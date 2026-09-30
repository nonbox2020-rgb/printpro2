"""CSV-B のファイル書き込み。

- アトミック書込(.tmp → rename) → 書きかけのCSVを読まれない
- .done ファイル → 書き終わりの合図
"""
import os
import tempfile
from datetime import datetime


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
