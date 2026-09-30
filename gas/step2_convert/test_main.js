// GAS 版の全体（1_main.gs）を、Gmail・Googleドライブ・スプレッドシート・メールの偽物の上で動かして確かめる。
//   node gas/step2_convert/test_main.js
// 本物の Gmail やドライブには触らない。架空サンプル（tests/samples）を添付したメールで試す。
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const ROOT = path.resolve(__dirname, "..", "..");
const SAMPLES = path.join(ROOT, "tests", "samples");
const EXPECTED = path.join(ROOT, "tests", "expected");

// ---------------- 偽物（GAS の Blob・ドライブ・Gmail など）----------------
let seq = 0;
class Blob {
  constructor(bytes, name, type) { this.bytes = Buffer.from(bytes); this.name = name; this.type = type || ""; }
  getName() { return this.name; }
  setName(n) { this.name = n; return this; }
  setContentType(t) { this.type = t; return this; }
  setDataFromString(s, charset) {
    if (charset !== "UTF-8") throw new Error("charset " + charset);
    this.bytes = Buffer.from(s, "utf8");
    return this;
  }
  getDataAsString(charset) {
    const enc = { "UTF-8": "utf-8", MS932: "shift_jis", Shift_JIS: "shift_jis" }[charset];
    return new TextDecoder(enc).decode(this.bytes);   // UTF-8 で読めない所は � になる（GAS と同じ）
  }
  copyBlob() { return new Blob(this.bytes, this.name, this.type); }
  getBytes() { return this.bytes; }
}
const folders = [], files = [];
const iter = (list) => { let i = 0; return { hasNext: () => i < list.length, next: () => list[i++] }; };
class File {
  constructor(blob, parent) { this.id = "f" + ++seq; this.blob = blob; this.parent = parent; this.trashed = false; this.created = new Date(); }
  getId() { return this.id; }
  getDateCreated() { return this.created; }
  getSize() { return this.blob.bytes.length; }
  getParents() { return iter([this.parent]); }
  getName() { return this.blob.name; }
  getBlob() { return this.blob.copyBlob(); }
  moveTo(folder) { this.parent = folder; return this; }
  setTrashed(v) { this.trashed = v; return this; }
  isTrashed() { return this.trashed; }
}
// 本物のドライブと同じく、ゴミ箱に入れたものも名前で見つかる（使う側で isTrashed を確かめる）
class Folder {
  constructor(name, parent) { this.id = "d" + ++seq; this.name = name; this.parent = parent; this.trashed = false; this.created = new Date(); }
  getName() { return this.name; }
  getDateCreated() { return this.created; }
  getId() { return this.id; }
  getFolders() { return iter(folders.filter((f) => f.parent === this)); }
  setTrashed(v) { this.trashed = v; return this; }
  isTrashed() { return this.trashed; }
  getUrl() { return "https://drive.google.com/drive/folders/" + this.id; }
  getFoldersByName(n) { return iter(folders.filter((f) => f.parent === this && f.name === n)); }
  createFolder(n) { const f = new Folder(n, this); folders.push(f); return f; }
  createFile(blob) { const f = new File(blob.copyBlob(), this); files.push(f); return f; }
  getFilesByName(n) { return iter(files.filter((f) => f.parent === this && f.getName() === n)); }
  getFiles() { return iter(files.filter((f) => f.parent === this)); }
}
const myDrive = new Folder("マイドライブ", null);
folders.push(myDrive);

const sheets = {};
function makeSpreadsheet(name) {
  const file = new File(new Blob([], name, "application/vnd.google-apps.spreadsheet"), myDrive);
  files.push(file);
  const sheet = { rows: [], appendRow(r) { this.rows.push(r); return this; }, setFrozenRows() { return this; } };
  sheets[file.id] = { getId: () => file.id, getSheets: () => [sheet] };
  return sheets[file.id];
}

