"""三映CSV → 印刷勘太郎向けCSV 変換 Webアプリ(FastAPI)。

フロー:
  1. ログイン(全画面・API共通で認証必須)
  2. 三映CSV(CSV-A・複数可)をアップロード → 固定ルールで勘太郎35列(A〜AI)に変換
     (AIは使わない。ルールは sanei_config.yaml)
  3. 画面で人が確認・修正(1案件=1ファイル単位。判断に迷う箇所は警告を表示)
  4. 確定 → 案件ごとにCSV-B生成 → アトミック書込 → .done 作成
  5. 設定によりSFTPで印刷勘太郎サーバーへ自動送信(鍵認証/パスワード認証)

設定ファイルの役割:
  sanei_config.yaml ... 変換ルール・CSV-Bの35列定義・文字コード/囲み/改行・ファイル名
  config.yaml       ... 出力フォルダ・.done・SFTP・サーバー

必要な環境変数:
  APP_USERNAME / APP_PASSWORD ... ログインID/パスワード
  SECRET_KEY ... セッション署名用のランダム文字列
  SFTP_PASSWORD ... SFTPをパスワード認証で使う場合のみ
"""
import logging
import os
import re
import secrets
import uuid
from datetime import datetime
from pathlib import Path

import yaml
from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.middleware.sessions import SessionMiddleware

from app import csv_writer
from app.sanei_converter import SaneiConverter

BASE_DIR = Path(__file__).resolve().parent.parent
CONFIG = yaml.safe_load((BASE_DIR / "config.yaml").read_text(encoding="utf-8"))
SANEI = yaml.safe_load((BASE_DIR / "sanei_config.yaml").read_text(encoding="utf-8"))
CONVERTER = SaneiConverter(SANEI)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(), logging.FileHandler(BASE_DIR / "app.log", encoding="utf-8")],
)
log = logging.getLogger("kantaro-app")

app = FastAPI(title="三映CSV→勘太郎CSV 変換アプリ(印刷勘太郎連携)")

UPLOAD_DIR = BASE_DIR / "data" / "uploads"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

SECTIONS = ("本番", "校正")

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
    """UIが35列の定義・運用設定を参照するためのAPI(SFTP秘密情報は返さない)。"""
    return {
        "columns": SANEI["csv_b_columns"],
        "output": CONFIG["output"],
        "sftp_push": CONFIG["sftp"]["push_enabled"],
        "user": request.session.get("user", ""),
    }


# ---------------- 三映CSV → 案件ごとの35列に変換 ----------------

def _decode_csv_a(raw: bytes) -> str:
    """UTF-8を先に厳密に試し、失敗したら設定の文字コード(cp932)で読む。

    cp932の日本語はUTF-8として解釈するとほぼ確実に失敗するため、この順番なら
    どちらで保存されたファイルでも文字化けせずに判定できる。
    """
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode(SANEI["input"].get("encoding", "cp932"))


@app.post("/api/convert")
async def convert(files: list[UploadFile] = File(...)):
    """三映CSV(複数可)を変換し、案件(=CSV-B 1ファイル分)の一覧を返す。保存はしない。"""
    cases, results = [], []
    for file in files:
        name = file.filename or "(名称なし)"
        if os.path.splitext(name)[1].lower() != ".csv":
            results.append({"file": name, "ok": False,
                            "note": "CSVファイル(.csv)を選んでください"})
            continue
        raw = await file.read()
        saved = UPLOAD_DIR / f"{datetime.now():%Y%m%d_%H%M%S}_{uuid.uuid4().hex[:8]}.csv"
        saved.write_bytes(raw)  # 監査用に原本を保管
        log.info("アップロード受付: %s (元: %s)", saved.name, name)
        try:
            res = CONVERTER.convert(_decode_csv_a(raw))
        except Exception as e:
            log.exception("変換エラー: %s", name)
            results.append({"file": name, "ok": False, "note": f"読み取りに失敗しました: {e}"})
            continue
        for c in res["cases"]:
            cases.append({
                "id": uuid.uuid4().hex[:8],
                "file": name,
                "section": c["section"],
                "order_no": c["order_no"],
                "plate_date": res["plate_date"],
                "filename": CONVERTER.filename_for(c, res["plate_date"]),
                "rows": c["b_rows"],
                "warnings": c["warnings"],
            })
        results.append({"file": name, "ok": True, "plate_date": res["plate_date"],
                        "cases": len(res["cases"]), "warnings": res["warnings"]})
        log.info("変換成功: %s (下版予定日 %s / %d案件)", name, res["plate_date"],
                 len(res["cases"]))
    return {"cases": cases, "results": results}


