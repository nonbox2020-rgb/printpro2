"""勘太郎パソコンの受け取り係が使うAPI(/api/agent/...)のテスト。

  python tests/test_agent_api.py    # 依存: requirements.txt + httpx

架空サンプルAを画面と同じ手順で出力し、受け取り係と同じ手順で受け取る。
出力フォルダは一時フォルダを使うので、手元の data/ は汚さない。
"""
import hashlib
import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.environ.update(APP_USERNAME="tester", APP_PASSWORD="pass-1234", SECRET_KEY="test-secret",
                  AGENT_TOKEN="agent-token-for-test")

from fastapi.testclient import TestClient  # noqa: E402

from app import main  # noqa: E402

AUTH = {"Authorization": "Bearer agent-token-for-test"}


def run():
    tmp = Path(tempfile.mkdtemp())
    main.CONFIG["output"].update(dir=str(tmp / "incoming"), archive_dir=str(tmp / "archive"),
                                 failed_dir=str(tmp / "failed"))
    main.UPLOAD_DIR = tmp / "uploads"
    main.UPLOAD_DIR.mkdir()
    c = TestClient(main.app)

    # 合言葉が無い・違うときは入れない
    assert c.get("/api/agent/files").status_code == 401
    assert c.get("/api/agent/files", headers={"Authorization": "Bearer wrong"}).status_code == 401

    # 画面と同じ手順で、架空サンプルAを変換 → 出力(5ファイルが未取込に入る)
    assert c.post("/api/login", json={"username": "tester", "password": "pass-1234"}).status_code == 200
    sample = Path(ROOT, "tests", "samples", "sample_A_2026-10-01.csv").read_bytes()
    conv = c.post("/api/convert", files=[("files", ("sample_A.csv", sample, "text/csv"))]).json()
    payload = {"cases": [{"order_no": k["order_no"], "section": k["section"],
                          "plate_date": k["plate_date"], "rows": k["rows"]} for k in conv["cases"]]}
    exported = c.post("/api/export", json=payload).json()
    assert exported["ok"] and len(exported["files"]) == 5, exported

    # 一覧: 日本語のファイル名を化けさせないよう charset=utf-8 を付けて返す
    r = c.get("/api/agent/files", headers=AUTH)
    assert "charset=utf-8" in r.headers["content-type"], r.headers["content-type"]
    files = r.json()["files"]
    assert len(files) == 5 and all(f["id"] and f["sha256"] for f in files)

    # 受け取ったファイルは正解CSVと同じで、SHA-256 も一致する
    expected = Path(ROOT, "tests", "expected", "sample_A_2026-10-01")
    for f in files:
        body = c.get("/api/agent/files/" + quote(f["name"]), headers=AUTH).content
        assert hashlib.sha256(body).hexdigest() == f["sha256"], f["name"]
        assert body == (expected / f["name"]).read_bytes(), f["name"]

    # 「受け取った」→ 取込済へ移り、画面に最終確認の時刻が出る
    for f in files:
        assert c.post(f"/api/agent/files/{quote(f['name'])}/taken", headers=AUTH).json()["ok"]
    state = c.get("/api/files").json()
    assert len(state["incoming"]) == 0 and len(state["archive"]) == 5, state
    assert state["agent"]["enabled"] and state["agent"]["last_seen"]

    # フォルダの外を指す名前・無いファイルは受け付けない
    assert c.get("/api/agent/files/..x.csv", headers=AUTH).status_code == 400
    assert c.post("/api/agent/files/nothing.csv/taken", headers=AUTH).status_code == 404

    # 日本語入力のままIDを打っても 500 にならず「違います」になる
    assert TestClient(main.app).post("/api/login", json={"username": "テスター",
                                                         "password": "ぱす"}).status_code == 401

    print("✅ 受け取り係APIのテスト合格")


if __name__ == "__main__":
    run()