const threads = [];
// from = 送り主、deliveredTo = 届いたアドレス（Gmail の deliveredto: で絞れる）
function mail(thread, date, attachments, from = "sanei@sanei.example", deliveredTo = "iwasaki@yushin-p.example") {
  const m = { id: "m" + ++seq, date, attachments, from, deliveredTo, getFrom() { return this.from; },
    getId() { return this.id; }, getDate() { return this.date; }, getAttachments() { return this.attachments; } };
  thread.messages.push(m);
}
const newThread = () => {
  const t = { messages: [], labels: [], getMessages() { return this.messages; }, addLabel(l) { this.labels.push(l.name); return this; } };
  threads.push(t);
  return t;
};
const sample = (n) => new Blob(fs.readFileSync(path.join(SAMPLES, n)), n, "text/csv");

const sent = [];
const props = {};
const triggers = [];
const logs = [];
let lastQuery = "";
const labels = {};
const jst = (d) => new Date(d.getTime() + 9 * 3600 * 1000);
const p2 = (n) => String(n).padStart(2, "0");
const sandbox = {
  console: { log: (...a) => logs.push(a.join(" ")) },
  DriveApp: {
    getRootFolder: () => myDrive,
    getFileById: (id) => {   // 本物と同じく、無い id ならエラー
      const f = files.find((x) => x.id === id);
      if (!f) throw new Error("ファイルが見つかりません: " + id);
      return f;
    },
  },
  GmailApp: {
    getUserLabelByName: (n) => labels[n] || null,
    createLabel: (n) => (labels[n] = { name: n }),
    // has:attachment filename:csv の代わり: CSV の添付があるスレッド。from:(…) と deliveredto:… でも絞る
    search: (q) => {
      lastQuery = q;
      const fromM = /from:\(([^)]*)\)/.exec(q);
      const froms = fromM ? fromM[1].split(" OR ").map((x) => x.trim().toLowerCase()) : null;
      const toM = /deliveredto:(\S+)/.exec(q);
      const to = toM ? toM[1].toLowerCase() : null;
      return threads.filter((t) => t.messages.some((m) => m.attachments.some((a) => /csv/i.test(a.getName())) &&
        (!froms || froms.some((f) => m.from.toLowerCase().includes(f))) && (!to || m.deliveredTo.toLowerCase() === to)));
    },
  },
  PropertiesService: {
    getScriptProperties: () => ({
      getProperties: () => Object.assign({}, props),
      getProperty: (k) => (k in props ? props[k] : null),
      setProperty: (k, v) => { props[k] = v; },
      deleteProperty: (k) => { delete props[k]; },
    }),
  },
  SpreadsheetApp: { create: makeSpreadsheet, openById: (id) => sheets[id] },
  ScriptApp: {
    getProjectTriggers: () => triggers,
    newTrigger: (fn) => ({ timeBased: () => ({ everyMinutes: (n) => ({ create: () => {
      const t = { minutes: n, getHandlerFunction: () => fn };
      triggers.push(t);
      return t;
    } }) }) }),
  },
  MailApp: { sendEmail: (to, subject, body) => sent.push({ to, subject, body }) },
  Session: { getEffectiveUser: () => ({ getEmail: () => "iwasaki@yushin-p.example" }) },
  ContentService: {
    MimeType: { JSON: "application/json" },
    createTextOutput: (text) => ({ text, mime: "", setMimeType(m) { this.mime = m; return this; } }),
  },
  Utilities: {
    getUuid: () => require("crypto").randomUUID(),
    base64Encode: (bytes) => Buffer.from(bytes).toString("base64"),
    newBlob: (s) => new Blob(Buffer.from(s || "", "utf8"), "", ""),
    formatDate: (d, tz, f) => {
      const t = jst(d);
      return f.replace("yyyy", t.getUTCFullYear()).replace("MM", p2(t.getUTCMonth() + 1)).replace("dd", p2(t.getUTCDate()))
        .replace("HH", p2(t.getUTCHours())).replace("mm", p2(t.getUTCMinutes()));
    },
  },
};
vm.createContext(sandbox);
vm.runInContext(["1_main.gs", "2_rules.gs", "3_converter.gs", "4_webapp.gs"]
  .map((n) => fs.readFileSync(path.join(__dirname, n), "utf8")).join("\n") + "\nthis.RULES = RULES;", sandbox);

