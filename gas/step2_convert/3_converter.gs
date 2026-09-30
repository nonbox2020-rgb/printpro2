// ===== 変換のしくみ（三映CSV → 勘太郎CSV）=====
// アプリの app/sanei_converter.py と同じ動き。ルールは 2_rules.gs（RULES）にある。
// AIは使わない。迷う値は握りつぶさず「警告」にする（警告は「変換の記録」とメールで知らせる）。
//
// 使い方: const res = SaneiConverter.convert(三映CSVの文字列, RULES);
//   res.plateDate … 下版予定日（例 2026/10/01）
//   res.warnings  … ファイル全体の知らせ（「裏」だけの案件など）
//   res.cases     … 1案件ずつ { section, orderNo, rowCount, warnings, fileName, csv }

const SaneiConverter = (function () {

  function convert(text, R) {
    const parsed = parseCsvA(text, R);
    const plateDate = parsed.plateDate;
    const warnings = [];
    if (!plateDate) warnings.push('1行目のI列から下版予定日を取得できませんでした');

    // 区分（本番/校正）＋受注№ でまとめる（出てきた順）。「裏」の行はここで外す
    const c = R.input.columns;
    const groups = new Map();
    const rawCounts = new Map();
    parsed.rows.forEach(function (item) {
      const section = item[0], r = item[1];
      const no = cell(r, c.order_no).trim();
      if (!no) return;
      const key = section + '\t' + no;
      rawCounts.set(key, (rawCounts.get(key) || 0) + 1);
      if (cell(r, c.side).trim() === R.skip_side_value) return;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(r);
    });

    const cases = [];
    groups.forEach(function (rows, key) {
      const section = key.split('\t')[0], no = key.split('\t')[1];
      const caseWarnings = [];
      const bRows = rows.map(function (src, i) { return buildRow(src, section, plateDate, i === 0, caseWarnings, R); });
      const kase = { section: section, orderNo: no, rowCount: rows.length, warnings: caseWarnings, rows: bRows };
      kase.fileName = fileName(kase, plateDate, R);
      kase.csv = buildCsvB(kase, R);
      cases.push(kase);
    });
    // すべて「裏」で1行も残らなかった案件は、取りこぼしが無いように知らせる
    rawCounts.forEach(function (cnt, key) {
      if (groups.has(key)) return;
      warnings.push('[裏のみ] ' + key.split('\t')[0] + ' 受注№' + key.split('\t')[1] + ': ' + cnt +
        '行すべて「裏」→ CSV-B生成なし(仕様どおり。表の処理で完結済み)');
    });
    return { plateDate: plateDate, cases: cases, warnings: warnings };
  }

  // ---------------- 三映CSVの読み方 ----------------

  // 列は位置ではなく見出し行の名前で探す。必要な列が無ければ推測せずエラーにする
  function parseCsvA(text, R) {
    const rows = parseCsv(text);
    const marker = R.input.proof_marker;
    const out = [];
    let colmap = null, section = '本番', plateDate = '';
    rows.forEach(function (r) {
      if (isBlank(r)) return;                       // 空白行（本番と校正の境目）
      const found = headerMap(r, R);
      if (found) { colmap = found; return; }        // 見出し行（本番・校正それぞれの先頭）
      if (!colmap) { plateDate = plateDate || titleDate(r, R); return; }   // タイトル行
      if (r.join('').indexOf(marker) >= 0 && !cell(r, colmap.order_no).trim()) {
        section = '校正';                           // 「本機校正」の行から先は校正
        return;
      }
      out.push([section, canonical(r, colmap, R)]);
    });
    if (rows.length && !colmap) {
      throw new Error('三映CSVの見出し行(順・受注№・寸法…)が見つかりません。三映から届いた元のCSVかどうか確認してください');
    }
    return { plateDate: plateDate, rows: out };
  }

  function headerMap(row, R) {
    const spec = R.input.header_names;
    const norm = row.map(normHeader);
    const found = {};
    Object.keys(spec).forEach(function (key) {
      const cands = spec[key].map(normHeader);
      const idx = norm.findIndex(function (h) { return cands.indexOf(h) >= 0; });
      if (idx >= 0) found[key] = idx;
    });
    if (Object.keys(found).length < 5) return null;   // 見出しがほとんど無い行 = タイトル行・明細行
    const missing = R.input.required_headers.filter(function (k) { return !(k in found); });
    if (missing.length) {
      throw new Error('三映CSVの見出し行に必要な列がありません: ' +
        missing.map(function (k) { return spec[k][0]; }).join('・') +
        '(見出し行: ' + row.map(function (s) { return s.trim(); }).filter(function (s) { return s; }).join('・') + ')');
    }
    return found;
  }

  function canonical(row, colmap, R) {
    const cols = R.input.columns;
    const size = Math.max.apply(null, Object.keys(cols).map(function (k) { return cols[k]; })) + 1;
    const out = [];
    for (let i = 0; i < size; i++) out.push('');
    Object.keys(colmap).forEach(function (key) { if (key in cols) out[cols[key]] = cell(row, colmap[key]); });
    return out;
  }

  function titleDate(row, R) {
    const d = R.input.title_date_col;
    const cells = (d >= 0 && d < row.length ? [row[d]] : []).concat(row);
    for (let i = 0; i < cells.length; i++) {
      const p = parseDate(cells[i]);
      if (p) return p;
    }
    return '';
  }

  // 見出しの表記ゆれを吸収（全角/半角・№/No・空白）
  function normHeader(s) {
    return (s || '').normalize('NFKC').replace(/\s/g, '');
  }

  // ---------------- 1行分の各列 ----------------

  function buildRow(src, section, plateDate, isFirst, warns, R) {
    const c = R.input.columns, f = R.fixed;
    const get = function (k) { return cell(src, c[k]).trim(); };
    const size = convertSize(get('dimension'), warns, R);
    const color = splitColor(get('color'), R);
    let isJacket = false, trim = '';
    if (isFirst) {
      trim = trimSize(get('kind'), R);
      isJacket = trim === R.trim_size.dvd_jacket_value;
    }
    return {
      // 1行目だけに入る列（A〜M, U, AC〜AI）
      sales_code: f.sales_code,
      customer_code: f.customer_code,
      product_name: productName(src, section, R),
      edition: f.edition,
      trim_size: trim,
      pages: f.pages,
      quantity: get('copies'),                                  // G 数量 ← 部数
      plate_date: plateDate,                                    // H 下版予定日
      delivery_date: deliveryDate(plateDate, color[1], R),      // I 納品日
      delivery_time: f.delivery_time,
      paper_arrange: f.paper_arrange,
      plate_form: f.plate_form,
      platemaking: f.platemaking,
      imposition: '',
      delivery_method: f.delivery_method,
      shipper: '',
      invoice: f.invoice,
      delivery_note: tpl('delivery_note', section, isJacket, warns, R),
      plate_note: tpl('plate_note', section, isJacket, warns, R),
      print_note: tpl('print_note', section, isJacket, warns, R),
      bind_note: '',
      // 続きの行にも入る列（N〜AB のうち U 以外）
      paper_brand: get('paper'),                                // N 用紙銘柄 ← 用紙
      paper_size: size[0],                                      // O 用紙サイズ ← 寸法
      grain: '',
      weight: get('weight'),                                    // Q 斤量
      print_item: printItem(get('note'), R),                    // R 印刷項目 ← 備考
      color_front: color[0],                                    // S 色数（表）
      color_back: color[1],                                     // T 色数（裏）
      units: f.units,
      print_size: size[1],                                      // W 印刷サイズ ← 寸法
      print_sheets: get('through'),                             // X 印刷枚数 ← 通し
      spare: '',
      print_place: f.print_place,
      print_start: '',
      print_end: '',
    };
  }

  function productName(src, section, R) {
    const pn = R.product_name;
    const parts = pn.parts.map(function (k) { return cell(src, R.input.columns[k]).trim(); })
      .filter(function (p) { return p; });
    let name = parts.join(pn.separator);
    if (section === '校正' && pn.proof_suffix) name = (name + pn.separator + pn.proof_suffix).trim();
    return name;
  }

  // 寸法 → [用紙サイズ, 印刷サイズ]。表にあれば表、無ければ規則で推定して警告
  function convertSize(dim, warns, R) {
    if (!dim) return ['', ''];
    const table = R.size_table;
    if (Object.prototype.hasOwnProperty.call(table, dim)) return [table[dim].paper, table[dim].print];
    let prefix = dim;
    const sufs = ['全判', '半裁', '全', '半', '判', '裁'];
    for (let i = 0; i < sufs.length; i++) {
      if (prefix.endsWith(sufs[i])) { prefix = prefix.slice(0, -sufs[i].length); break; }
    }
    const map = R.size_prefix_map || {};
    Object.keys(map).forEach(function (k) { prefix = prefix.split(k).join(map[k]); });
    const kind = dim.indexOf('半') >= 0 ? '半' : (dim.indexOf('全') >= 0 ? '全' : '');
    const paper = prefix + '判';
    const pr = kind ? prefix + kind : prefix;
    warns.push('[寸法推定] 「' + dim + '」は変換表に無いため推定 → 用紙:' + paper + ' / 印刷:' + pr + '(要確認 B-2)');
    return [paper, pr];
  }

  // 色 → [表, 裏]。例 4/4c → 4,4  4 → 4,0  5/1c → 5,1
  function splitColor(val, R) {
    if (!val) return ['', ''];
    let v = val.trim();
    Array.from(R.color.strip_chars).forEach(function (ch) { v = v.split(ch).join(''); });
    const def = R.color.default_back;
    const i = v.indexOf('/');
    const fp = i >= 0 ? v.slice(0, i) : v;
    const bp = i >= 0 ? v.slice(i + 1) : def;
    return [leadInt(fp, ''), leadInt(bp, def)];
  }

  // 種類 → 仕上サイズ（定型のみ。該当なしは空白）
  function trimSize(kind, R) {
    if (!kind) return '';
    const ts = R.trim_size;
    const norm = kind.normalize('NFKC');
    if (norm.indexOf(ts.dvd_jacket_source) >= 0 || kind.indexOf(ts.dvd_jacket_source) >= 0) return ts.dvd_jacket_value;
    const pats = ts.patterns || [];
    for (let i = 0; i < pats.length; i++) {
      const m = norm.match(new RegExp(pats[i].re));
      if (m) {
        let out = pats[i].out;
        for (let g = 1; g < m.length; g++) out = out.split('$' + g).join(m[g] || '');
        return out;
      }
    }
    return '';
  }

  // 備考 → 印刷項目（最初に一致した 表紙 / ○折）
  function printItem(note, R) {
    if (!note) return '';
    const norm = note.normalize('NFKC');
    const pats = R.print_item.patterns;
    for (let i = 0; i < pats.length; i++) {
      const m = norm.match(new RegExp(pats[i]));
      if (m) return m[0];
    }
    return '';
  }

  // 納品日: 裏の色数が0なら +1営業日、それ以外は +2営業日
  function deliveryDate(plateDate, colorBack, R) {
    if (!plateDate) return '';
    const d = R.delivery;
    let back = 0;
    if (colorBack !== '' && colorBack != null) {
      const n = toInt(colorBack);
      back = n === null ? 0 : n;
    }
    const offset = back === 0 ? d.side_color_zero_offset : d.side_color_nonzero_offset;
    return fmt(addBusinessDays(ymd(plateDate), offset, R));
  }

  function tpl(name, section, isJacket, warns, R) {
    const t = R.templates[name];
    const has = function (k) { return Object.prototype.hasOwnProperty.call(t, k); };
    if (section === '校正') {
      if (isJacket && !has('proof_jacket')) {
        warns.push('[文面未定義] 校正×ジャケットの' + name + 'が仕様書に無い(要確認 A-5)。校正(非ジャケ)文面で代用');
      }
      return (isJacket && has('proof_jacket')) ? t.proof_jacket : (has('proof') ? t.proof : '');
    }
    return isJacket ? (has('jacket') ? t.jacket : t.main) : t.main;
  }

  // ---------------- 勘太郎CSVを作る ----------------

  // 1案件 → CSVの文字列（1行目=見出し、次の行=35列すべて、続きの行=N〜AB だけ）。BOM は保存するときに付ける
  function buildCsvB(kase, R) {
    const cols = R.csv_b_columns, out = R.output;
    const mode = out.cell_newline || 'crlf';
    const term = out.newline || '\r\n';
    const quoting = out.quoting || 'minimal';
    const lines = [];
    if (out.header !== false) lines.push(cols.map(function (col) { return cellNewline(col.label, mode); }));
    kase.rows.forEach(function (row, i) {
      lines.push(cols.map(function (col) {
        if (i > 0 && !col.per_row) return '';
        return cellNewline(col.key in row ? row[col.key] : '', mode);
      }));
    });
    return lines.map(function (line) {
      return line.map(function (v) { return quote(v, quoting, term); }).join(',') + term;
    }).join('');
  }

  function quote(v, quoting, term) {
    const special = /[,"\r\n]/.test(v) || Array.from(term).some(function (ch) { return v.indexOf(ch) >= 0; });
    if (quoting === 'all' || (quoting === 'minimal' && special)) return '"' + v.split('"').join('""') + '"';
    return v;
  }

  function cellNewline(value, mode) {
    if (!value) return value;
    const v = value.split('\r\n').join('\n').split('\r').join('\n');
    if (mode === 'crlf') return v.split('\n').join('\r\n');
    if (mode === 'space') return v.split('\n').join(' ');
    if (mode === 'remove') return v.split('\n').join('');
    return v;
  }

  function fileName(kase, plateDate, R) {
    return R.output.filename_pattern
      .split('{no}').join(kase.orderNo)
      .split('{date}').join((plateDate || 'nodate').split('/').join(''))
      .split('{seg}').join(kase.section);
  }

  // ---------------- CSV を読む（" で囲まれたセルの中のカンマ・改行もそのまま）----------------

  function parseCsv(text) {
    const rows = [];
    let row = [], field = '', state = 'start';   // start / plain / quoted / quote（" の直後）
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (state === 'quoted') {
        if (ch === '"') state = 'quote'; else field += ch;
        continue;
      }
      if (state === 'quote') {
        if (ch === '"') { field += '"'; state = 'quoted'; continue; }
        state = 'plain';
      }
      if (ch === ',') { row.push(field); field = ''; state = 'start'; continue; }
      if (ch === '\r' || ch === '\n') {
        row.push(field); rows.push(row); row = []; field = ''; state = 'start';
        if (ch === '\r' && text[i + 1] === '\n') i++;
        continue;
      }
      if (ch === '"' && state === 'start') { state = 'quoted'; continue; }
      field += ch;
      state = 'plain';
    }
    if (state !== 'start' || field !== '' || row.length) { row.push(field); rows.push(row); }
    return rows;
  }

  // ---------------- 日付・祝日 ----------------

  // 「2026-08-27 予定」「2026/8/27」→ 2026/08/27
  function parseDate(raw) {
    if (!raw) return '';
    const m = raw.match(/(\p{Nd}{4})[-/](\p{Nd}{1,2})[-/](\p{Nd}{1,2})/u);
    if (!m) return '';
    return m[1] + '/' + pad2(toInt(m[2])) + '/' + pad2(toInt(m[3]));
  }

  // 土日・国民の祝日・会社の休業日を数えずに n 営業日進める
  function addBusinessDays(base, n, R) {
    const closed = {};
    (R.delivery.company_closed || []).forEach(function (v) { closed[fmt(closedDay(v))] = true; });
    let d = base, added = 0;
    while (added < n) {
      d = addDays(d, 1);
      const dow = d.getUTCDay();
      if (dow === 0 || dow === 6 || isJapaneseHoliday(d) || closed[fmt(d)]) continue;
      added++;
    }
    return d;
  }

  function closedDay(v) {
    const m = String(v).match(/^\s*(\d{4})[/-](\d{1,2})[/-](\d{1,2})\s*$/);
    const d = m && new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
    if (!d || d.getUTCMonth() !== +m[2] - 1 || d.getUTCDate() !== +m[3]) {
      throw new Error('2_rules.gs の company_closed に日付として読めない値があります: ' + v + '（例: \'2026/12/31\'）');
    }
    return d;
  }

  // 国民の祝日（2020年以降の祝日法。振替休日・国民の休日を含む）
  function isJapaneseHoliday(d) {
    return baseHoliday(d) || substituteHoliday(d) || citizensHoliday(d);
  }

  function baseHoliday(d) {
    const y = d.getUTCFullYear(), m = d.getUTCMonth() + 1, day = d.getUTCDate(), dow = d.getUTCDay();
    const monday = function (n) { return dow === 1 && day > (n - 1) * 7 && day <= n * 7; };   // 第n月曜
    switch (m) {
      case 1: return day === 1 || monday(2);                         // 元日・成人の日
      case 2: return day === 11 || day === 23;                       // 建国記念の日・天皇誕生日
      case 3: return day === equinox(y, 20.8431);                    // 春分の日
      case 4: return day === 29;                                     // 昭和の日
      case 5: return day === 3 || day === 4 || day === 5;            // 憲法記念日・みどりの日・こどもの日
      case 7: return monday(3);                                      // 海の日
      case 8: return day === 11;                                     // 山の日
      case 9: return monday(3) || day === equinox(y, 23.2488);       // 敬老の日・秋分の日
      case 10: return monday(2);                                     // スポーツの日
      case 11: return day === 3 || day === 23;                       // 文化の日・勤労感謝の日
      default: return false;
    }
  }

  function equinox(y, base) {   // 春分・秋分の日（1980〜2099年に使える式）
    return Math.floor(base + 0.242194 * (y - 1980) - Math.floor((y - 1980) / 4));
  }

  function substituteHoliday(d) {   // 振替休日: 日曜の祝日のあと、最初の祝日でない日
    if (baseHoliday(d)) return false;
    let p = addDays(d, -1);
    while (baseHoliday(p)) {
      if (p.getUTCDay() === 0) return true;
      p = addDays(p, -1);
    }
    return false;
  }

  function citizensHoliday(d) {     // 国民の休日: 祝日にはさまれた日
    return !baseHoliday(d) && d.getUTCDay() !== 0 && baseHoliday(addDays(d, -1)) && baseHoliday(addDays(d, 1));
  }

  // ---------------- 小さな道具 ----------------

  function addDays(d, n) { return new Date(d.getTime() + n * 86400000); }
  function ymd(s) {
    const m = s.normalize('NFKC').match(/^(\d{4})\/(\d{2})\/(\d{2})$/);
    return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  }
  function fmt(d) { return d.getUTCFullYear() + '/' + pad2(d.getUTCMonth() + 1) + '/' + pad2(d.getUTCDate()); }
  function pad2(n) { return String(n).padStart(2, '0'); }
  function toInt(s) {
    const t = String(s).normalize('NFKC').trim();
    return /^[+-]?\d+$/.test(t) ? parseInt(t, 10) : null;
  }
  function leadInt(s, def) {
    const m = (s || '').match(/^\s*(\p{Nd}+)/u);
    return m ? m[1] : def;
  }
  function cell(row, idx) { return idx >= 0 && idx < row.length ? row[idx] : ''; }
  function isBlank(row) { return row.every(function (c) { return (c || '').trim() === ''; }); }

  return { convert: convert, parseCsv: parseCsv, isJapaneseHoliday: isJapaneseHoliday };
})();
