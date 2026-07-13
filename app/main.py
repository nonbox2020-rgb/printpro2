"""発注書 → 印刷勘太郎向けCSV変換 Webアプリ(FastAPI)。

フロー:
  1. ログイン(全画面・API共通で認証必須)
  2. 発注書(PDF/画像・複数可)をアップロード → Claude APIがデータ抽出
  3. 画面で人が確認・修正(必須チェック・桁数チェック付き)
  4. 確定 → 検証 → CSV生成 → アトミック書込 → .done 作成
  5. 設定によりSFTPで印刷勘太郎サーバーへ自動送信(鍵認証/パスワード認証)

必要な環境変数:
  ANTHROPIC_API_KEY ... Claude APIキー
  APP_USERNAME / APP_PASSWORD ... ログインID/パスワード
  SECRET_KEY ... セッション署名用のランダム文字列
  SFTP_PASSWORD ... SFTPをパスワード認証で使う場合のみ
"""
import json
import logging
import os
import secrets
import shutil
import uuid
from datetime import datetime
from pathlib import Path

import yaml
from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.middleware.sessions import SessionMiddleware

from app import csv_writer, extractor
from app.store import OrderStore

BASE_DIR = Path(__file__).resolve().parent.parent
CONFIG = yaml.safe_load((BASE_DIR / "config.yaml").read_text(encoding="utf-8"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(), logging.FileHandler(BASE_DIR / "app.log", encoding="utf-8")],
)
log = logging.getLogger("kantaro-app")

app = FastAPI(title="発注書CSV変換アプリ(印刷勘太郎連携)")

UPLOAD_DIR = BASE_DIR / "data" / "uploads"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

STORE = OrderStore(str(BASE_DIR / "data" / "orders.json"),
                   str(BASE_DIR / "data" / "notifications.json"),
                   key_field=CONFIG.get("update_check", {}).get("key_field", "order_no"))

# ---------------- 認証 ----------------

PUBLIC_PATHS = {"/login.html", "/api/login"}


@app.middleware("http")
async def auth_guard(request: Request, call_next):
    """ログイン必須ガード。未ログインなら画面はログインページへ、APIは401を返す。"""
    path = request.url.path
    if path in PUBLIC_PATHS or request.session.get("user"):
        return await call_next(request)
    if path.startswith("/api/"):
        return JSONResponse({"detail": "ログインが必要です"}, status_code=401)
    return RedirectResponse("/login.html")


# 注意: add_middleware は「後に登録したものが先に実行」されるため、
# auth_guard(上のデコレータ)より後に登録することで Session → 認証 の順で動く。
app.add_middleware(SessionMiddleware,
                   secret_key=os.environ.get("SECRET_KEY", secrets.token_hex(32)),
                   max_age=8 * 60 * 60)  # セッション有効期間: 8時間


class LoginRequest(BaseModel):
    username: str
    password: str


@app.post("/api/login")
def login(req: LoginRequest, request: Request):
    expect_user = os.environ.get("APP_USERNAME", "")
    expect_pass = os.environ.get("APP_PASSWORD", "")
    if not expect_user or not expect_pass:
        raise HTTPException(status_code=500,
                            detail="サーバーに APP_USERNAME / APP_PASSWORD が設定されていません")
    ok = secrets.compare_digest(req.username, expect_user) and \
         secrets.compare_digest(req.password, expect_pass)
    if not ok:
        log.warning("ログイン失敗: user=%s", req.username)
        raise HTTPException(status_code=401, detail="IDまたはパスワードが違います")
    request.session["user"] = req.username
    log.info("ログイン成功: %s", req.username)
    return {"ok": True}


@app.get("/api/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/login.html")


# ---------------- 設定参照 ----------------

@app.get("/api/config")
def get_config(request: Request):
    """UIが列定義・運用設定を参照するためのAPI(SFTP秘密情報は返さない)。"""
    return {
        "columns": CONFIG["csv"]["columns"],
        "output": CONFIG["output"],
        "sftp_push": CONFIG["sftp"]["push_enabled"],
        "user": request.session.get("user", ""),
    }


# ---------------- AI抽出(複数ファイル対応) ----------------

