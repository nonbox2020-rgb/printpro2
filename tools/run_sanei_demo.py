"""三映CSV→CSV-B 変換のデモ実行。

  python tools/run_sanei_demo.py <CSV-Aファイル...> [--out 出力先ディレクトリ]

入力の三映CSV(顧客情報を含む)はリポジトリに含めない。手元のパスを指定する。
各案件ごとに CSV-B を出力し、標準出力に変換サマリと警告を表示する。
"""
import argparse
import os
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from app.sanei_converter import SaneiConverter  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("--config", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sanei_config.yaml"))
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    cfg = yaml.safe_load(open(args.config, encoding="utf-8"))
    conv = SaneiConverter(cfg)
    enc = cfg["input"]["encoding"]

    for path in args.inputs:
        raw = open(path, "rb").read()
        try:
            text = raw.decode(enc)
        except UnicodeDecodeError:
            text = raw.decode("utf-8", errors="replace")
        result = conv.convert(text)
        print("=" * 78)
        print(f"入力: {os.path.basename(path)}")
        print(f"下版予定日: {result['plate_date']}   案件数: {len(result['cases'])}")
        for w in result["warnings"]:
            print(f"  ⚠ {w}")
        for case in result["cases"]:
            n = len(case["b_rows"])
            fn = conv.filename_for(case, result["plate_date"])
            first = case["b_rows"][0]
            print(f"  ・{case['section']} 受注№{case['order_no']} "
                  f"({n}行) → {fn}")
            print(f"      品名={first['product_name']!r}")
            print(f"      仕上={first['trim_size']!r} 用紙サイズ={first['paper_size']!r} "
                  f"印刷サイズ={first['print_size']!r} 色数={first['color_front']}/{first['color_back']} "
                  f"納品日={first['delivery_date']!r}")
            for w in case["warnings"]:
                print(f"      ⚠ {w}")
            if args.out:
                os.makedirs(args.out, exist_ok=True)
                with open(os.path.join(args.out, fn), "wb") as f:
                    f.write(conv.build_csv_b(case))
    if args.out:
        print(f"\nCSV-B を {args.out} に書き出しました。")


if __name__ == "__main__":
    main()
