"""三映CSV(CSV-A) → 印刷勘太郎向けCSV(CSV-B) 変換エンジン。

設計方針:
  - 変換ルールはすべて sanei_config.yaml に外出しし、このコードには
    業務固有の値を直書きしない(GAS版へ移す際はシートへ転記する)。
  - AIは使わない。決定的(ルールベース)な変換のみ。
  - 判断に迷う値は握りつぶさず、警告(warnings)として呼び出し側へ返す。
    → 画面(確認工程)で人が目視・修正してから確定する前提。

処理の流れ:
  parse_csv_a()  CSV-A本文 → セクション(本番/校正)ごとのデータ行
  convert()      → 案件(1受注№=1ファイル分)のリスト。各案件は複数行を持つ
  build_csv_b()  1案件 → CSV-B本文(1行目=全35列、2行目以降=N〜AB のみ)
"""
import csv
import datetime as _dt
import io
import re
import unicodedata


class SaneiConverter:
    def __init__(self, config: dict):
        self.cfg = config
        self.cols = config["input"]["columns"]
        self._holidays = set(config["delivery"].get("holidays_2026", [])) | \
            set(config["delivery"].get("company_closed", []))

    # ---------------- CSV-A の解釈 ----------------

    def parse_csv_a(self, text: str) -> dict:
        """CSV-A本文を解釈し、下版予定日とセクション別データ行を返す。

        戻り値: {"plate_date": "YYYY/MM/DD" or "", "rows": [(section, row_list), ...]}
        section は "本番" または "校正"。row_list は元の1行(list)。
        """
        rows = list(csv.reader(io.StringIO(text, newline="")))
        if not rows:
            return {"plate_date": "", "rows": []}

        # 1行目(タイトル行)のI列から日付を取り出す
        dcol = self.cfg["input"]["title_date_col"]
        raw_date = rows[0][dcol] if len(rows[0]) > dcol else ""
        plate_date = self._parse_date(raw_date)

        header_first = self.cfg["input"]["header_first_cell"]
        proof_marker = self.cfg["input"]["proof_marker"]

        out_rows = []
        section = "本番"
        for idx, r in enumerate(rows):
            if idx == 0:
                continue  # タイトル行
            first = (r[0].strip() if r else "")
            if self._is_blank(r):
                continue  # 空白行(セクション境界。次のマーカー行で校正へ切替)
            # 校正タイトル行: A列が空 かつ 本機校正 を含む
            if first == "" and proof_marker in "".join(r):
                section = "校正"
                continue
            if first == header_first:
                continue  # 見出し行
            out_rows.append((section, r))
        return {"plate_date": plate_date, "rows": out_rows}

    def convert(self, text: str) -> dict:
        """CSV-A本文 → 案件リスト。

        戻り値: {"plate_date":..., "cases":[case,...], "warnings":[...]}
        case = {"section", "order_no", "b_rows":[dict,...(CSV-Bの各行)],
                "src_count", "warnings":[...]}
        """
        parsed = self.parse_csv_a(text)
        plate_date = parsed["plate_date"]
        warnings = []
        if not plate_date:
            warnings.append("1行目のI列から下版予定日を取得できませんでした")

        skip_val = self.cfg["skip_side_value"]
        c = self.cols

        # セクション+受注№でグルーピング(出現順を保持)。裏行はここで除外。
        groups = {}          # (section, no) -> [src_row,...]
        order = []           # キーの出現順
        dropped_all_ura = {} # (section,no) -> 元行数(全部裏で0行になった案件)
        raw_counts = {}
        for section, r in parsed["rows"]:
            no = self._cell(r, c["order_no"]).strip()
            if not no:
                continue
            key = (section, no)
            raw_counts[key] = raw_counts.get(key, 0) + 1
            if self._cell(r, c["side"]).strip() == skip_val:
                continue  # 裏行はスキップ
            if key not in groups:
                groups[key] = []
                order.append(key)
            groups[key].append(r)

        # 全行が裏で0行になった案件を検出(発注取りこぼし防止のため通知)
        for key, cnt in raw_counts.items():
            if key not in groups:
                dropped_all_ura[key] = cnt

        cases = []
        for key in order:
            section, no = key
            src_rows = groups[key]
            case_w = []
            b_rows = [self._build_row(src, section, plate_date, i == 0, case_w)
                      for i, src in enumerate(src_rows)]
            cases.append({"section": section, "order_no": no,
                          "b_rows": b_rows, "src_count": len(src_rows),
                          "warnings": case_w})
        for (section, no), cnt in dropped_all_ura.items():
            warnings.append(f"[裏のみ] {section} 受注№{no}: {cnt}行すべて「裏」→ "
                            f"CSV-B生成なし(仕様どおりか要確認②)")
        return {"plate_date": plate_date, "cases": cases, "warnings": warnings}

    # ---------------- 1行分の各列を計算 ----------------

    def _build_row(self, src: list, section: str, plate_date: str,
                   is_first: bool, warns: list) -> dict:
        c = self.cols
        f = self.cfg["fixed"]
        get = lambda k: self._cell(src, c[k]).strip()

        paper_size, print_size = self._convert_size(get("dimension"), warns)
        front, back = self._split_color(get("color"))
        is_jacket = False
        trim = ""
        if is_first:
            trim = self._trim_size(get("kind"))
            is_jacket = (trim == self.cfg["trim_size"]["dvd_jacket_value"])

        row = {
            # --- 1行目のみ(A〜M, U, AC〜AI) ---
            "sales_code": f["sales_code"],
            "customer_code": f["customer_code"],
            "product_name": self._product_name(src, section),
            "edition": f["edition"],
            "trim_size": trim,
            "pages": f["pages"],
            "quantity": get("copies"),                 # G 数量 ← L 部数
            "plate_date": plate_date,                   # H 下版予定日
            "delivery_date": self._delivery_date(plate_date, back),  # I 納品日
            "delivery_time": f["delivery_time"],
            "paper_arrange": f["paper_arrange"],
            "plate_form": f["plate_form"],
            "platemaking": f["platemaking"],
            "imposition": "",                           # U 面付(現状未使用)
            "delivery_method": f["delivery_method"],
            "shipper": "",                              # AD 荷主名(未使用)
            "invoice": f["invoice"],
            "delivery_note": self._tpl("delivery_note", section, is_jacket, warns),
            "plate_note": self._tpl("plate_note", section, is_jacket, warns),
            "print_note": self._tpl("print_note", section, is_jacket, warns),
            "bind_note": "",                            # AI 製本備考(未使用)
            # --- 継続行にも入る(N〜AB のうち U以外) ---
            "paper_brand": get("paper"),                # N 用紙銘柄 ← H 用紙
            "paper_size": paper_size,                   # O 用紙サイズ ← G 寸法
            "grain": "",                                # P 紙目(未使用)
            "weight": get("weight"),                    # Q 斤量 ← I 斤量
            "print_item": self._print_item(get("note")),# R 印刷項目 ← M 備考
            "color_front": front,                       # S 色数(表) ← K 色
            "color_back": back,                         # T 色数(裏) ← K 色
            "units": f["units"],                        # V 台数
            "print_size": print_size,                   # W 印刷サイズ ← G 寸法
            "print_sheets": get("through"),             # X 印刷枚数 ← J 通し
            "spare": "",                                # Y 予備(未使用)
            "print_place": f["print_place"],            # Z 印刷場所
            "print_start": "",                          # AA 印刷開始日(未使用)
            "print_end": "",                            # AB 印刷終了日(未使用)
        }
        return row

    # ---------------- 個別の変換ロジック ----------------

    def _product_name(self, src: list, section: str) -> str:
        pn = self.cfg["product_name"]
        parts = [self._cell(src, self.cols[k]).strip() for k in pn["parts"]]
        name = pn["separator"].join(p for p in parts if p)
        if section == "校正" and pn.get("proof_suffix"):
            name = (name + pn["separator"] + pn["proof_suffix"]).strip()
        return name

    def _convert_size(self, dim: str, warns: list) -> tuple:
        """寸法(G) → (用紙サイズ, 印刷サイズ)。表優先、無ければ規則で推定。"""
        if not dim:
            return "", ""
        table = self.cfg["size_table"]
        if dim in table:
            return table[dim]["paper"], table[dim]["print"]
        # 規則推定: プレフィックスを取り出し、全判/半裁の別で組み立てる
        prefix = dim
        for suf in ("全判", "半裁", "全", "半", "判", "裁"):
            if prefix.endswith(suf):
                prefix = prefix[: -len(suf)]
                break
        for k, v in self.cfg.get("size_prefix_map", {}).items():
            prefix = prefix.replace(k, v)
        kind = "半" if ("半" in dim) else ("全" if "全" in dim else "")
        paper = prefix + "判"
        pr = prefix + kind if kind else prefix
        warns.append(f"[寸法推定] 「{dim}」は変換表に無いため推定 "
                     f"→ 用紙:{paper} / 印刷:{pr}(要確認 B-2)")
        return paper, pr

    def _split_color(self, val: str) -> tuple:
        """色(K) → (表, 裏)。例 4/4c→(4,4)  4→(4,0)  5/1c→(5,1)"""
        if not val:
            return "", ""
        v = val.strip()
        for ch in self.cfg["color"]["strip_chars"]:
            v = v.replace(ch, "")
        default_back = self.cfg["color"]["default_back"]
        if "/" in v:
            fp, bp = v.split("/", 1)
        else:
            fp, bp = v, default_back
        return self._lead_int(fp, ""), self._lead_int(bp, default_back)

    def _trim_size(self, kind: str) -> str:
        """種類(D) → 仕上サイズ(E)。定型のみ。該当なしは空白。"""
        if not kind:
            return ""
        ts = self.cfg["trim_size"]
        if ts["dvd_jacket_source"] in unicodedata.normalize("NFKC", kind) \
                or ts["dvd_jacket_source"] in kind:
            return ts["dvd_jacket_value"]
        norm = unicodedata.normalize("NFKC", kind)
        for p in ts.get("patterns", []):
            m = re.search(p["re"], norm)
            if m:
                out = p["out"]
                for i, g in enumerate(m.groups(), start=1):
                    out = out.replace(f"${i}", g or "")
                return out
        return ""

    def _print_item(self, note: str) -> str:
        """備考(M) → 印刷項目(R)。最初に一致した折/表紙を返す。"""
        if not note:
            return ""
        norm = unicodedata.normalize("NFKC", note)
        for pat in self.cfg["print_item"]["patterns"]:
            m = re.search(pat, norm)
            if m:
                return m.group(0)
        return ""

    def _delivery_date(self, plate_date: str, color_back: str) -> str:
        """納品日(I): 裏色数(T)=0 なら+1営業日、それ以外は+2営業日。"""
        if not plate_date:
            return ""
        d = self.cfg["delivery"]
        try:
            back = int(color_back) if color_back not in ("", None) else 0
        except ValueError:
            back = 0
        offset = d["side_color_zero_offset"] if back == 0 \
            else d["side_color_nonzero_offset"]
        base = _dt.datetime.strptime(plate_date, "%Y/%m/%d").date()
        return self._add_business_days(base, offset).strftime("%Y/%m/%d")

    def _tpl(self, name: str, section: str, is_jacket: bool, warns: list) -> str:
        t = self.cfg["templates"][name]
        if section == "校正":
            if is_jacket and "proof_jacket" not in t:
                warns.append(f"[文面未定義] 校正×ジャケットの{name}が仕様書に無い"
                             f"(要確認 A-5)。校正(非ジャケ)文面で代用")
            return t.get("proof_jacket") if (is_jacket and "proof_jacket" in t) \
                else t.get("proof", "")
        return t.get("jacket", t["main"]) if is_jacket else t["main"]

    # ---------------- CSV-B の生成 ----------------

    def build_csv_b(self, case: dict) -> bytes:
        """1案件 → CSV-B本文(bytes)。1行目=全35列、2行目以降=N〜AB のみ。"""
        cols = self.cfg["csv_b_columns"]
        out = self.cfg["output"]
        buf = io.StringIO()
        quoting = {"all": csv.QUOTE_ALL, "minimal": csv.QUOTE_MINIMAL,
                   "none": csv.QUOTE_NONE}[out.get("quoting", "minimal")]
        w = csv.writer(buf, quoting=quoting, lineterminator=out.get("newline", "\r\n"))
        if out.get("header", True):
            w.writerow([col["label"] for col in cols])
        for i, brow in enumerate(case["b_rows"]):
            if i == 0:
                line = [brow.get(col["key"], "") for col in cols]
            else:  # 継続行: per_row の列のみ、他は空
                line = [brow.get(col["key"], "") if col.get("per_row") else ""
                        for col in cols]
            w.writerow(line)
        data = buf.getvalue()
        if out.get("bom") and out.get("encoding", "utf-8").startswith("utf-8"):
            return b"\xef\xbb\xbf" + data.encode(out["encoding"])
        return data.encode(out.get("encoding", "utf-8"))

    def filename_for(self, case: dict, plate_date: str) -> str:
        pat = self.cfg["output"]["filename_pattern"]
        return pat.format(no=case["order_no"],
                          date=(plate_date or "nodate").replace("/", ""),
                          seg=case["section"])

    # ---------------- 補助 ----------------

    @staticmethod
    def _cell(row: list, idx: int) -> str:
        return row[idx] if 0 <= idx < len(row) else ""

    @staticmethod
    def _is_blank(row: list) -> bool:
        return all((c or "").strip() == "" for c in row)

    @staticmethod
    def _lead_int(s: str, default: str) -> str:
        m = re.match(r"\s*(\d+)", s or "")
        return m.group(1) if m else default

    @staticmethod
    def _parse_date(raw: str) -> str:
        """"2026-08-27 予定" / "2026/8/27" → "2026/08/27" """
        if not raw:
            return ""
        m = re.search(r"(\d{4})[-/](\d{1,2})[-/](\d{1,2})", raw)
        if not m:
            return ""
        return f"{m.group(1)}/{int(m.group(2)):02d}/{int(m.group(3)):02d}"

    def _add_business_days(self, base: "_dt.date", n: int) -> "_dt.date":
        d = base
        added = 0
        while added < n:
            d = d + _dt.timedelta(days=1)
            if d.weekday() >= 5:  # 土(5)日(6)
                continue
            if d.strftime("%Y/%m/%d") in self._holidays:
                continue
            added += 1
        return d
