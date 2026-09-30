"""架空サンプル(tests/samples/)を変換し、正解(tests/expected/)と1バイトずつ比べるテスト。

  python tests/test_samples.py            # テスト(依存: pyyaml・jpholiday)
  python tests/test_samples.py --update   # 変換ルールを意図して変えたとき、正解を作り直す

サンプルはすべて架空データ。実際の三映CSV(顧客情報を含む)はリポジトリに入れない。
  sample_A … 基本(本番4案件+校正1案件、「裏」だけの案件は出力しない)
  sample_B … 年末(12/30下版。元日をまたぐ納品日)
  sample_C … 先頭に列が1つ多い(見出し名で読むので結果は A と同じ)
  sample_D … 変換表に無い寸法(4/6四裁)→ 警告が出る
  sample_E … 3連休の前(10/9下版、10/12スポーツの日をとばす)
  sample_F … 文化の日の前日(11/2下版)＋校正2案件
  sample_G … ゴールデンウィーク(2027/4/28下版、4/29と5/3〜5/5をとばす)
  sample_H … 忙しい日(本番12案件・校正3案件。変換表の寸法・色の書き方いろいろ・DVDジャケット)
  sample_I … 確認が要るもの(表に無い寸法・「裏」だけの案件・校正のDVDジャケット)
  sample_J … 見出しの名前と列の並びが違う(中身は E と同じなので、結果も E と同じ)
  sample_K … UTF-8・改行LF(Googleスプレッドシートで作ったCSVなど)
  sample_L … 同じ受注№がもう一度届く(A の 9000101 を部数変更で再送)
"""
import csv
import io
import os
import shutil
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from app.sanei_converter import SaneiConverter  # noqa: E402

SAMPLES = os.path.join(ROOT, "tests", "samples")
EXPECTED = os.path.join(ROOT, "tests", "expected")
CFG = yaml.safe_load(open(os.path.join(ROOT, "sanei_config.yaml"), encoding="utf-8"))


def convert_all() -> dict:
    """サンプルごとに ({ファイル名: CSV-Bのバイト列}, [警告]) を返す。"""
    conv = SaneiConverter(CFG)
    out = {}
    for name in sorted(os.listdir(SAMPLES)):
        if not name.endswith(".csv"):
            continue
        raw = open(os.path.join(SAMPLES, name), "rb").read()
        try:  # アプリと同じ順で読む(UTF-8 → だめなら Shift_JIS)
            text = raw.decode("utf-8-sig")
        except UnicodeDecodeError:
            text = raw.decode(CFG["input"].get("encoding", "cp932"))
        res = conv.convert(text)
        files = {conv.filename_for(c, res["plate_date"]): conv.build_csv_b(c) for c in res["cases"]}
        assert len(files) == len(res["cases"]), f"{name}: 出力ファイル名が重複しています"
        warnings = res["warnings"] + [w for c in res["cases"] for w in c["warnings"]]
        out[name[:-4]] = (files, warnings)
    return out


def first_difference(expected: bytes, actual: bytes) -> str:
    """どの行・どの列が違うかを、列名つきで1か所だけ示す。"""
    labels = [c["label"] for c in CFG["csv_b_columns"]]
    exp = list(csv.reader(io.StringIO(expected.decode("utf-8-sig"), newline="")))
    act = list(csv.reader(io.StringIO(actual.decode("utf-8-sig"), newline="")))
    for i, (e, a) in enumerate(zip(exp, act), start=1):
        for j, (ev, av) in enumerate(zip(e, a)):
            if ev != av:
                label = labels[j] if j < len(labels) else f"{j + 1}列目"
                return f"{i}行目「{label}」: 正解 {ev!r} ／ 結果 {av!r}"
        if len(e) != len(a):
            return f"{i}行目: 列の数が違います(正解 {len(e)} ／ 結果 {len(a)})"
    if len(exp) != len(act):
        return f"行の数が違います(正解 {len(exp)} ／ 結果 {len(act)})"
    return "文字コード・改行・BOMなど、見た目以外が違います"


def update(results: dict):
    for sample, (files, warnings) in results.items():
        d = os.path.join(EXPECTED, sample)
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        for fn, data in files.items():
            with open(os.path.join(d, fn), "wb") as f:
                f.write(data)
        with open(os.path.join(d, "warnings.txt"), "w", encoding="utf-8", newline="\n") as f:
            f.writelines(w + "\n" for w in warnings)
    print(f"正解を作り直しました: {EXPECTED}(差分を確認してから納めてください)")


def check(results: dict) -> list:
    problems = []
    for sample, (files, warnings) in results.items():
        d = os.path.join(EXPECTED, sample)
        if not os.path.isdir(d):
            problems.append(f"{sample}: 正解のフォルダがありません(--update で作成)")
            continue
        want = sorted(f for f in os.listdir(d) if f.endswith(".csv"))
        if want != sorted(files):
            problems.append(f"{sample}: 出力ファイルの一覧が違います\n    正解: {want}\n    結果: {sorted(files)}")
        for fn in sorted(set(want) & set(files)):
            expected = open(os.path.join(d, fn), "rb").read()
            if expected != files[fn]:
                problems.append(f"{sample}/{fn}: {first_difference(expected, files[fn])}")
        want_w = open(os.path.join(d, "warnings.txt"), encoding="utf-8").read().splitlines()
        if want_w != warnings:
            problems.append(f"{sample}: 警告が違います\n    正解: {want_w}\n    結果: {warnings}")
    return problems


def main():
    results = convert_all()
    if "--update" in sys.argv:
        update(results)
        return
    problems = check(results)
    if problems:
        print("❌ 変換結果が正解と違います:")
        for p in problems:
            print("  - " + p)
        print("変換ルールをわざと変えた場合は、python tests/test_samples.py --update で正解を作り直してください。")
        sys.exit(1)
    n = sum(len(f) for f, _ in results.values())
    print(f"✅ 架空サンプル {len(results)}件・CSV-B {n}ファイルがすべて正解と一致")


if __name__ == "__main__":
    main()
