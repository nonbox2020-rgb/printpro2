"""受注台帳ストア。

受注番号をキーに過去の発注内容を記憶し、同じ受注番号が再登録されたら
「更新」と判定して変更された科目の差分を返す。

- 保存先: data/orders.json(台帳) / data/notifications.json(更新通知)
- 注意: Render無料プランはディスクが再起動で消えるため、本番運用では
  Persistent Disk か社内サーバー常設が必要。
"""
import json
import os
import threading
from datetime import datetime

_lock = threading.Lock()


class OrderStore:
    def __init__(self, orders_path: str, notif_path: str, key_field: str = "order_no"):
        self.orders_path = orders_path
        self.notif_path = notif_path
        self.key_field = key_field

    # ---------- 内部: 読み書き ----------
    def _load(self, path) -> dict | list:
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        return {} if path == self.orders_path else []

    def _save(self, path, data):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)

    # ---------- 差分判定 ----------
    def check_rows(self, rows: list[dict], columns: list[dict]) -> list[dict]:
        """各行を台帳と比較して new / updated / unchanged と変更科目を返す(保存はしない)。"""
        with _lock:
            orders = self._load(self.orders_path)
        results = []
        labels = {c["key"]: c["label"] for c in columns}
        for row in rows:
            key = str(row.get(self.key_field, "")).strip()
            if not key:
                results.append({"status": "new", "changes": []})
                continue
            old = orders.get(key)
            if old is None:
                results.append({"status": "new", "changes": []})
                continue
            changes = []
            for c in columns:
                k = c["key"]
                if k == self.key_field:
                    continue
                ov, nv = str(old["fields"].get(k, "")), str(row.get(k, ""))
                if ov != nv:
                    changes.append({"key": k, "label": labels.get(k, k), "old": ov, "new": nv})
            results.append({"status": "updated" if changes else "unchanged", "changes": changes})
        return results

    # ---------- 確定登録 ----------
    def commit_rows(self, rows: list[dict], columns: list[dict], filename: str) -> list[dict]:
        """CSV出力確定時に呼ぶ。台帳を更新し、変更があれば通知を記録して差分結果を返す。"""
        results = self.check_rows(rows, columns)
        now = datetime.now().strftime("%Y/%m/%d %H:%M:%S")
        with _lock:
            orders = self._load(self.orders_path)
            notifs = self._load(self.notif_path)
            for row, res in zip(rows, results):
                key = str(row.get(self.key_field, "")).strip()
                if not key:
                    continue
                fields = {c["key"]: str(row.get(c["key"], "")) for c in columns}
                if res["status"] == "updated":
                    entry = orders[key]
                    entry.setdefault("history", []).append(
                        {"at": entry["updated_at"], "fields": entry["fields"]})
                    entry["fields"] = fields
                    entry["updated_at"] = now
                    entry["revision"] = entry.get("revision", 1) + 1
                    notifs.insert(0, {
                        "at": now, "order_no": key, "file": filename,
                        "item_name": fields.get("item_name", ""),
                        "changes": res["changes"],
                    })
                elif res["status"] == "new":
                    orders[key] = {"fields": fields, "created_at": now,
                                   "updated_at": now, "revision": 1}
            self._save(self.orders_path, orders)
            self._save(self.notif_path, notifs[:100])  # 直近100件のみ保持
        return results

    def notifications(self, limit: int = 30) -> list[dict]:
        with _lock:
            return self._load(self.notif_path)[:limit]