// ---------------- 確かめる道具 ----------------
let failed = 0;
const check = (ok, name) => { console.log((ok ? "  OK  " : "  NG  ") + name); if (!ok) failed++; };
const folderAt = (...names) => names.reduce((f, n) => f && folders.find((x) => x.parent === f && x.name === n && !x.trashed), myDrive);
const namesIn = (...names) => {
  const f = folderAt(...names);
  return f ? files.filter((x) => x.parent === f && !x.trashed).map((x) => x.getName()).sort() : [];
};
const expectedNames = (s) => fs.readdirSync(path.join(EXPECTED, s)).filter((n) => n !== "warnings.txt").sort();
const logRows = () => { const f = files.find((x) => x.getName() === "変換の記録" && x.parent === folderAt(P)); return sheets[f.id].getSheets()[0].rows; };
const run = () => { const before = sent.length; vm.runInContext("saveSaneiCsv()", sandbox); return sent.slice(before); };
const P = "三映CSV連携";

// ---------------- 1回目: 練習メール（A・B・C と PDF）----------------
console.log("== 1回目: 練習メール（sample A・B・C と PDF）");
const t1 = newThread();
mail(t1, new Date("2026-09-30T00:00:00Z"), ["sample_A_2026-10-01.csv", "sample_B_2026-12-30.csv", "sample_C_extra_column.csv"]
  .map(sample).concat([new Blob(Buffer.from("%PDF"), "memo.pdf", "application/pdf")]));
let mails = run();
check(JSON.stringify(namesIn(P, "1_受信", "2026-09-30")) === JSON.stringify(
  ["0900_sample_A_2026-10-01.csv", "0900_sample_B_2026-12-30.csv", "0900_sample_C_extra_column.csv"]),
"1_受信/2026-09-30 に三映CSVが3つ（受け取った時刻つき・PDFは入れない）");
const out = () => namesIn(P, "2_勘太郎用");
const a = expectedNames("sample_A_2026-10-01"), b = expectedNames("sample_B_2026-12-30");
const c2 = expectedNames("sample_C_extra_column").map((n) => n.replace(/\.csv$/, "_2.csv"));
check(JSON.stringify(out()) === JSON.stringify(a.concat(b, c2).sort()),
  "2_勘太郎用（日付で分けない）に A の5・B の2・C の5（A と同じ名前なので _2 付き）");
const sameBytes = a.every((n) => {
  const f = files.find((x) => x.parent === folderAt(P, "2_勘太郎用") && x.getName() === n);
  return f.blob.bytes.equals(fs.readFileSync(path.join(EXPECTED, "sample_A_2026-10-01", n)));
});
check(sameBytes, "保存した勘太郎CSVは、アプリの正解と1バイトも違わない（BOM付きUTF-8）");
check(!folderAt(P, "3_要確認"), "要確認のフォルダは作らない（同じ受注№も基幹システムへ）");
check(files.filter((f) => f.parent === myDrive && !f.trashed).length === 0, "マイドライブの直下にはファイルを置かない（すべて「三映CSV連携」の中）");
check(files.find((f) => f.getName() === "変換の記録").parent === folderAt(P), "「変換の記録」スプレッドシートも「三映CSV連携」の中");
check(logRows().length === 1 + 14, "変換の記録: 見出し＋14行（案件12・お知らせ2）");
check(logRows().some((r) => r[5] === "20261001_9000101-00-00_本番_2.csv"), "変換の記録に、保存したファイルの名前（_2 付き）");
check(mails.length === 1 && mails[0].subject === "【三映CSV】勘太郎用 12件", "メールの件名: " + (mails[0] || {}).subject);
check(t1.labels.includes("sanei-saved"), "メールのスレッドに目印のラベル");

