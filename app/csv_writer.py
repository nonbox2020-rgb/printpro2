"""勘太郎取込仕様に沿ったCSV生成モジュール。

「印刷勘太郎から求むものリスト」対応:
- 文字コード / 改行コード / ヘッダー有無 / 囲み文字 → config.yaml の csv セクション
- 命名規則(タイムスタンプ+連番) → filename_pattern
- アトミック書込(.tmp → rename) → 不完全CSVの読込防止
- .done トリガーファイル → 転送完了の合図
"""
import csv
import io
import os
import re
import tempfile
import unicodedata
from datetime import datetime

QUOTING_MAP = {"all": csv.QUOTE_ALL, "minimal": csv.QUOTE_MINIMAL, "none": csv.QUOTE_NONE}


class ValidationError(Exception):
    def __init__(self, errors: list[str]):
        self.errors = errors
        super().__init__("; ".join(errors))


def _normalize(value: str, fmt: str | None) -> str:
    v = unicodedata.normalize("NFKC", str(value or "")).strip()
    if fmt == "date" and v:
        m = re.match(r"(\d{4})[/\-年](\d{1,2})[/\-月](\d{1,2})日?", v)
        if m:
            v = f"{m.group(1)}/{int(m.group(2)):02d}/{int(m.group(3)):02d}"
    if fmt in ("int", "number") and v:
        v = v.replace(",", "").replace("円", "").replace("¥", "")
    return v


def validate_rows(rows: list[dict], columns: list[dict], encoding: str) -> list[dict]:
    """正規化 + 必須/桁数/形式/文字コード変換可否をチェック。エラーは行番号付きでまとめて返す。"""
    errors: list[str] = []
    cleaned: list[dict] = []
    for i, row in enumerate(rows, start=1):
        out = {}
        for col in columns:
            v = _normalize(row.get(col["key"], ""), col.get("format"))
            if col.get("required") and not v:
                errors.append(f"{i}行目: 「{col['label']}」は必須です")
            if col.get("max_len") and len(v) > col["max_len"]:
                errors.append(f"{i}行目: 「{col['label']}」が{col['max_len']}桁を超えています({len(v)}桁)")
            if col.get("format") == "int" and v and not re.fullmatch(r"-?\d+", v):
                errors.append(f"{i}行目: 「{col['label']}」は整数で入力してください: {v}")
            if col.get("format") == "number" and v and not re.fullmatch(r"-?\d+(\.\d+)?", v):
                errors.append(f"{i}行目: 「{col['label']}」は数値で入力してください: {v}")
            if col.get("format") == "date" and v and not re.fullmatch(r"\d{4}/\d{2}/\d{2}", v):
                errors.append(f"{i}行目: 「{col['label']}」は YYYY/MM/DD 形式にしてください: {v}")
            try:
                v.encode(encoding)
            except UnicodeEncodeError as e:
                errors.append(f"{i}行目: 「{col['label']}」に{encoding}へ変換できない文字があります: {v[e.start:e.end]}")
            out[col["key"]] = v
        cleaned.append(out)
    if errors:
        raise ValidationError(errors)
    return cleaned


def build_csv_bytes(rows: list[dict], cfg_csv: dict) -> bytes:
    columns = cfg_csv["columns"]
    buf = io.StringIO()
    writer = csv.writer(buf, quoting=QUOTING_MAP[cfg_csv.get("quoting", "minimal")],
                        lineterminator=cfg_csv.get("newline", "\r\n"))
    if cfg_csv.get("header", True):
        writer.writerow([c["label"] for c in columns])
    for row in rows:
        writer.writerow([row.get(c["key"], "") for c in columns])
    return buf.getvalue().encode(cfg_csv.get("encoding", "cp932"))


def next_filename(out_dir: str, pattern: str, ts_format: str) -> str:
    """タイムスタンプ+連番で重複しないファイル名を採番(都度発生型で同時刻でも衝突しない)。"""
    ts = datetime.now().strftime(ts_format)
    seq = 1
    while True:
        name = pattern.format(timestamp=ts, seq=seq)
        if not os.path.exists(os.path.join(out_dir, name)):
            return name
        seq += 1


def write_atomic(out_dir: str, filename: str, data: bytes, done: bool, done_suffix: str) -> dict:
    """一時ファイルに完全に書き切ってから rename。最後に .done を置く。"""
    os.makedirs(out_dir, exist_ok=True)
    final_path = os.path.join(out_dir, filename)
    fd, tmp_path = tempfile.mkstemp(dir=out_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, final_path)  # 同一FS内renameはアトミック
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise
    done_path = None
    if done:
        done_path = final_path + done_suffix
        with open(done_path, "w") as f:
            f.write(datetime.now().isoformat())
    return {"csv": final_path, "done": done_path}