@app.post("/api/extract")
async def extract(files: list[UploadFile] = File(...)):
    """複数の発注書をまとめてAI抽出。ファイルごとに成否を返し、明細は結合する。"""
    orders, results = [], []
    for file in files:
        ext = os.path.splitext(file.filename or "")[1].lower()
        saved = UPLOAD_DIR / f"{datetime.now():%Y%m%d_%H%M%S}_{uuid.uuid4().hex[:8]}{ext}"
        with open(saved, "wb") as f:
            shutil.copyfileobj(file.file, f)
        log.info("アップロード受付: %s (元: %s)", saved.name, file.filename)
        try:
            result = extractor.extract_from_file(
                str(saved), CONFIG["csv"]["columns"],
                CONFIG["extraction"]["model"], CONFIG["extraction"]["max_tokens"],
            )
            for row in result["orders"]:
                row["_source"] = file.filename  # 読取元の表示用(CSVには出力しない)
            orders.extend(result["orders"])
            results.append({"file": file.filename, "ok": True,
                            "rows": len(result["orders"]),
                            "note": result.get("confidence_note", "")})
            log.info("抽出成功: %s (%d明細)", file.filename, len(result["orders"]))
        except Exception as e:
            log.exception("AI抽出エラー: %s", file.filename)
            results.append({"file": file.filename, "ok": False, "rows": 0, "note": str(e)})
    return {"orders": orders, "results": results}


# ---------------- 更新チェック・通知 ----------------

class CheckRequest(BaseModel):
    rows: list[dict]


@app.post("/api/check")
def check(req: CheckRequest):
    """AI読取直後に呼び、各明細が 新規/更新/変更なし かと変更科目を返す。"""
    rows = [{k: v for k, v in r.items() if not k.startswith("_")} for r in req.rows]
    return {"results": STORE.check_rows(rows, CONFIG["csv"]["columns"])}


@app.get("/api/notifications")
def notifications():
    """発注書の更新通知一覧(画面のお知らせ欄に表示)。"""
    return {"notifications": STORE.notifications()}


def _notify_slack(changed: list[dict], filename: str):
    """SLACK_WEBHOOK_URL が設定されていればSlackにも通知(未設定なら何もしない)。"""
    url = os.environ.get("SLACK_WEBHOOK_URL", "")
    if not url or not changed:
        return
    try:
        import urllib.request
        lines = [f"【発注書の更新がありました】({filename})"]
        for n in changed:
            diffs = "、".join(f"{c['label']}: {c['old']} → {c['new']}" for c in n["changes"])
            lines.append(f"・受注番号 {n['order_no']}({n['item_name']}): {diffs}")
        body = json.dumps({"text": "\n".join(lines)}).encode()
        req = urllib.request.Request(url, data=body,
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10)
        log.info("Slack通知送信: %d件", len(changed))
    except Exception:
        log.exception("Slack通知に失敗(処理は継続)")


# ---------------- CSV出力 + SFTP送信 ----------------

class ExportRequest(BaseModel):
    rows: list[dict]
    source_file: str = ""