console.log("== 2回目: 新しいメールなし");
check(run().length === 0, "何も無ければ、メールも送らない");

console.log("== 3回目: 同じスレッドに2通目（sample D・変換表に無い寸法）");
mail(t1, new Date("2026-09-30T01:00:00Z"), [sample("sample_D_unknown_size.csv")]);
mails = run();
const dName = expectedNames("sample_D_unknown_size")[0];
const dFile = () => files.filter((x) => x.parent === folderAt(P, "2_勘太郎用") && x.getName().startsWith(dName.slice(0, -4)));
check(dFile().length === 1 && dFile()[0].blob.bytes.equals(fs.readFileSync(path.join(EXPECTED, "sample_D_unknown_size", dName))),
  "警告のある案件も 2_勘太郎用 へ（推定の値のまま。正解と同じ）");
check(mails.length === 1 && mails[0].subject === "【三映CSV】勘太郎用 1件・確認 1件" && /寸法推定/.test(mails[0].body) &&
  /勘太郎に入ったあとで確認/.test(mails[0].body), "メールで「確認 1件」と警告の中身を知らせる: " + (mails[0] || {}).subject);

console.log("== 4回目: ルールを直して（変換表に 4/6四裁 を足す）、sample D をもう一度送る");
vm.runInContext("RULES.size_table['4/6四裁'] = { paper: '46判', print: '46四' };", sandbox);
mail(t1, new Date("2026-09-30T01:30:00Z"), [sample("sample_D_unknown_size.csv")]);
mails = run();
const fixed = files.find((x) => x.parent === folderAt(P, "2_勘太郎用") && x.getName() === dName.replace(/\.csv$/, "_2.csv"));
const text = fixed ? fixed.blob.bytes.toString("utf8") : "";
check(fixed && text.includes(",46判,") && text.includes(",46四,") && !text.includes("46四判"), "直したルールで変換（用紙サイズ 46判・印刷サイズ 46四。名前は _2）");
check(mails.length === 1 && mails[0].subject === "【三映CSV】勘太郎用 1件", "警告が消え、件名から「確認」が消える: " + (mails[0] || {}).subject);

console.log("== 5回目: 三映CSVでない CSV が届いた");
const t2 = newThread();
mail(t2, new Date("2026-09-30T02:00:00Z"), [new Blob(Buffer.from("日付,金額\r\n2026/10/01,1000\r\n", "utf8"), "report.csv", "text/csv")]);
mails = run();
check(mails.length === 1 && /エラー 1件/.test(mails[0].subject), "変換できないCSVはエラーとして知らせる: " + (mails[0] || {}).subject);
check(namesIn(P, "1_受信", "2026-09-30").includes("1100_report.csv"), "元のファイルは 1_受信 に残る");
check(logRows().some((r) => r[5] === "エラー（変換できない）"), "変換の記録にエラーの行");

console.log("== 練習のやり直し（「三映CSV連携」をゴミ箱に入れて resetPractice → saveSaneiCsv）");
const oldRoot = folderAt(P);
oldRoot.setTrashed(true);
vm.runInContext("resetPractice()", sandbox);
check(!("done" in props), "保存済みメールの記録が消える");
mails = run();
check(folderAt(P) && folderAt(P) !== oldRoot, "ゴミ箱のフォルダは使わず、新しい「三映CSV連携」を作る");
check(out().length === 12 + 2, "新しいフォルダで最初から変換し直す（A・B・C の12件と D の2通分）");

console.log("== 設定: setup（スクリプト プロパティとトリガーを作る）");
vm.runInContext("setup()", sandbox);
check(props.SANEI_FROM === "未設定" && props.CHECK_ADDRESS === "未設定" && props.NOTIFY_TO === "未設定" && props.KEEP_DAYS === "3",
  "設定の欄を作る（値は「未設定」、KEEP_DAYS は 3）");
