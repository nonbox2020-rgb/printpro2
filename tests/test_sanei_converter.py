"""三映CSV→CSV-B 変換の単体テスト(合成データのみ。顧客情報は含まない)。

  python tests/test_sanei_converter.py    # 依存: pyyaml のみ
"""
import csv
import io
import os
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from app.sanei_converter import SaneiConverter  # noqa: E402

CFG = yaml.safe_load(open(os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "sanei_config.yaml"), encoding="utf-8"))

# 合成CSV-A: タイトル→見出し→本番3行(うち1行裏)→空白→校正タイトル→見出し→校正1行
HEADER = "順,受注№,作品名,種類,下版,裏表,寸法,用紙,斤量,通し,色,部数,備考,加工,加工日,検品日,納期,得意先,付合情報"
SAMPLE = "\r\n".join([
    ",,,,印刷予定表,,,,2026-09-01 予定,,,,,,,,,,テスト社",
    HEADER,
    "1,9999001-00-00,テスト作品,B2ポスター,,表,4/6半裁,コート,90,1300,4/4c,2000,4/4c 2折(8P),断裁,,,,得意先,",
    "2,9999001-00-00,テスト作品,B2ポスター,,表,4/6半裁,コート,90,2500,4/1c,2000,4/1c 表紙,断裁,,,,得意先,",
    "3,9999002-00-00,裏だけ作品,B1ポスター,,裏,4/6全,コート,135,500,4/4c,500,4/4c,断裁,,,,得意先,",
    ",,,,,,,,,,,,,,,,,,",
    ",,,,,,,,,,,,,,,,,本機校正 テスト社",
    HEADER,
    "1,9999003-00-00,校正作品,DVDジャケット,,表,A半裁,コート,70.5,250,5/1c,1000,5/1c,断裁,,,,得意先,",
]) + "\r\n"


def run():
    conv = SaneiConverter(CFG)
    res = conv.convert(SAMPLE)
    cases = {(c["section"], c["order_no"]): c for c in res["cases"]}

    # 下版予定日: 1行目I列から取得
    assert res["plate_date"] == "2026/09/01", res["plate_date"]

    # 裏だけの案件は生成されず、警告に出る
    assert ("本番", "9999002-00-00") not in cases
    assert any("9999002-00-00" in w for w in res["warnings"])

    # 本番の複数行案件: 2行(裏除外後)、受注№でグループ化
    main = cases[("本番", "9999001-00-00")]
    assert main["src_count"] == 2, main["src_count"]
    r0, r1 = main["b_rows"]

    # 品名 = 受注№+作品名+種類(半角スペース)
    assert r0["product_name"] == "9999001-00-00 テスト作品 B2ポスター", r0["product_name"]
    # 仕上サイズ = B2、用紙/印刷サイズ変換
    assert r0["trim_size"] == "B2", r0["trim_size"]
    assert r0["paper_size"] == "46判" and r0["print_size"] == "46半"
    # 色数分解 4/4c → 4,4
    assert (r0["color_front"], r0["color_back"]) == ("4", "4")
    # 数量=部数(L), 印刷枚数=通し(J)
    assert r0["quantity"] == "2000" and r0["print_sheets"] == "1300"
    # 印刷項目: 備考から「2折」抽出
    assert r0["print_item"] == "2折", r0["print_item"]
    # 継続行の印刷枚数は各行の通し
    assert r1["print_sheets"] == "2500"
    # 納品日: 裏色数(T)=4(≠0) → +2営業日。9/1(火)+2 = 9/3(木)
    assert r0["delivery_date"] == "2026/09/03", r0["delivery_date"]

    # 校正案件: 品名末尾に本機校正、DVDジャケ判定、proofテンプレート
    proof = cases[("校正", "9999003-00-00")]
    pr = proof["b_rows"][0]
    assert pr["product_name"].endswith("本機校正"), pr["product_name"]
    assert pr["trim_size"] == "DVDジャケ"
    # 色数 5/1c → 5,1、裏≠0 → +2営業日
    assert (pr["color_front"], pr["color_back"]) == ("5", "1")
    assert pr["delivery_date"] == "2026/09/03"

    # CSV-B構造: 1行目=全35列、継続行=N〜AB(U除く)のみ
    b = conv.build_csv_b(main)
    assert b.decode("utf-8").count("\r\n") >= 2  # ヘッダ+2データ行
    rows = list(csv.reader(io.StringIO(b.decode("utf-8"), newline="")))
    assert len(rows) == 3 and all(len(r) == 35 for r in rows)
    # 継続行(rows[2]): A〜M と U,AC〜AI は空
    labels = [c["label"] for c in CFG["csv_b_columns"]]
    per_row = {c["label"] for c in CFG["csv_b_columns"] if c.get("per_row")}
    for lbl, val in zip(labels, rows[2]):
        if lbl not in per_row:
            assert val == "", f"継続行の非per_row列 {lbl} が空でない: {val!r}"

    print("✅ 全テスト合格 (案件数:", len(res["cases"]),
          "/ 警告:", len(res["warnings"]), ")")


if __name__ == "__main__":
    run()
