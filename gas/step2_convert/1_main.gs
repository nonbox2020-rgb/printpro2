// ===== 三映CSV → 勘太郎CSV 自動変換（Gmail → Googleドライブ）=====
// ファイルは3つ: 1_main.gs（この流れ）・2_rules.gs（変換のルール）・3_converter.gs（変換のしくみ）
// 5分おきのトリガーで saveSaneiCsv を動かす（第1回で作ったトリガーがそのまま使える）。
//
// ドライブの中（すべて「三映CSV連携」フォルダの中にまとめる）:
//   1_受信/2026-09-30/   Gmail に届いた三映CSV（元のまま）。受け取った日ごと
//   2_勘太郎用/          変換した勘太郎CSV（35列・1案件1ファイル）。勘太郎のパソコンの移し係が、ここから指定フォルダへ移す
//   変換の記録           スプレッドシート。いつ・どのCSVの・どの案件を・どのファイルにしたか
//
// 同じ受注№のCSVが届いても、そのまま勘太郎用に入れる（基幹システムはそのまま読み、あとで作業員が確かめて直す）。
// 名前が同じときは、最後に _2、_3 … を付ける。警告のある案件も入れて、記録とメールで「確認する案件」として知らせる。

const PARENT_NAME = '三映CSV連携';
const LABEL_NAME = 'sanei-saved';                              // 保存したメールに付ける目印
const SEARCH = 'has:attachment filename:csv newer_than:7d';    // 本番では from:（三映様のアドレス） を足す

function saveSaneiCsv() {
  const root = childFolder_(DriveApp.getRootFolder(), PARENT_NAME);
  const log = openLog_(root);
  const results = [];

  const label = GmailApp.getUserLabelByName(LABEL_NAME) || GmailApp.createLabel(LABEL_NAME);
  const props = PropertiesService.getScriptProperties();
  const done = JSON.parse(props.getProperty('done') || '[]');   // 保存し終わったメールのID
  GmailApp.search(SEARCH, 0, 50).forEach(thread => {
    thread.getMessages().forEach(msg => {
      if (done.includes(msg.getId())) return;                  // 保存済みのメールはとばす
      msg.getAttachments().forEach(att => {
        if (!/\.csv$/i.test(att.getName())) return;            // CSV だけ
        const inbox = childFolder_(childFolder_(root, '1_受信'), day_(msg.getDate()));
        const file = inbox.createFile(att.copyBlob().setName(time_(msg.getDate()) + '_' + att.getName()));
        results.push(convertFile_(root, file, log));
      });
      done.push(msg.getId());
    });
    thread.addLabel(label);
  });
  props.setProperty('done', JSON.stringify(done.slice(-300)));  // 最近の300通だけ覚える

  if (results.length) notify_(root, results);
}

// 1つの三映CSVを変換し、案件ごとに「2_勘太郎用」へ保存する
function convertFile_(root, file, log) {
  const r = { source: file.getName(), saved: 0, check: 0, notes: [], error: '' };
  let res;
  try {
    res = SaneiConverter.convert(readCsv_(file.getBlob()), RULES);
  } catch (e) {
    r.error = e.message;
    log.appendRow([now_(), r.source, '', '', '', 'エラー（変換できない）', e.message]);
    return r;
  }
  res.warnings.forEach(w => {
    r.notes.push(w);
    log.appendRow([now_(), r.source, '', '', '', 'お知らせ', w]);
  });
  const outDir = childFolder_(root, '2_勘太郎用');
  res.cases.forEach(c => {
    const name = uniqueName_(outDir, c.fileName);
    outDir.createFile(csvBlob_(c.csv, name));
    r.saved++;
    if (c.warnings.length) r.check++;
    c.warnings.forEach(w => r.notes.push(name + ' ' + w));
    log.appendRow([now_(), r.source, c.orderNo, c.section, c.rowCount, name, c.warnings.join('\n')]);
  });
  return r;
}