check(triggers.length === 1 && triggers[0].getHandlerFunction() === "saveSaneiCsv" && triggers[0].minutes === 5, "5分おきのトリガーを作る");
props.SANEI_FROM = "sanei@sanei.example";
vm.runInContext("setup()", sandbox);
check(triggers.length === 1 && props.SANEI_FROM === "sanei@sanei.example", "もう一度実行しても、トリガーは増えず、変えた設定も消さない");

console.log("== 設定: 三映様のアドレス（SANEI_FROM）で絞る");
const base = out().length;
mail(newThread(), new Date("2026-09-30T03:00:00Z"), [sample("sample_E_2026-10-09_long_weekend.csv")], "someone@other.example");
mails = run();
check(lastQuery.includes("from:(sanei@sanei.example)"), "Gmail の検索に from:(三映様のアドレス): " + lastQuery);
check(out().length === base && mails.length === 0, "三映様以外から届いたCSVは使わない");
const t4 = newThread();
mail(t4, new Date("2026-09-30T03:10:00Z"), [sample("sample_E_2026-10-09_long_weekend.csv")], "三映 担当 <SANEI@sanei.example>");
mails = run();
check(out().length === base + 4 && mails.length === 1, "三映様から届いたCSVは変換する（名前つき・大文字でも）");
check(/3日たつとゴミ箱へ/.test(mails[0].body), "知らせのメールに、3日たつとゴミ箱へ移ることを書く");
mail(t4, new Date("2026-09-30T03:20:00Z"), [sample("sample_G_2027-04-28_golden_week.csv")], "staff@yushin-p.example");
mails = run();
check(out().length === base + 4 && mails.length === 0, "同じスレッドでも、三映様以外のメールのCSVは使わない");

console.log("== 設定: 三映CSVが届くアドレス（CHECK_ADDRESS）で絞る");
props.CHECK_ADDRESS = "csv@yushin-p.example";
mail(newThread(), new Date("2026-09-30T04:00:00Z"), [sample("sample_K_2026-10-22_utf8.csv")], "sanei@sanei.example", "other@yushin-p.example");
mails = run();
check(lastQuery.includes("deliveredto:csv@yushin-p.example"), "Gmail の検索に deliveredto:（届くアドレス）");
check(mails.length === 0, "ほかのアドレスに届いたメールは使わない");
mail(newThread(), new Date("2026-09-30T04:10:00Z"), [sample("sample_K_2026-10-22_utf8.csv")], "sanei@sanei.example", "csv@yushin-p.example");
mails = run();
check(mails.length === 1 && out().length === base + 4 + 3, "届くアドレスに来たメールは変換する");

console.log("== 設定: 結果を知らせる先（NOTIFY_TO）");
check(mails[0].to === "iwasaki@yushin-p.example", "未設定なら、このアカウントへ知らせる");
props.NOTIFY_TO = "a@yushin-p.example、 b@yushin-p.example";
mail(newThread(), new Date("2026-09-30T04:20:00Z"), [sample("sample_G_2027-04-28_golden_week.csv")], "sanei@sanei.example", "csv@yushin-p.example");
mails = run();
check(mails.length === 1 && mails[0].to === "a@yushin-p.example,b@yushin-p.example", "設定した先（複数）へ知らせる: " + (mails[0] || {}).to);

console.log("== 設定を確かめる（checkSettings）");
const lines = vm.runInContext("checkSettings()", sandbox);
check(lines.some((l) => l.includes("このGASが見ている Gmail: iwasaki@yushin-p.example")), "見ている Gmail を出す");
check(lines.some((l) => l.includes("from:(sanei@sanei.example)") && l.includes("deliveredto:csv@yushin-p.example")), "Gmail の検索を出す");
check(lines.some((l) => l.includes("件のスレッド")), "対象になるメールの数を出す");
check(lines.some((l) => l.includes("CHECK_ADDRESS がこのアカウントと違います")), "届くアドレスがアカウントと違えば、転送を確かめるよう出す");

