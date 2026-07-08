# 発注書CSV変換アプリ（印刷勘太郎 連携）

発注書（PDF/画像）をAIで読み取り、人が確認・修正したうえで、印刷勘太郎の取込仕様に沿ったCSVを連携フォルダへ出力するWebアプリです。勘太郎側はSFTPでこのフォルダからCSVを取り込みます（PULL方式）。

## 処理フロー

```
発注書(PDF/画像)
   │  ① アップロード
   ▼
Claude API がデータ抽出（明細ごとにJSON化）
   │  ② 画面で人が確認・修正（必須／桁数／形式チェック）
   ▼
CSV生成（文字コード・改行・囲み文字は config.yaml で指定）
   │  ③ .tmpに書き切ってから rename（アトミック書込）
   ▼
連携フォルダ /data/incoming/ に order_YYYYMMDD_HHMMSS_001.csv
   │  ④ 最後に .done ファイルを作成（転送完了の合図）
   ▼
印刷勘太郎が SFTP で .done を確認してから CSV を取込
```

## セットアップ

```bash
pip install -r requirements.txt
export ANTHROPIC_API_KEY=sk-ant-...   # Windowsは set ANTHROPIC_API_KEY=...
python -m app.main
# → http://localhost:8000 をブラウザで開く
```

## 「印刷勘太郎から求むものリスト」との対応表

| リストの項目 | 本アプリでの実装 | 勘太郎側と決めること |
|---|---|---|
| 1. SFTP接続情報 | 基本はPULL方式（勘太郎が取りに来る）。PUSH方式も `sftp.push_enabled` で対応可（paramiko・SSH鍵認証） | ホスト/ポート/アカウント、鍵ペアはアプリ側で生成し公開鍵を渡す |
| 2. CSVフォーマット | `config.yaml` の csv セクション（encoding / newline / header / quoting / columns）。コード変更不要 | 文字コード・改行・列定義・桁数・囲み文字の正式仕様書 |
| 3. 命名規則 | `order_{timestamp}_{seq:03d}.csv`（秒タイムスタンプ+連番で重複防止） | 正式な命名規則の合意 |
| 3. 配置先ディレクトリ | `output.dir`（既定 `data/incoming/`） | 実際のパス |
| 3. 処理済みファイルの扱い | `archive/` `failed/` フォルダを用意。UIで3フォルダの状況を可視化 | 勘太郎側が取込後に削除するか移動するか |
| .doneトリガーファイル | CSVを完全に書き切った**後**に `.done` を作成。SFTP PUSH時も CSV→.done の順で送信 | 「.doneを見つけるまでCSVに触らない」ルールの合意 |
| 不完全CSVの防止 | `.tmp` に書いて `os.replace()` でrename（アトミック）。PUSH時もリモートで rename | — |
| 発生頻度 | `mode: realtime / batch`。realtimeは確定の都度出力、ファイル名衝突は連番で回避 | バッチか都度か、取込タイミング |
| SSH鍵認証 | パスワード不使用。Ed25519秘密鍵ファイルを参照（コードにハードコードしない） | 公開鍵の登録 |
| 固定IPアドレス制限 | ネットワーク側の設定事項。アプリサーバーのIPを固定し、勘太郎側FWで許可リスト化 | 許可IPの登録 |

## 運用上の設計判断

- **AIは下書き、確定は人**: AI抽出結果は必ず画面で目視確認してから出力する設計です。読取に不安がある箇所はAIが「注意」として画面に表示します。
- **バリデーション**: 必須項目・桁数・数値/日付形式に加え、**Shift_JISに変換できない文字**（例: 一部の環境依存文字）を出力前に検出します。
- **ログ**: すべての受付・抽出・出力を `app.log` に記録します（いつ・どのファイル・何明細）。
- **セキュリティ**: APIキーは環境変数、SFTPは鍵認証、ダウンロードAPIはパストラバーサル対策済み。

## ファイル構成

```
kantaro-csv-app/
├── config.yaml        # 勘太郎との協議結果をすべてここに反映（コード変更不要）
├── requirements.txt
├── app/
│   ├── main.py        # FastAPI（API + 画面配信）
│   ├── extractor.py   # Claude APIによる発注書読取
│   └── csv_writer.py  # 検証・CSV生成・アトミック書込・.done
├── static/index.html  # 画面（アップロード→確認→出力→フォルダ状況）
└── data/
    ├── uploads/   # アップロードされた発注書の保管（監査用）
    ├── incoming/  # 勘太郎がSFTPで見に来るフォルダ
    ├── archive/   # 取込済
    └── failed/    # エラー退避
```
