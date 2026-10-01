// ===== 変換のルール（三映CSV → 勘太郎CSV）=====
// ルールを変えるときは、このファイルだけを直す。中身はアプリの sanei_config.yaml と同じ。
// 例: 変換表に無い寸法を足す → size_table に1行足す（Gemini に頼んでよい）
//
// 確定状況: [確定] 実ファイル・岩崎様のご回答（2026-09-30）で確認済み / [仕様書] 岩崎様の資料どおり

const RULES = {
  // --- 三映CSV（入力）の読み方 [確定] ---
  input: {
    // 列は見出し行の名前で探す（列が増えても、並びが変わっても読める）。
    // 全角/半角・№/No・空白の違いは自動で吸収する。
    header_names: {
      order_seq: ['順'],
      order_no: ['受注№', '受注番号'],
      title: ['作品名'],
      kind: ['種類'],
      side: ['裏表', '表裏'],
      dimension: ['寸法'],
      paper: ['用紙'],
      weight: ['斤量'],
      through: ['通し'],
      color: ['色', '色数'],
      copies: ['部数'],
      note: ['備考'],
      process: ['加工'],
    },
    // これが1つでも無い見出し行は、取り違えを防ぐためエラーにする
    required_headers: ['order_no', 'title', 'kind', 'side', 'dimension', 'paper', 'weight', 'through', 'color', 'copies', 'note'],
    // 内部で扱う標準の並び（見出しで探した列をこの位置にそろえる）
    columns: {
      order_seq: 0, order_no: 1, title: 2, kind: 3, plate_down: 4, side: 5, dimension: 6,
      paper: 7, weight: 8, through: 9, color: 10, copies: 11, note: 12, process: 13,
    },
    title_date_col: 8,          // タイトル行のI列に「2026-08-27 予定」（下版予定日）
    proof_marker: '本機校正',    // 受注№が無くこの文字を含む行 = 校正のまとまりの始まり
  },

  // --- 「裏」の行は読まない [確定] ---
  skip_side_value: '裏',

  // --- 「表裏」の行（両面） [確定: 2026-10-01] ---
  // 裏表がこの値の行は両面に刷る。'' にすると、この扱いをしない
  //  ・色が数字だけ（例 4）なら、表も裏も同じ色数（4/4）→ 裏が0でないので納品日は2営業日後。スラッシュがあれば書いてあるとおり
  //  ・同じ受注№で、勘太郎CSVにしたときの中身（N〜AB列）が同じ「表裏」の行は1行にまとめる（知らせを出す）
  both_sides_value: '表裏',

  // --- 勘太郎CSV（出力）の形 [勘太郎で取込確認済] ---
  output: {
    bom: true,                  // UTF-8（BOM付き）。Excel で開いても文字化けしない
    quoting: 'minimal',         // カンマ・改行・" を含むセルだけ " で囲む
    newline: '\r\n',            // 行の区切り（CRLF）
    cell_newline: 'crlf',       // セルの中の改行も CRLF にそろえる
    header: true,               // 1行目に見出し
    filename_pattern: '{date}_{no}_{seg}.csv',   // 例 20261001_9000101-00-00_本番.csv
  },

  // --- 決まった値 [確定]（見本の「あさ」「引き取り」ではなく「朝」「先方引取」）---
  fixed: {
    sales_code: 'S0005',        // A 営業コード
    customer_code: '00332',     // B 得意先コード（先頭ゼロ付き5桁）
    edition: '新版',            // D 版別
    pages: '2',                 // F ページ数
    delivery_time: '朝',        // J 納品時間
    paper_arrange: '先方',      // K 用紙手配先
    plate_form: 'データ支給',   // L 下版形態
    platemaking: '社内',        // M 製版先
    units: '1',                 // V 台数
    print_place: '社内',        // Z 印刷場所
    delivery_method: '先方引取', // AC 納品方法
    invoice: '無',              // AE 指定納品書
  },

  // --- 品名の組み立て [確定] ---
  product_name: {
    parts: ['order_no', 'title', 'kind'],   // 受注№ 作品名 種類
    separator: ' ',
    proof_suffix: '本機校正',                // 校正のまとまりでは最後に付ける
  },

  // --- 用紙サイズ（O）・印刷サイズ（W）の変換表 [仕様書] ---
  // 表に無い寸法は、下の size_unknown に従う（いまは空白にして、警告で知らせる）
  size_table: {
    '菊全判': { paper: '菊判', print: '菊全' },
    '菊半裁': { paper: '菊判', print: '菊半' },
    '4/6全': { paper: '46判', print: '46全' },
    '4/6半裁': { paper: '46判', print: '46半' },
    'L全判': { paper: 'L判', print: 'L全' },
    'L半裁': { paper: 'L判', print: 'L半' },
    'K全判': { paper: 'K判', print: 'K全' },
    'K半裁': { paper: 'K判', print: 'K半' },
    'A全判': { paper: 'A判', print: 'A全' },
    'A半裁': { paper: 'A判', print: 'A半' },
    'B全判': { paper: 'B判', print: 'B全' },
    'B半裁': { paper: 'B判', print: 'B半' },
  },
  size_prefix_map: { '4/6': '46' },   // 推定のときの言いかえ（size_unknown が 'estimate' のときだけ使う）
  // 表に無い寸法 [確定: 岩崎様「表に無い寸法は空白でOK」]
  //   'blank' = 用紙サイズ・印刷サイズを空白にして警告で知らせる（勘太郎に入ったあとで入力）/ 'estimate' = 推定して警告
  size_unknown: 'blank',

  // --- 仕上サイズ（E）[確定] ---
  trim_size: {
    dvd_jacket_source: 'DVDジャケット',   // 種類にこれを含めば
    dvd_jacket_value: 'DVDジャケ',        // この値にする
    patterns: [                           // 上から順に、最初に一致したもの
      { re: '^(B[0-9])', out: '$1' },     // B1ポスター → B1
      { re: '^(A[0-9])', out: '$1' },     // A4チラシ → A4
    ],
  },

  // --- 印刷項目（R）: 備考から取り出す（表紙と○折が両方あるときは表紙）[確定] ---
  print_item: {
    patterns: ['表紙', '[0-9０-９,，\\.]+折'],   // 表紙 / 1折・2,3折 など
  },

  // --- 色数（S表・T裏）[確定] 例 4/4c → 4と4、4 → 4と0 ---
  color: {
    strip_chars: 'cCｃＣ',
    default_back: '0',
  },

  // --- 納品日（I）: 休みの日を除いて数える [確定] ---
  // 日曜・国民の祝日・会社の休業日は休み。土曜は第1・3土曜日が休みで、第2・4・5土曜日は営業日。あとはカレンダー通り
  delivery: {
    side_color_zero_offset: 1,      // 裏の色数が0 → 下版予定日の1営業日後
    side_color_nonzero_offset: 2,   // それ以外 → 2営業日後
    // 会社の休業日（お盆・年末年始など）。例: ['2026/12/29', '2026/12/30']。祝日は自動で数える
    working_saturdays: [2, 4, 5],   // 営業日にする「第N土曜日」
    company_closed: [],
  },

  // --- 備考の文面 [仕様書] ---
  templates: {
    delivery_note: {   // AF 納品先・備考
      main: '橋本さんへ\n刷りだし5枚+支給品  刷版ケースは　三映　三浦さんが取ります\n新富運輸　　先方手配　刷り本引き取りです',
      proof: '三映　三浦さんが引き取りです',
      proof_jacket: '三映　三浦さんが引き取りです',   // 校正×DVDジャケット（ご回答に無いため、校正と同じ）
    },
    plate_note: {      // AG 刷版備考
      main: '三映様分　先方のアクセサリー等は取らない（先方の受注番号や先方の　作業詳細有り）\n●面付け',
      jacket: '金主任　　三映様分の　ジャケット案件\nセンター白を統一で開けて焼いてください\n\n三映様分　先方のアクセサリー等は取らない（先方の受注番号や先方の　作業詳細有り）\n●面付け',
      proof: '三映様分　先方のアクセサリー等は取らない（先方の受注番号や先方の　作業詳細有り）',
      proof_jacket: '三映様分 先方のアクセサリー等は取らない（先方の受注番号や先方の作業詳細有り）\n校正は46版 本番A半\n加工 断裁 のみ',
    },
    print_note: {      // AH 印刷備考
      main: '本番です　本機校正　に色合わせです\n●●●シートで　付箋（駒取りして下さい）　　加工予備　●●●シート以上付けて下さい　刷りだし1枚だけ文京事務所に下さい　　刷りだし5枚+支給品は刷版ケースに入れて橋本さん渡して下さい　別指示書の　三映様分同梱して下さい',
      jacket: 'プリモ見本合わせです　　100シートで付箋（駒取りして下さい）　　加工予備／150シート以上付けて下さい　　★三映様分のジャケットは引き取り日が同じ案件は、枚数が少ない場合はアイ紙挟んで別案件のジャケット刷り本積んで下さい　　刷りだし1枚だけ文京事務所に下さい　　刷りだし5枚+支給品は刷版ケースに入れて橋本さん渡して下さい　　別指示書の三映様分同梱して下さい',
      proof: '本機校正　1回目　\n先方支給　　色見本に　なるべく色よせて下さい\n校正　1枚だけ文京事務所に下さい\n校正20枚+支給品は　刷版ケースに入れて橋本さんに渡して下さい三映様分校正は　まとめて刷版ケース入れて下さい',
      proof_jacket: '先方支給 色校正合わせです\n校正 1枚だけ文京事務所に下さい\n校正20枚+支給品は 刷版ケースに入れて橋本さんに渡して下さい三映様分校正は まとめて刷版ケース入れて下さい',
    },
  },

  // --- 勘太郎CSV 35列の並びと見出し [確定] ---
  // per_row: true の列は、2行目以降（同じ案件の続きの行）にも値を入れる
  csv_b_columns: [
    { key: 'sales_code', label: '営業コード' },
    { key: 'customer_code', label: '得意先コード' },
    { key: 'product_name', label: '品名' },
    { key: 'edition', label: '版別' },
    { key: 'trim_size', label: '仕上サイズ' },
    { key: 'pages', label: 'ページ数' },
    { key: 'quantity', label: '数量' },
    { key: 'plate_date', label: '下版予定日' },
    { key: 'delivery_date', label: '納品日' },
    { key: 'delivery_time', label: '納品時間' },
    { key: 'paper_arrange', label: '用紙手配先' },
    { key: 'plate_form', label: '下版形態' },
    { key: 'platemaking', label: '製版先' },
    { key: 'paper_brand', label: '用紙銘柄', per_row: true },
    { key: 'paper_size', label: '用紙サイズ', per_row: true },
    { key: 'grain', label: '紙目', per_row: true },
    { key: 'weight', label: '斤量', per_row: true },
    { key: 'print_item', label: '印刷項目', per_row: true },
    { key: 'color_front', label: '色数（表）', per_row: true },
    { key: 'color_back', label: '色数（裏）', per_row: true },
    { key: 'imposition', label: '面付' },
    { key: 'units', label: '台数', per_row: true },
    { key: 'print_size', label: '印刷サイズ', per_row: true },
    { key: 'print_sheets', label: '印刷枚数', per_row: true },
    { key: 'spare', label: '予備', per_row: true },
    { key: 'print_place', label: '印刷場所', per_row: true },
    { key: 'print_start', label: '印刷開始日', per_row: true },
    { key: 'print_end', label: '印刷終了日', per_row: true },
    { key: 'delivery_method', label: '納品方法' },
    { key: 'shipper', label: '荷主名' },
    { key: 'invoice', label: '指定納品書' },
    { key: 'delivery_note', label: '納品先・備考' },
    { key: 'plate_note', label: '刷版備考' },
    { key: 'print_note', label: '印刷備考' },
    { key: 'bind_note', label: '製本備考' },
  ],
};