// 三映CSVの文字を読む。UTF-8 でなければ Shift_JIS（㈱・№ などを含む Windows の文字コード MS932）
function readCsv_(blob) {
  let text = blob.getDataAsString('UTF-8');
  if (text.indexOf('�') >= 0) {
    try { text = blob.getDataAsString('MS932'); } catch (e) { text = blob.getDataAsString('Shift_JIS'); }
  }
  return text.replace(/^﻿/, '');
}

// 勘太郎CSVのファイル（UTF-8・BOM付き）
function csvBlob_(csv, name) {
  return Utilities.newBlob('').setDataFromString((RULES.output.bom ? '﻿' : '') + csv, 'UTF-8')
    .setContentType('text/csv').setName(name);
}

// 同じ名前があれば _2、_3 … を付けた名前
function uniqueName_(folder, name) {
  const dot = name.lastIndexOf('.');
  const stem = dot > 0 ? name.slice(0, dot) : name, ext = dot > 0 ? name.slice(dot) : '';
  let candidate = name;
  for (let n = 2; hasFile_(folder, candidate); n++) candidate = stem + '_' + n + ext;
  return candidate;
}

// フォルダの中のフォルダ（無ければ作る）。ゴミ箱に入れたフォルダは使わない
function childFolder_(parent, name) {
  const found = parent.getFoldersByName(name);
  while (found.hasNext()) {
    const folder = found.next();
    if (!folder.isTrashed()) return folder;
  }
  return parent.createFolder(name);
}

// 同じ名前のファイルがあるか（ゴミ箱の中は数えない）
function hasFile_(folder, name) {
  const found = folder.getFilesByName(name);
  while (found.hasNext()) {
    if (!found.next().isTrashed()) return true;
  }
  return false;
}

// 「変換の記録」スプレッドシート（無ければ作る）
function openLog_(root) {
  const found = root.getFilesByName('変換の記録');
  while (found.hasNext()) {
    const file = found.next();
    if (!file.isTrashed()) return SpreadsheetApp.openById(file.getId()).getSheets()[0];
  }
  const ss = SpreadsheetApp.create('変換の記録');
  DriveApp.getFileById(ss.getId()).moveTo(root);
  const sheet = ss.getSheets()[0];
  sheet.appendRow(['日時', '三映CSV', '受注№', '区分', '行数', '保存したファイル', '警告・お知らせ']);
  sheet.setFrozenRows(1);
  return sheet;
}

// 自分にメールで知らせる（確認する案件・エラーがあれば件名に出す）
function notify_(root, results) {
  const total = key => results.reduce((n, r) => n + r[key], 0);
  const errors = results.filter(r => r.error).length;
  let subject = '【三映CSV】勘太郎用 ' + total('saved') + '件';
  if (total('check')) subject += '・確認 ' + total('check') + '件';
  if (errors) subject += '・エラー ' + errors + '件';
  const lines = [];
  results.forEach(r => {
    lines.push('■ ' + r.source);
    lines.push(r.error ? '  エラー（変換できない）: ' + r.error : '  勘太郎用に ' + r.saved + '件');
    r.notes.forEach(n => lines.push('  ・' + n));
  });
  lines.push('', '警告のある案件は、勘太郎に入ったあとで確認して直してください。', 'フォルダ: ' + root.getUrl());
  MailApp.sendEmail(Session.getEffectiveUser().getEmail(), subject, lines.join('\n'));
}

function day_(date) { return Utilities.formatDate(date, 'Asia/Tokyo', 'yyyy-MM-dd'); }
function time_(date) { return Utilities.formatDate(date, 'Asia/Tokyo', 'HHmm'); }
function now_() { return Utilities.formatDate(new Date(), 'Asia/Tokyo', 'yyyy/MM/dd HH:mm'); }

// 練習のやり直し用: 保存済みメールの記録を消す（次の実行で、7日以内のCSVつきメールをもう一度保存・変換する）。
// きれいにやり直すときは、先にドライブの「三映CSV連携」フォルダをゴミ箱に入れてから実行する
function resetPractice() {
  PropertiesService.getScriptProperties().deleteProperty('done');
}
