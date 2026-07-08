"""発注書(PDF/画像)からClaude APIで構造化データを抽出するモジュール。"""
import base64
import json
import os

import anthropic

MEDIA_TYPES = {
    ".pdf": "application/pdf",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
}


def build_prompt(columns: list[dict]) -> str:
    fields = "\n".join(
        f'- "{c["key"]}" ({c["label"]}) '
        f'{"【必須】" if c.get("required") else "【任意】"}'
        + (f' 形式:{c["format"]}' if c.get("format") else "")
        for c in columns
    )
    return f"""あなたは印刷会社の受注入力担当です。添付の発注書から以下の項目を正確に読み取ってください。

抽出項目:
{fields}

ルール:
- 発注書に複数の明細行がある場合は、明細ごとに1オブジェクトとして配列で返す
- 日付は YYYY/MM/DD 形式に正規化する
- 数量・単価・金額はカンマや円記号を除いた数値文字列にする
- 読み取れない項目は空文字 "" にする(推測で埋めない)
- 手書き文字が不鮮明な場合は "confidence_note" に懸念点を書く

必ず次のJSONのみを返してください。前置きやMarkdownの```は不要です:
{{"orders": [{{...各項目...}}], "confidence_note": "読取に関する注意点(なければ空文字)"}}"""


def extract_from_file(file_path: str, columns: list[dict], model: str, max_tokens: int) -> dict:
    """発注書ファイルをClaudeに渡し、抽出結果(dict)を返す。"""
    ext = os.path.splitext(file_path)[1].lower()
    media_type = MEDIA_TYPES.get(ext)
    if media_type is None:
        raise ValueError(f"未対応のファイル形式です: {ext}(PDF/PNG/JPEG/GIF/WEBPに対応)")

    with open(file_path, "rb") as f:
        data = base64.standard_b64encode(f.read()).decode("utf-8")

    block_type = "document" if media_type == "application/pdf" else "image"
    client = anthropic.Anthropic()  # ANTHROPIC_API_KEY 環境変数を使用

    resp = client.messages.create(
        model=model,
        max_tokens=max_tokens,
        messages=[{
            "role": "user",
            "content": [
                {"type": block_type, "source": {"type": "base64", "media_type": media_type, "data": data}},
                {"type": "text", "text": build_prompt(columns)},
            ],
        }],
    )
    text = "".join(b.text for b in resp.content if b.type == "text")
    text = text.replace("```json", "").replace("```", "").strip()
    result = json.loads(text)
    if "orders" not in result or not isinstance(result["orders"], list):
        raise ValueError("AIの応答形式が不正です(ordersが見つかりません)")
    return result
