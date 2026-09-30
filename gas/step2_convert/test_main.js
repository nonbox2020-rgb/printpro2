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
}
const folders = [], files = [];
const iter = (list) => { let i = 0; return { hasNext: () => i < list.length, next: () => list[i++] }; };
class File {
  constructor(blob, parent) { this.id = "f" + ++seq; this.blob = blob; this.parent = parent; this.trashed = false; }
  getId() { return this.id; }
  getName() { return this.blob.name; }
  getBlob() { return this.blob.copyBlob(); }
  moveTo(folder) { this.parent = folder; return this; }
  setTrashed(v) { this.trashed = v; return this; }
}
class Folder {
  constructor(name, parent) { this.id = "d" + ++seq; this.name = name; this.parent = parent; }
  getName() { return this.name; }
  getUrl() { return "https://drive.google.com/drive/folders/" + this.id; }
  getFoldersByName(n) { return iter(folders.filter((f) => f.parent === this && f.name === n)); }
  createFolder(n) { const f = new Folder(n, this); folders.push(f); return f; }
  createFile(blob) { const f = new File(blob.copyBlob(), this); files.push(f); return f; }
  getFilesByName(n) { return iter(files.filter((f) => f.parent === this && !f.trashed && f.getName() === n)); }
  getFiles() { return iter(files.filter((f) => f.parent === this && !f.trashed)); }
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
function mail(thread, date, attachments) {
  const m = { id: "m" + ++seq, date, attachments,
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
const labels = {};
const jst = (d) => new Date(d.getTime() + 9 * 3600 * 1000);
const p2 = (n) => String(n).padStart(2, "0");
const sandbox = {
  console,
  DriveApp: {
    getRootFolder: () => myDrive,
    getFileById: (id) => files.find((f) => f.id === id),
  },
  GmailApp: {
    getUserLabelByName: (n) => labels[n] || null,
    createLabel: (n) => (labels[n] = { name: n }),
    // has:attachment filename:csv の代わり: CSV の添付があるスレッド
    search: () => threads.filter((t) => t.messages.some((m) => m.attachments.some((a) => /csv/i.test(a.getName())))),
  },
  PropertiesService: {
    getScriptProperties: () => ({
      getProperty: (k) => (k in props ? props[k] : null),
      setProperty: (k, v) => { props[k] = v; },
      deleteProperty: (k) => { delete props[k]; },
    }),
  },
  SpreadsheetApp: { create: makeSpreadsheet, openById: (id) => sheets[id] },
  MailApp: { sendEmail: (to, subject, body) => sent.push({ to, subject, body }) },
  Session: { getEffectiveUser: () => ({ getEmail: () => "iwasaki@yushin-p.example" }) },
  Utilities: {
    newBlob: (s) => new Blob(Buffer.from(s || "", "utf8"), "", ""),
    formatDate: (d, tz, f) => {
      const t = jst(d);
      return f.replace("yyyy", t.getUTCFullYear()).replace("MM", p2(t.getUTCMonth() + 1)).replace("dd", p2(t.getUTCDate()))
        .replace("HH", p2(t.getUTCHours())).replace("mm", p2(t.getUTCMinutes()));
    },
  },
};
vm.createContext(sandbox);
vm.runInContext(["1_main.gs", "2_rules.gs", "3_converter.gs"]
  .map((n) => fs.readFileSync(path.join(__dirname, n), "utf8")).join("\n") + "\nthis.RULES = RULES;", sandbox);

// ---------------- 確かめる道具 ----------------
let failed = 0;
const check = (ok, name) => { console.log((ok ? "  OK  " : "  NG  ") + name); if (!ok) failed++; };
const folderAt = (...names) => names.reduce((f, n) => f && folders.find((x) => x.parent === f && x.name === n), myDrive);
const namesIn = (...names) => {
  const f = folderAt(...names);
  return f ? files.filter((x) => x.parent === f && !x.trashed).map((x) => x.getName()).sort() : [];
};
const expectedNames = (s) => fs.readdirSync(path.join(EXPECTED, s)).filter((n) => n !== "warnings.txt").sort();
const logRows = () => { const f = files.find((x) => x.getName() === "変換の記録"); return sheets[f.id].getSheets()[0].rows; };
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
check(JSON.stringify(namesIn(P, "2_勘太郎用", "2026-10-01")) === JSON.stringify(expectedNames("sample_A_2026-10-01")),
  "2_勘太郎用/2026-10-01 に sample A の5案件");
check(JSON.stringify(namesIn(P, "2_勘太郎用", "2026-12-30")) === JSON.stringify(expectedNames("sample_B_2026-12-30")),
  "2_勘太郎用/2026-12-30 に sample B の2案件（下版予定日ごとのフォルダ）");
const sameBytes = expectedNames("sample_A_2026-10-01").every((n) => {
  const f = files.find((x) => x.parent === folderAt(P, "2_勘太郎用", "2026-10-01") && x.getName() === n);
  return f.blob.bytes.equals(fs.readFileSync(path.join(EXPECTED, "sample_A_2026-10-01", n)));
});
check(sameBytes, "保存した勘太郎CSVは、アプリの正解と1バイトも違わない（BOM付きUTF-8）");
check(namesIn(P, "3_要確認", "2026-10-01").length === 5, "sample C（A と同じ中身）は二重なので 3_要確認 へ（勘太郎用には出さない）");
check(files.filter((f) => f.parent === myDrive && !f.trashed).length === 0, "マイドライブの直下にはファイルを置かない（すべて「三映CSV連携」の中）");
check(files.find((f) => f.getName() === "変換の記録").parent === folderAt(P), "「変換の記録」スプレッドシートも「三映CSV連携」の中");
check(logRows().length === 1 + 14, "変換の記録: 見出し＋14行（案件12・お知らせ2）");
check(mails.length === 1 && mails[0].subject === "【三映CSV】勘太郎用 7件・要確認 5件", "メールの件名: " + (mails[0] || {}).subject);
check(t1.labels.includes("sanei-saved"), "メールのスレッドに目印のラベル");

console.log("== 2回目: 新しいメールなし");
check(run().length === 0, "何も無ければ、メールも送らない");

console.log("== 3回目: 同じスレッドに2通目（sample D・変換表に無い寸法）");
mail(t1, new Date("2026-09-30T01:00:00Z"), [sample("sample_D_unknown_size.csv")]);
mails = run();
check(JSON.stringify(namesIn(P, "3_要確認", "2026-10-02")) === JSON.stringify(expectedNames("sample_D_unknown_size")),
  "警告のある案件は 3_要確認/2026-10-02 へ");
check(namesIn(P, "2_勘太郎用", "2026-10-02").length === 0, "警告のある案件は勘太郎用に出さない");
check(mails.length === 1 && /要確認 1件/.test(mails[0].subject) && /寸法推定/.test(mails[0].body), "メールで要確認と警告の中身を知らせる");

console.log("== 4回目: ルールを直して（変換表に 4/6四裁 を足す）、もう一度変換");
vm.runInContext("RULES.size_table['4/6四裁'] = { paper: '46判', print: '46四' };", sandbox);
const d = files.find((f) => f.getName() === "1000_sample_D_unknown_size.csv");
d.moveTo(folderAt(P, "4_もう一度変換"));
mails = run();
check(namesIn(P, "2_勘太郎用", "2026-10-02").length === 1, "直したあとは 2_勘太郎用/2026-10-02 へ");
check(namesIn(P, "3_要確認", "2026-10-02").length === 0, "古い要確認のファイルは消える（ゴミ箱へ）");
check(d.parent.parent === folderAt(P, "1_受信") && namesIn(P, "4_もう一度変換").length === 0, "変換し直した三映CSVは 1_受信 へ戻る");
check(mails.length === 1 && mails[0].subject === "【三映CSV】勘太郎用 1件", "メールの件名: " + (mails[0] || {}).subject);

console.log("== 5回目: 勘太郎用に出したもの（sample A）を、もう一度変換に入れる");
const a = files.find((f) => f.getName() === "0900_sample_A_2026-10-01.csv");
a.moveTo(folderAt(P, "4_もう一度変換"));
const before = files.length;
mails = run();
check(files.length === before, "勘太郎用にある案件は出し直さない（二重登録を防ぐ）");
check(mails.length === 1 && /とばした 5件/.test(mails[0].body), "メールで「とばした 5件」と知らせる");

console.log("== 6回目: 三映CSVでない CSV が届いた");
const t2 = newThread();
mail(t2, new Date("2026-09-30T02:00:00Z"), [new Blob(Buffer.from("日付,金額\r\n2026/10/01,1000\r\n", "utf8"), "report.csv", "text/csv")]);
mails = run();
check(mails.length === 1 && /エラー 1件/.test(mails[0].subject), "変換できないCSVはエラーとして知らせる: " + (mails[0] || {}).subject);
check(namesIn(P, "1_受信", "2026-09-30").includes("1100_report.csv"), "元のファイルは 1_受信 に残る");
check(logRows().some((r) => r[5] === "エラー（変換できない）"), "変換の記録にエラーの行");

console.log("== 練習のやり直し（resetPractice）");
vm.runInContext("resetPractice()", sandbox);
check(!("done" in props), "保存済みメールの記録が消える");

if (failed) {
  console.log(`❌ ${failed} 件が期待と違います`);
  process.exit(1);
}
console.log("✅ GAS 版（Gmail → ドライブ → 勘太郎CSV）は期待どおりに動きます");
