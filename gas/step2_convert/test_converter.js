// GAS 版の変換（2_rules.gs・3_converter.gs）を、アプリの正解CSV（tests/expected）と1バイトずつ比べる。
//   node gas/step2_convert/test_converter.js
// 架空サンプル（tests/samples のすべて）を変換し、ファイル名・中身（BOM・改行まで）・警告がすべて同じなら合格。
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const ROOT = path.resolve(__dirname, "..", "..");
const ctx = {};
vm.createContext(ctx);
// GAS と同じく、2つのファイルを1つの場所に読み込む（最後の行で外から使える名前にする）
vm.runInContext(
  fs.readFileSync(path.join(__dirname, "2_rules.gs"), "utf8") + "\n" +
  fs.readFileSync(path.join(__dirname, "3_converter.gs"), "utf8") +
  "\nthis.RULES = RULES; this.SaneiConverter = SaneiConverter;", ctx);

// アプリと同じ順で読む（UTF-8 → だめなら Shift_JIS）
function decode(raw) {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(raw).replace(/^﻿/, "");
  } catch (e) {
    return new TextDecoder("shift_jis").decode(raw);
  }
}

let failed = 0;
const samples = path.join(ROOT, "tests", "samples");
const expected = path.join(ROOT, "tests", "expected");
for (const name of fs.readdirSync(samples).filter((n) => n.endsWith(".csv")).sort()) {
  const res = ctx.SaneiConverter.convert(decode(fs.readFileSync(path.join(samples, name))), ctx.RULES);
  const dir = path.join(expected, name.slice(0, -4));
  const want = fs.readdirSync(dir).filter((n) => n !== "warnings.txt").sort();
  const got = res.cases.map((c) => c.fileName).sort();
  const problems = [];
  if (JSON.stringify(want) !== JSON.stringify(got)) problems.push(`ファイル名が違う: 正解 ${want} ／ 結果 ${got}`);
  for (const c of res.cases) {
    const file = path.join(dir, c.fileName);
    if (!fs.existsSync(file)) continue;
    const bytes = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(c.csv, "utf8")]);
    if (!bytes.equals(fs.readFileSync(file))) {
      const e = fs.readFileSync(file, "utf8").replace(/^﻿/, "").split("\r\n");
      const a = c.csv.split("\r\n");
      const i = e.findIndex((line, k) => line !== a[k]);
      problems.push(`${c.fileName}: 中身が違う（${i + 1}番目の区切り）\n    正解 ${JSON.stringify(e[i])}\n    結果 ${JSON.stringify(a[i])}`);
    }
  }
  const wantW = fs.readFileSync(path.join(dir, "warnings.txt"), "utf8").split("\n").filter((l) => l);
  const gotW = res.warnings.concat(...res.cases.map((c) => c.warnings));
  if (JSON.stringify(wantW) !== JSON.stringify(gotW)) problems.push(`警告が違う:\n    正解 ${JSON.stringify(wantW)}\n    結果 ${JSON.stringify(gotW)}`);
  if (problems.length) {
    failed++;
    console.log(`  NG  ${name}\n    ` + problems.join("\n    "));
  } else {
    console.log(`  OK  ${name}（${res.cases.length}ファイル）`);
  }
}

// 見出しが無いファイル（三映CSVではない）は、推測せずにエラーにする
try {
  ctx.SaneiConverter.convert("日付,金額\r\n2026/10/01,1000\r\n", ctx.RULES);
  failed++;
  console.log("  NG  三映CSVでないファイルがエラーにならない");
} catch (e) {
  console.log("  OK  三映CSVでないファイルはエラー: " + e.message.slice(0, 30) + "…");
}

if (failed) {
  console.log(`❌ ${failed} 件が正解と違います`);
  process.exit(1);
}
console.log("✅ GAS 版の変換は、アプリの正解CSVと1バイトも違いません");
