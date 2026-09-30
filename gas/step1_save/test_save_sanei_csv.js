// save_sanei_csv.gs を、Gmail・Googleドライブの偽物の上で動かして確かめる。
//   node gas/step1_save/test_save_sanei_csv.js
// GAS の画面に貼る前や、Gemini で直した後に実行する（本物の Gmail には触らない）。
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const code = fs.readFileSync(path.join(__dirname, "save_sanei_csv.gs"), "utf8");

const saved = [];
const labels = {};
const props = {};
let nextId = 1;

function makeThread() {
  return { messages: [], labels: [], getMessages() { return this.messages; }, addLabel(l) { this.labels.push(l.name); } };
}
function makeMessage(date, files) {
  return {
    id: "m" + nextId++, date, files,
    getId() { return this.id; },
    getDate() { return this.date; },
    getAttachments() {
      return this.files.map((name) => ({
        getName: () => name,
        copyBlob: () => ({ name, setName(n) { this.name = n; return this; } }),
      }));
    },
  };
}
const practice = makeThread();   // 練習メールのスレッド（同じ件名の2通目もここに入る）
const other = makeThread();      // CSV の無いメール

const sandbox = {
  console: { log: () => {} },
  JSON,
  GmailApp: {
    getUserLabelByName: (n) => labels[n] || null,
    createLabel: (n) => (labels[n] = { name: n }),
    // has:attachment filename:csv の代わり: CSV の添付があるスレッドだけ返す
    search: () => [practice, other].filter((t) => t.messages.some((m) => m.files.some((f) => /csv/i.test(f)))),
  },
  DriveApp: {
    getFoldersByName: () => ({ hasNext: () => false }),
    createFolder: () => ({ createFile: (blob) => saved.push(blob.name) }),
  },
  PropertiesService: {
    getScriptProperties: () => ({ getProperty: (k) => (k in props ? props[k] : null), setProperty: (k, v) => { props[k] = v; } }),
  },
  Utilities: { formatDate: (d) => d + "_" },
};
vm.createContext(sandbox);
vm.runInContext(code, sandbox);

function run() {
  const before = saved.length;
  vm.runInContext("saveSaneiCsv()", sandbox);
  return saved.length - before;
}

let failed = 0;
function check(ok, name) {
  console.log((ok ? "  OK  " : "  NG  ") + name);
  if (!ok) failed++;
}

practice.messages.push(makeMessage("20260930_0900",
  ["sample_A_2026-10-01.csv", "sample_B_2026-12-30.csv", "sample_C_extra_column.csv", "memo.pdf"]));
check(run() === 3, "1通目: CSV の3つだけ保存する（PDF は保存しない）");
check(run() === 0, "もう一度動かしても、同じものは保存しない");
practice.messages.push(makeMessage("20260930_1000", ["sample_D_unknown_size.csv"]));
check(run() === 1, "同じスレッドにまとめられた2通目も保存する");
other.messages.push(makeMessage("20260930_1005", ["report.xlsx"]));
check(run() === 0, "CSV の無いメールでは何もしない");
check(practice.labels.includes("sanei-saved"), "保存したスレッドに目印のラベルを付ける");
check(saved[0] === "20260930_0900_sample_A_2026-10-01.csv", "ファイル名の前に受け取った日時を付ける");

if (failed) {
  console.log(`❌ ${failed} 件が期待と違います`);
  process.exit(1);
}
console.log("✅ GAS（Gmail → Googleドライブ）の見本は期待どおりに動きます");