console.log("== 3日たったCSVを消す（KEEP_DAYS）");
const daysAgo = (n) => new Date(Date.now() - n * 24 * 3600 * 1000);
const inboxDay = folderAt(P, "1_受信", "2026-09-30");
const oldInbox = files.filter((f) => f.parent === inboxDay && !f.trashed);
oldInbox.forEach((f) => { f.created = daysAgo(4); });
inboxDay.created = daysAgo(4);
const outFiles = files.filter((f) => f.parent === folderAt(P, "2_勘太郎用") && !f.trashed);
outFiles.slice(0, 2).forEach((f) => { f.created = daysAgo(4); });
const doneDir = folderAt(P).createFolder("3_渡し済み");
const oldDone = doneDir.createFile(new Blob(Buffer.from("x"), "old.csv", "text/csv"));
oldDone.created = daysAgo(5);
const recent = doneDir.createFile(new Blob(Buffer.from("x"), "recent.csv", "text/csv"));
recent.created = daysAgo(1);
const logFile = files.find((f) => f.getName() === "変換の記録" && f.parent === folderAt(P));
logFile.created = daysAgo(10);
delete props.LAST_CLEANUP;
mails = run();
check(oldInbox.length > 0 && oldInbox.every((f) => f.trashed) && inboxDay.trashed, "1_受信: 4日前のCSVをゴミ箱へ（空になった日付のフォルダも）");
check(outFiles.slice(0, 2).every((f) => f.trashed) && outFiles.slice(2).every((f) => !f.trashed), "2_勘太郎用: 4日前の2件だけゴミ箱へ（新しいものは残す）");
check(oldDone.trashed && !recent.trashed, "3_渡し済み: 5日前はゴミ箱へ、1日前は残す");
check(!logFile.trashed, "「変換の記録」スプレッドシートは消さない");
check(mails.length === 1 && mails[0].subject === "【三映CSV】勘太郎へ渡していないCSVを削除しました 2件" &&
  mails[0].body.includes(outFiles[0].getName()), "勘太郎へ渡していないCSVを消したときは、名前つきでメールで知らせる: " + (mails[0] || {}).subject);
check(logRows().some((r) => r[5] === "削除" && /1_受信/.test(r[6]) && /2_勘太郎用 2件/.test(r[6])), "変換の記録に「削除」の行（フォルダごとの件数）");
recent.created = daysAgo(30);
mails = run();
check(!recent.trashed && mails.length === 0, "1時間以内には、もう一度は見ない");
props.KEEP_DAYS = "0";
delete props.LAST_CLEANUP;
run();
check(!recent.trashed, "KEEP_DAYS を 0 にすると消さない");
props.KEEP_DAYS = "三日";
delete props.LAST_CLEANUP;
run();
check(recent.trashed, "KEEP_DAYS が数字でなければ 3日として消す");

