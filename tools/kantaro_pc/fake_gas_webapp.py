"""テスト用: GAS の受け取り口（4_webapp.gs）の偽物。本物の Google には触らない。

  python3 fake_gas_webapp.py ROOT      ROOT/2_勘太郎用 にあるCSVを渡す。使うポート番号を1行目に出す

本物と同じく、/macros/s/<ID>/exec への問い合わせは 302 で /macros/echo?key=… へ回してから JSON を返す。
  - /macros/s/TEST/exec   合言葉 TOKEN（下）の受け取り口
  - /macros/s/LOGIN/exec  「全員」に公開していないときのように、ログインの画面（HTML）を返す
ROOT/fail_done に数字を書くと、その回数だけ done を失敗させる（受け取ったのに知らせが届かないとき）。
"""
import json
import os
import shutil
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = sys.argv[1]
OUT, DONE, SKIP = (os.path.join(ROOT, n) for n in ("2_勘太郎用", "3_渡し済み", "4_渡さなかった分"))
TOKEN = "0123456789abcdef" * 4   # 本物と同じく英数字64文字
PENDING = {}


def answer(params):
    if params.get("token") != TOKEN:
        return {"ok": False, "error": "合言葉が違います"}
    action = params.get("action", "list")
    names = sorted(n for n in os.listdir(OUT) if n.lower().endswith(".csv"))
    # 本物のドライブと同じく、ファイルごとに別の id（同じ名前でも、届き直したものは別の id）
    ids = {n + "#" + str(os.stat(os.path.join(OUT, n)).st_ino): n for n in names}
    if action == "ping":
        return {"ok": True, "account": "tester@example.com"}
    if action == "list":
        return {"ok": True, "files": [{"id": i, "name": n, "size": os.path.getsize(os.path.join(OUT, n))} for i, n in ids.items()]}
    fid = params.get("id", "")
    name = ids.get(fid)
    if action == "file":
        if not name:
            return {"ok": False, "error": "このファイルは渡せません: " + fid}
        data = open(os.path.join(OUT, name), "rb").read()
        import base64
        return {"ok": True, "name": name, "size": len(data), "data": base64.b64encode(data).decode()}
    if action in ("done", "skip"):
        flag = os.path.join(ROOT, "fail_done")
        if action == "done" and os.path.exists(flag):
            left = int(open(flag).read() or 0)
            if left > 0:
                open(flag, "w").write(str(left - 1))
                return {"ok": False, "error": "（テスト）知らせを受け取れませんでした"}
        if name:
            to = DONE if action == "done" else SKIP
            os.makedirs(to, exist_ok=True)
            target = os.path.join(to, name)
            while os.path.exists(target):   # ドライブは同じ名前を並べられる。偽物では名前を変えて残す
                target += "_"
            shutil.move(os.path.join(OUT, name), target)
        return {"ok": True}
    return {"ok": False, "error": "知らない action です: " + action}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body, ctype, location=None):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        if location:
            self.send_header("Location", location)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        params = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path == "/macros/s/TEST/exec":
            key = uuid.uuid4().hex
            PENDING[key] = json.dumps(answer(params), ensure_ascii=False)
            self.send(302, "", "text/html", "/macros/echo?key=" + key)
        elif url.path == "/macros/echo" and params.get("key") in PENDING:
            self.send(200, PENDING.pop(params["key"]), "application/json; charset=utf-8")
        elif url.path == "/macros/s/LOGIN/exec":
            self.send(200, "<!DOCTYPE html><html><body>ログイン</body></html>", "text/html; charset=utf-8")
        else:
            self.send(404, "not found", "text/plain")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
