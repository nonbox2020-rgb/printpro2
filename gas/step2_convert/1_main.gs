// ===== 三映CSV → 勘太郎CSV 自動変換（Gmail → Googleドライブ）=====
// ファイルは3つ: 1_main.gs（この流れ）・2_rules.gs（変換のルール）・3_converter.gs（変換のしくみ）
// 5分おきのトリガーで saveSaneiCsv を動かす（第1回で作ったトリガーがそのまま使える）。
//
// ドライブの中（すべて「三映CSV連携」フォルダの中にまとめる）:
//   1_受信/2026-09-30/       Gmail に届いた三映CSV（元のまま）。受け取った日ごと
//   2_勘太郎用/2026-10-01/   変換できた勘太郎CSV（35列・1案件1ファイル）。下版予定日ごと
//   3_要確認/2026-10-02/     警告があった案件。勘太郎へは出さない。人が確かめる
//   4_もう一度変換/           ルールを直したあと、三映CSVをここへ入れると変換し直す
//   変換の記録               スプレッドシート。いつ・どのCSVの・どの案件を・どこへ

const PARENT_NAME = '三映CSV連携';
const LABEL_NAME = 'sanei-saved';                              // 保存したメールに付ける目印
const SEARCH = 'has:attachment filename:csv newer_than:7d';    // 本番では from:（三映様のアドレス） を足す
const GROUP_BY_DATE = true;   // 勘太郎のパソコンへ同期するときは false（日付のフォルダを作らない）

function saveSaneiCsv() {
  const root = childFolder_(DriveApp.getRootFolder(), PARENT_NAME);
  const log = openLog_(root);
  const results = [];

  // ① Gmail に届いた新しい三映CSVを「1_受信」に保存して、変換する
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
        results.push(convertFile_(root, file, false, log));
      });
      done.push(msg.getId());
    });
    thread.addLabel(label);
  });
  props.setProperty('done', JSON.stringify(done.slice(-300)));  // 最近の300通だけ覚える

  // ② 「4_もう一度変換」に入れられた三映CSVを変換し直し、「1_受信」へ戻す
  const again = [];
  const files = childFolder_(root, '4_もう一度変換').getFiles();
  while (files.hasNext()) again.push(files.next());
  again.forEach(file => {
    results.push(convertFile_(root, file, true, log));
    file.moveTo(childFolder_(childFolder_(root, '1_受信'), day_(new Date())));
  });

  if (results.length) notify_(root, results);
}

// 1つの三映CSVを変換し、案件ごとに「2_勘太郎用」か「3_要確認」へ保存する
function convertFile_(root, file, isAgain, log) {
  const r = { source: file.getName(), ok: 0, check: 0, skipped: 0, notes: [], error: '' };
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
  res.cases.forEach(c => {
    const okDir = outFolder_(root, '2_勘太郎用', res.plateDate);
    const checkDir = outFolder_(root, '3_要確認', res.plateDate);
    const warnings = c.warnings.slice();
    const already = okDir.getFilesByName(c.fileName).hasNext();
    if (already && isAgain) {   // 変換し直し: 勘太郎用にあるものは出し直さない（勘太郎への二重登録を防ぐ）
      r.skipped++;
      log.appendRow([now_(), r.source, c.orderNo, c.section, c.rowCount, 'とばした（2_勘太郎用にあり）', '']);
      return;
    }
    if (already) warnings.push('[二重] 同じ名前のCSVがすでに「2_勘太郎用」にあります（同じ三映CSVが2回届いた可能性）');
    removeSame_(checkDir, c.fileName);   // 前の要確認の分は、新しい結果で置きかえる
    (warnings.length ? checkDir : okDir).createFile(csvBlob_(c));
    if (warnings.length) r.check++; else r.ok++;
    warnings.forEach(w => r.notes.push(c.orderNo + ' ' + w));
    log.appendRow([now_(), r.source, c.orderNo, c.section, c.rowCount,
      warnings.length ? '3_要確認' : '2_勘太郎用', warnings.join('\n')]);
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
function csvBlob_(c) {
  return Utilities.newBlob('').setDataFromString((RULES.output.bom ? '﻿' : '') + c.csv, 'UTF-8')
    .setContentType('text/csv').setName(c.fileName);
}

// 「2_勘太郎用」「3_要確認」の中の、下版予定日のフォルダ
function outFolder_(root, name, plateDate) {
  const dir = childFolder_(root, name);
  if (!GROUP_BY_DATE) return dir;
  return childFolder_(dir, plateDate ? plateDate.split('/').join('-') : '下版予定日なし');
}

// フォルダの中のフォルダ（無ければ作る）
function childFolder_(parent, name) {
  const found = parent.getFoldersByName(name);
  return found.hasNext() ? found.next() : parent.createFolder(name);
}

function removeSame_(folder, name) {
  const found = folder.getFilesByName(name);
  while (found.hasNext()) found.next().setTrashed(true);
}

// 「変換の記録」スプレッドシート（無ければ作る）
function openLog_(root) {
  const found = root.getFilesByName('変換の記録');
  if (found.hasNext()) return SpreadsheetApp.openById(found.next().getId()).getSheets()[0];
  const ss = SpreadsheetApp.create('変換の記録');
  DriveApp.getFileById(ss.getId()).moveTo(root);
  const sheet = ss.getSheets()[0];
  sheet.appendRow(['日時', '三映CSV', '受注№', '区分', '行数', '結果', '警告・お知らせ']);
  sheet.setFrozenRows(1);
  return sheet;
}

// 自分にメールで知らせる（要確認・エラーがあれば件名に出す）
function notify_(root, results) {
  const total = key => results.reduce((n, r) => n + r[key], 0);
  const errors = results.filter(r => r.error).length;
  let subject = '【三映CSV】勘太郎用 ' + total('ok') + '件';
  if (total('check')) subject += '・要確認 ' + total('check') + '件';
  if (errors) subject += '・エラー ' + errors + '件';
  const lines = [];
  results.forEach(r => {
    lines.push('■ ' + r.source);
    if (r.error) {
      lines.push('  エラー（変換できない）: ' + r.error);
    } else {
      lines.push('  勘太郎用 ' + r.ok + '件・要確認 ' + r.check + '件' +
        (r.skipped ? '・とばした ' + r.skipped + '件（2_勘太郎用にあり）' : ''));
    }
    r.notes.forEach(n => lines.push('  ・' + n));
  });
  lines.push('', 'フォルダ: ' + root.getUrl());
  MailApp.sendEmail(Session.getEffectiveUser().getEmail(), subject, lines.join('\n'));
}

function day_(date) { return Utilities.formatDate(date, 'Asia/Tokyo', 'yyyy-MM-dd'); }
function time_(date) { return Utilities.formatDate(date, 'Asia/Tokyo', 'HHmm'); }
function now_() { return Utilities.formatDate(new Date(), 'Asia/Tokyo', 'yyyy/MM/dd HH:mm'); }

// 練習のやり直し用: 保存済みメールの記録を消す（次の実行で、7日以内のCSVつきメールをもう一度保存・変換する）。
// きれいにやり直すときは、先にドライブの「三映CSV連携」フォルダを消してから実行する
function resetPractice() {
  PropertiesService.getScriptProperties().deleteProperty('done');
}
