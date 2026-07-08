"""発注書 → 印刷勘太郎向けCSV変換 Webアプリ(FastAPI)。

フロー:
  1. 発注書(PDF/画像)をアップロード → Claude APIがデータ抽出
  2. 画面で人が確認・修正(必須チェック・桁数チェック付き)
  3. 確定 → 検証 → CSV生成(Shift_JIS/CRLF等は設定) → アトミック書込 → .done 作成
  4. 勘太郎側がSFTP(PULL)で取込。必要ならアプリからSFTP PUSHも可能(鍵認証)
"""
import logging
import os
import shutil
import uuid
from datetime import datetime
from pathlib import Path

import yaml
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from app import csv_writer, extractor

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


class ExportRequest(BaseModel):
    rows: list[dict]
    source_file: str = ""


@app.get("/api/config")
def get_config():
    """UIが列定義・運用設定を参照するためのAPI(SFTP秘密情報は返さない)。"""
    return {
        "columns": CONFIG["csv"]["columns"],
        "csv": {k: v for k, v in CONFIG["csv"].items() if k != "columns"},
        "output": CONFIG["output"],
        "mode": CONFIG["mode"],
        "sftp_push": CONFIG["sftp"]["push_enabled"],
    }


@app.post("/api/extract")
async def extract(file: UploadFile = File(...)):
    """発注書をアップロードしてAI抽出。結果は画面で人が確認・修正する。"""
    ext = os.path.splitext(file.filename or "")[1].lower()
    saved = UPLOAD_DIR / f"{datetime.now():%Y%m%d_%H%M%S}_{uuid.uuid4().hex[:8]}{ext}"
    with open(saved, "wb") as f:
        shutil.copyfileobj(file.file, f)
    log.info("アップロード受付: %s (元ファイル名: %s)", saved.name, file.filename)
    try:
        result = extractor.extract_from_file(
            str(saved), CONFIG["csv"]["columns"],
            CONFIG["extraction"]["model"], CONFIG["extraction"]["max_tokens"],
        )
    except Exception as e:
        log.exception("AI抽出エラー: %s", saved.name)
        raise HTTPException(status_code=422, detail=f"読み取りに失敗しました: {e}")
    log.info("抽出成功: %s (%d明細)", saved.name, len(result["orders"]))
    return {"orders": result["orders"], "confidence_note": result.get("confidence_note", ""),
            "source_file": saved.name}


@app.post("/api/export")
def export(req: ExportRequest):
    """人の確認を経たデータを検証し、勘太郎仕様のCSVとして出力する。"""
    out_cfg = CONFIG["output"]
    out_dir = str(BASE_DIR / out_cfg["dir"]) if not os.path.isabs(out_cfg["dir"]) else out_cfg["dir"]
    try:
        rows = csv_writer.validate_rows(req.rows, CONFIG["csv"]["columns"], CONFIG["csv"]["encoding"])
    except csv_writer.ValidationError as e:
        return {"ok": False, "errors": e.errors}

    data = csv_writer.build_csv_bytes(rows, CONFIG["csv"])
    filename = csv_writer.next_filename(out_dir, out_cfg["filename_pattern"], out_cfg["timestamp_format"])
    paths = csv_writer.write_atomic(out_dir, filename, data,
                                    out_cfg.get("done_file", True), out_cfg.get("done_suffix", ".done"))
    log.info("CSV出力: %s (%d明細, 元:%s)", paths["csv"], len(rows), req.source_file)

    sftp_result = None
    if CONFIG["sftp"]["push_enabled"]:
        sftp_result = _sftp_push(paths)
    return {"ok": True, "filename": filename, "rows": len(rows), "paths": paths, "sftp": sftp_result}


def _sftp_push(paths: dict) -> dict:
    """アプリ側からPUSHする構成の場合のみ使用。SSH鍵認証(パスワード不使用)。"""
    import paramiko
    s = CONFIG["sftp"]
    key = paramiko.Ed25519Key.from_private_key_file(s["private_key_path"])
    transport = paramiko.Transport((s["host"], s["port"]))
    try:
        transport.connect(username=s["username"], pkey=key)
        sftp = paramiko.SFTPClient.from_transport(transport)
        for p in [paths["csv"], paths["done"]]:  # CSVを先に、.doneを最後に送る(順序が重要)
            if p:
                remote = s["remote_dir"].rstrip("/") + "/" + os.path.basename(p)
                sftp.put(p, remote + ".tmp")
                sftp.rename(remote + ".tmp", remote)  # リモート側でもアトミックに
        log.info("SFTP送信完了: %s", paths["csv"])
        return {"ok": True}
    finally:
        transport.close()


@app.get("/api/files")
def list_files():
    """出力済み/処理済みファイルの一覧(運用状況の見える化)。"""
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