# ---------------- CSV-B出力(1案件1ファイル) + SFTP送信 ----------------

class CaseIn(BaseModel):
    order_no: str
    section: str = "本番"
    plate_date: str = ""
    rows: list[dict]


class ExportRequest(BaseModel):
    cases: list[CaseIn]


_UNSAFE_CHARS = re.compile(r'[\\/:*?"<>|\x00-\x1f]')


def _safe_filename(name: str) -> str:
    """画面から戻る値で組み立てるため、パス区切り等を無害化する(ディレクトリ外への書込防止)。"""
    name = os.path.basename(_UNSAFE_CHARS.sub("_", name).replace("..", "_"))
    return name if name.lower().endswith(".csv") else name + ".csv"


def _unique_name(out_dir: str, name: str, used: set) -> str:
    """同名が既にある場合は上書きせず _2, _3 … を付ける(未取込ファイルの消失防止)。"""
    stem, ext = os.path.splitext(name)
    candidate, n = name, 1
    while candidate in used or os.path.exists(os.path.join(out_dir, candidate)):
        n += 1
        candidate = f"{stem}_{n}{ext}"
    return candidate


@app.post("/api/export")
def export(req: ExportRequest):
    """人の確認を経た案件を、案件ごとにCSV-Bとして出力・送信する。

    先に全案件のCSVを組み立てて検証し、1件でも失敗したら1ファイルも書き出さない。
    """
    if not req.cases:
        return {"ok": False, "errors": ["出力する案件がありません"]}
    out_cfg = CONFIG["output"]
    out_dir = out_cfg["dir"] if os.path.isabs(out_cfg["dir"]) else str(BASE_DIR / out_cfg["dir"])

    built, errors = [], []
    for c in req.cases:
        if not c.rows:
            errors.append(f"受注№{c.order_no}: 明細がありません")
            continue
        section = c.section if c.section in SECTIONS else "本番"
        rows = [{k: "" if v is None else str(v) for k, v in r.items()} for r in c.rows]
        case = {"section": section, "order_no": c.order_no, "b_rows": rows}
        try:
            data = CONVERTER.build_csv_b(case)
        except UnicodeEncodeError as e:
            errors.append(f"受注№{c.order_no}: 出力の文字コードに変換できない文字があります"
                          f"「{e.object[e.start:e.end]}」")
            continue
        plate_date = rows[0].get("plate_date") or c.plate_date
        name = _safe_filename(CONVERTER.filename_for(case, plate_date))
        built.append({"order_no": c.order_no, "section": section, "filename": name,
                      "data": data, "rows": len(rows)})
    if errors:
        return {"ok": False, "errors": errors}

    written, used = [], set()
    for b in built:
        b["filename"] = _unique_name(out_dir, b["filename"], used)
        used.add(b["filename"])
        b["paths"] = csv_writer.write_atomic(out_dir, b["filename"], b["data"],
                                             out_cfg.get("done_file", True),
                                             out_cfg.get("done_suffix", ".done"))
        written.append(b)
        log.info("CSV-B出力: %s (受注№%s %s / %d行)", b["paths"]["csv"], b["order_no"],
                 b["section"], b["rows"])

    sftp_result = None
    if CONFIG["sftp"]["push_enabled"]:
        failed = []
        for b in written:
            try:
                _sftp_push(b["paths"])
            except Exception as e:
                log.exception("SFTP送信エラー: %s", b["filename"])
                failed.append(f"{b['filename']}: {e}")
        sftp_result = ({"ok": True, "message": f"印刷勘太郎サーバーへ{len(written)}件送信しました"}
                       if not failed else
                       {"ok": False, "message": "SFTP送信に失敗したファイルがあります"
                        "(CSVはサーバー内に保存済み): " + " / ".join(failed)})
    return {"ok": True,
            "files": [{k: b[k] for k in ("order_no", "section", "filename", "rows")}
                      for b in written],
            "sftp": sftp_result}


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
            for p in sorted(d.glob("*.csv"), key=lambda x: x.stat().st_mtime, reverse=True)[:50]:
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