console.log("== 受け取り口（4_webapp.gs・勘太郎のパソコンが取りに来る）");
const get = (params) => {
  const o = vm.runInContext("doGet", sandbox)({ parameter: params });
  return Object.assign({ mime: o.mime }, JSON.parse(o.text));
};
check(get({ action: "list" }).ok === false && /合言葉/.test(get({ action: "list", token: "x" }).error), "合言葉が無い・違うときは渡さない");
const token = vm.runInContext("makeAgentToken()", sandbox);
check(/^[0-9a-f]{64}$/.test(token) && props.AGENT_TOKEN === token && logs.some((l) => l.includes(token)), "makeAgentToken で合言葉を作り、実行ログに出す");
check(vm.runInContext("makeAgentToken()", sandbox) === token, "もう一度実行しても、合言葉は変わらない");
const ping = get({ action: "ping", token });
check(ping.ok && ping.account === "iwasaki@yushin-p.example" && ping.mime === "application/json", "ping: つながる（JSON で答える）");
check(Number(props.AGENT_LAST_SEEN) > 0, "取りに来た時刻を控える");
const outNow = files.filter((f) => f.parent === folderAt(P, "2_勘太郎用") && !f.trashed);
outNow.forEach((f, i) => { f.created = new Date(Date.UTC(2026, 8, 30, 0, 0, outNow.length - i)); });   // 名前と逆の順に作ったことにする
const listed = get({ action: "list", token });
check(listed.ok && listed.files.length === outNow.length, "list: 「2_勘太郎用」の勘太郎CSVを全部出す（" + outNow.length + "件）");
check(listed.files[0].id === outNow[outNow.length - 1].id, "list: 古い順");
check(listed.files.every((x) => x.size === files.find((f) => f.id === x.id).blob.bytes.length), "list: 大きさ（バイト）も出す");
const first = files.find((f) => f.id === listed.files[0].id);
const got = get({ action: "file", id: first.id, token });
check(got.ok && got.name === first.getName() && Buffer.from(got.data, "base64").equals(first.blob.bytes) && got.size === first.blob.bytes.length,
  "file: 中身を1バイトも変えずに渡す（base64）");
const inboxFile = files.find((f) => f.parent && f.parent.parent === folderAt(P, "1_受信") && !f.trashed) ||
  files.find((f) => f.parent === folderAt(P) && f.getName() === "変換の記録");
check(get({ action: "file", id: inboxFile.id, token }).ok === false, "「2_勘太郎用」以外のファイルは渡さない");
check(get({ action: "file", id: "no-such-id", token }).ok === false, "無い id は ok:false");
check(get({ action: "done", id: first.id, token }).ok && first.parent === folderAt(P, "3_渡し済み"), "done: 「3_渡し済み」へ移す");
check(logRows().some((r) => r[5] === first.getName() && r[6] === "勘太郎のパソコンが受け取りました"), "done: 変換の記録に「受け取りました」");
check(get({ action: "done", id: first.id, token }).ok === true, "done がもう一度来ても ok（二度知らせても大丈夫）");
check(!get({ action: "list", token }).files.some((x) => x.id === first.id), "渡したものは、次の list に出ない");
const second = files.find((f) => f.id === listed.files[1].id);
check(get({ action: "skip", id: second.id, token }).ok && second.parent === folderAt(P, "4_渡さなかった分"), "skip: 「4_渡さなかった分」へよける");
check(get({ action: "whatever", token }).ok === false, "知らない action は ok:false");

console.log("== 受け取りの見張り（30分以上残っていたら知らせる）");
const stuck = files.find((f) => f.id === listed.files[2].id);
stuck.created = new Date(Date.now() - 31 * 60 * 1000);
files.filter((f) => f.parent === folderAt(P, "2_勘太郎用") && f !== stuck).forEach((f) => { f.created = new Date(); });
props.KEEP_DAYS = "3";
mails = run();
check(mails.length === 1 && mails[0].subject === "【三映CSV】勘太郎のパソコンが受け取っていません 1件" && mails[0].body.includes(stuck.getName()) &&
  mails[0].to === "a@yushin-p.example,b@yushin-p.example", "30分以上残っていたら、知らせる先へメール: " + (mails[0] || {}).subject);
check(run().length === 0, "知らせるのは1回だけ");
files.filter((f) => f.parent === folderAt(P, "2_勘太郎用")).forEach((f) => get({ action: "done", id: f.id, token }));
mails = run();
check(mails.length === 1 && mails[0].subject === "【三映CSV】勘太郎のパソコンの受け取りが元にもどりました", "受け取られたら「元にもどりました」");
check(run().length === 0, "元にもどったあとは何も送らない");

if (failed) {
  console.log(`❌ ${failed} 件が期待と違います`);
  process.exit(1);
}
console.log("✅ GAS 版（Gmail → ドライブ → 勘太郎CSV）は期待どおりに動きます");