@app.post("/api/export")
def export(req: ExportRequest):
    """人の確認を経たデータを検証し、勘太郎仕様のCSVとして出力・送信する。"""
    out_cfg = CONFIG["output"]
    out_dir = str(BASE_DIR / out_cfg["dir"]) if not os.path.isabs(out_cfg["dir"]) else out_cfg["dir"]
    rows_in = [{k: v for k, v in r.items() if not k.startswith("_")} for r in req.rows]
    try:
        rows = csv_writer.validate_rows(rows_in, CONFIG["csv"]["columns"], CONFIG["csv"]["encoding"])
    except csv_writer.ValidationError as e:
        return {"ok": False, "errors": e.errors}

    # 台帳と比較: 新規/更新/変更なし を判定し、台帳を更新
    results = STORE.commit_rows(rows, CONFIG["csv"]["columns"], req.source_file)
    statuses = [r["status"] for r in results]
    skip_unchanged = CONFIG.get("update_check", {}).get("skip_unchanged", True)
    if skip_unchanged:
        rows_out = [row for row, r in zip(rows, results) if r["status"] != "unchanged"]
    else:
        rows_out = rows
    if not rows_out:
        return {"ok": True, "filename": None, "rows": 0,
                "summary": {"new": 0, "updated": 0,
                            "unchanged": statuses.count("unchanged")},
                "message": "すべて登録済みの内容と同一のため、CSVは出力しませんでした"}

    data = csv_writer.build_csv_bytes(rows_out, CONFIG["csv"])
    filename = csv_writer.next_filename(out_dir, out_cfg["filename_pattern"], out_cfg["timestamp_format"])
    paths = csv_writer.write_atomic(out_dir, filename, data,
                                    out_cfg.get("done_file", True), out_cfg.get("done_suffix", ".done"))
    log.info("CSV出力: %s (%d明細, 新規%d/更新%d/同一スキップ%d, 元:%s)",
             paths["csv"], len(rows_out), statuses.count("new"),
             statuses.count("updated"), statuses.count("unchanged"), req.source_file)

    # 更新があった明細をSlack通知(SLACK_WEBHOOK_URL 設定時のみ)
    changed = [{"order_no": row.get("order_no", ""),
                "item_name": row.get("item_name", ""), "changes": r["changes"]}
               for row, r in zip(rows, results) if r["status"] == "updated"]
    _notify_slack(changed, filename)

    sftp_result = None
    if CONFIG["sftp"]["push_enabled"]:
        try:
            _sftp_push(paths)
            sftp_result = {"ok": True, "message": "印刷勘太郎サーバーへ送信しました"}
        except Exception as e:
            log.exception("SFTP送信エラー: %s", filename)
            sftp_result = {"ok": False, "message": f"SFTP送信に失敗しました: {e}(CSVはサーバー内に保存済み)"}
    return {"ok": True, "filename": filename, "rows": len(rows_out), "sftp": sftp_result,
            "summary": {"new": statuses.count("new"), "updated": statuses.count("updated"),
                        "unchanged": statuses.count("unchanged")},
            "changed": changed}


def _sftp_push(paths: dict):
    """SFTPで勘太郎サーバーへ送信。鍵認証を優先し、なければパスワード認証(環境変数)。

    送信順序が重要: CSV本体を先に(.tmp→renameでアトミックに)、.done を最後に送る。
    """
    import paramiko
    s = CONFIG["sftp"]
    transport = paramiko.Transport((s["host"], int(s["port"])))
    try:
        key_path = s.get("private_key_path") or ""
        if key_path and os.path.exists(key_path):
            try:
                pkey = paramiko.Ed25519Key.from_private_key_file(key_path)
            except paramiko.SSHException:
                pkey = paramiko.RSAKey.from_private_key_file(key_path)
            transport.connect(username=s["username"], pkey=pkey)
        else:
            password = os.environ.get("SFTP_PASSWORD", "")
            if not password:
                raise RuntimeError("SSH鍵ファイルが見つからず、SFTP_PASSWORD も未設定です")
            transport.connect(username=s["username"], password=password)
        sftp = paramiko.SFTPClient.from_transport(transport)
        remote_dir = s["remote_dir"].rstrip("/")
        for p in [paths["csv"], paths["done"]]:
            if p:
                remote = remote_dir + "/" + os.path.basename(p)
                sftp.put(p, remote + ".tmp")
                sftp.rename(remote + ".tmp", remote)
        log.info("SFTP送信完了: %s → %s", paths["csv"], remote_dir)
    finally:
        transport.close()


# ---------------- ファイル一覧・ダウンロード ----------------

@app.get("/api/files")
def list_files():
    result = {}
    for label, key in [("incoming", "dir"), ("archive", "archive_dir"), ("failed", "failed_dir")]:
        d = BASE_DIR / CONFIG["output"][key]
        files = []
        if d.exists():
            for p in sorted(d.glob("*.csv"), reverse=True)[:50]:
                st = p.stat()
                files.append({"name": p.name, "size": st.st_size,
                              "mtime": datetime.fromtimestamp(st.st_mtime).strftime("%Y/%m/%d %H:%M:%S"),
                              "done": (p.parent / (p.name + CONFIG["output"]["done_suffix"])).exists()})
        result[label] = files
    return result


@app.get("/api/download/{filename}")
def download(filename: str):
    if "/" in filename or "\\" in filename or ".." in filename:
        raise HTTPException(status_code=400, detail="不正なファイル名です")
    p = BASE_DIR / CONFIG["output"]["dir"] / filename
    if not p.exists():
        raise HTTPException(status_code=404, detail="ファイルが見つかりません")
    return FileResponse(p, filename=filename, media_type="text/csv")


app.mount("/", StaticFiles(directory=str(BASE_DIR / "static"), html=True), name="static")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=CONFIG["server"]["host"], port=CONFIG["server"]["port"])
