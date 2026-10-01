// ===== 三映CSV → 勘太郎CSV 自動変換（Gmail → Googleドライブ）=====
// ファイルは3つ: 1_main.gs（この流れ）・2_rules.gs（変換のルール）・3_converter.gs（変換のしくみ）
// 勘太郎のパソコンが取りに来る受け取り口を使うときは、4_webapp.gs も足す（入れ方は 4_webapp.gs の先頭）
//
// ■ はじめに1回だけ: setup を実行する（最初に Gmail・ドライブ・メール送信の許可を聞かれるので「許可」）
//   - 下の「設定」をスクリプト プロパティに作る（値は「未設定」、KEEP_DAYS は 3）
//   - 5分おきに saveSaneiCsv を動かすトリガーを作る（すでにあれば作らない）
//
// ■ 設定はコードではなく、スクリプト プロパティで変える
//   （左の歯車「プロジェクトの設定」→ いちばん下「スクリプト プロパティ」→「スクリプト プロパティを編集」）
//   SANEI_FROM     三映様のメールアドレス。複数はカンマ区切り。会社のドメイン（例 sanei.co.jp）だけでもよい
//                  「未設定」なら送り主で絞らない（練習用。本番では必ず入れる）
//   CHECK_ADDRESS  三映CSVが届くメールアドレス（このGmailで受け取っているアドレス）。「未設定」なら宛先で絞らない
//                  ※ GAS が見られるのは、このGASを作ったGoogleアカウントの Gmail だけ
//                    （ほかのアドレスに届くメールは、このアカウントへ自動転送しておく）
//   NOTIFY_TO      結果を知らせるメールアドレス。複数はカンマ区切り。「未設定」ならこのアカウントへ
//   KEEP_DAYS      ドライブに保存したCSVを残す日数（初めは 3）。過ぎたらゴミ箱へ（30日間は元に戻せる）。0 なら消さない
//   START_DATE     この日（時刻も書ける）より前に届いたメールは読まない。初めは 2026/10/01（本番を始めた日）
//                  例 2026/10/01 、2026/10/01 15:00（日本の時刻）。「未設定」なら日付で絞らない（7日以内を全部読む）
//   SUBJECT_WORDS  件名にこの言葉が入っているメールだけ読む。初めは「最終予定表」（「仮予定表」は読まない）
//                  複数はカンマ区切り（どれか1つが入っていればよい）。「未設定」なら件名で絞らない
//                  読まなかったメールは「変換の記録」に1行残す（変換はしない・メールでは知らせない）
//   設定を変えたら checkSettings を実行すると、どのメールが対象になるかを確かめられる。
//   done・LAST_CLEANUP・AGENT_LAST_SEEN・PICKUP_ALERTED は GAS が使う控えなので触らない。
//   AGENT_TOKEN は受け取り口の合言葉（4_webapp.gs の makeAgentToken で作る）。
//
// ■ ドライブの中（すべて「三映CSV連携」フォルダの中）:
//   1_受信/2026-09-30/   Gmail に届いた三映CSV（元のまま）。受け取った日ごと
//   2_勘太郎用/          変換した勘太郎CSV（35列・1案件1ファイル）。ここから勘太郎へ渡す
//   変換の記録           スプレッドシート。いつ・どのCSVの・どの案件を・どのファイルにしたか
//
// 同じ受注№のCSVが届いても、そのまま勘太郎用に入れる（基幹システムはそのまま読み、あとで作業員が確かめて直す）。
// 名前が同じときは、最後に _2、_3 … を付ける。警告のある案件も入れて、記録とメールで「確認する案件」として知らせる。

const PARENT_NAME = '三映CSV連携';
const LABEL_NAME = 'sanei-saved';                                 // 保存したメールに付ける目印
const SEARCH_BASE = 'has:attachment filename:csv newer_than:7d';  // 7日以内の、CSV つきのメール
const UNSET = '未設定';
const SETTINGS = {                                                // スクリプト プロパティの名前と、はじめの値
  SANEI_FROM: UNSET,
  CHECK_ADDRESS: UNSET,
  NOTIFY_TO: UNSET,
  KEEP_DAYS: '3',
  START_DATE: '2026/10/01',   // 本番を始めた日。これより前に届いたメールは読まない（古いメールを勘太郎へ送らない）
  SUBJECT_WORDS: '最終予定表',  // 件名にこの言葉があるメールだけ読む（「仮予定表」は読まない）
};

function saveSaneiCsv() {
  // 5分おきの回と、手で押した「実行」が重なっても同じメールを二度変換しないよう、1回ずつ順に動かす。
  // ほかの回が動いていれば終わるまで（最大1分）待ち、終わったら続きをする
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(60 * 1000)) {
    console.log('ほかの回が動いているため、今回は何もしませんでした（次の回で処理します）');
    return;
  }
  try {
    saveSaneiCsvNow_();
  } finally {
    lock.releaseLock();
  }
}

function saveSaneiCsvNow_() {
  const s = settings_();
  const root = childFolder_(DriveApp.getRootFolder(), PARENT_NAME);
  const log = openLog_(root);
  const results = [];

  const label = GmailApp.getUserLabelByName(LABEL_NAME) || GmailApp.createLabel(LABEL_NAME);
  const props = PropertiesService.getScriptProperties();
  const done = JSON.parse(props.getProperty('done') || '[]');   // 保存し終わったメールのID
  GmailApp.search(searchQuery_(s), 0, 50).forEach(thread => {
    thread.getMessages().forEach(msg => {
      if (done.includes(msg.getId())) return;                    // 保存済みのメールはとばす
      if (s.start && msg.getDate() < s.start) return;            // START_DATE より前に届いたメールは読まない
      if (fromSanei_(msg, s) && !subjectOk_(msg, s)) {           // 件名に「最終予定表」が無い（仮予定表など）は読まない
        const csvNames = msg.getAttachments().map(att => att.getName()).filter(n => /\.csv$/i.test(n));
        if (csvNames.length) {
          log.appendRow([now_(), csvNames.join(' / '), '', '', '', '読まなかった',
            '件名に「' + s.subjectWords.join('」「') + '」が無い: ' + msg.getSubject()]);
        }
      } else if (fromSanei_(msg, s)) {                           // 同じスレッドの、三映様以外のメールは使わない
        msg.getAttachments().forEach(att => {
          if (!/\.csv$/i.test(att.getName())) return;            // CSV だけ
          const inbox = childFolder_(childFolder_(root, '1_受信'), day_(msg.getDate()));
          const file = inbox.createFile(att.copyBlob().setName(time_(msg.getDate()) + '_' + att.getName()));
          results.push(convertFile_(root, file, log));
        });
      }
      done.push(msg.getId());
    });
    thread.addLabel(label);
  });
  props.setProperty('done', JSON.stringify(done.slice(-300)));  // 最近の300通だけ覚える

  if (results.length) notify_(root, results, s);
  cleanupIfDue_(root, log, s);
  if (typeof watchPickup_ === 'function') watchPickup_(root, s);   // 4_webapp.gs があるとき: 受け取りの見張り
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

// ---------------- 設定（スクリプト プロパティ）----------------

function settings_() {
  const p = PropertiesService.getScriptProperties().getProperties();
  const value = key => {
    const v = String(p[key] == null ? SETTINGS[key] : p[key]).trim();
    return v === UNSET ? '' : v;
  };
  const list = key => value(key).split(/[,、，\s]+/).map(x => x.trim()).filter(x => x);
  let keepDays = parseInt(value('KEEP_DAYS'), 10);
  if (isNaN(keepDays) || keepDays < 0) keepDays = Number(SETTINGS.KEEP_DAYS);
  return { from: list('SANEI_FROM'), check: value('CHECK_ADDRESS'), notify: list('NOTIFY_TO'), keepDays: keepDays,
    start: startDate_(value('START_DATE')), subjectWords: list('SUBJECT_WORDS') };
}

// START_DATE（例 2026/10/01 、2026/10/01 15:00。日本の時刻）→ その時刻。空なら null（日付で絞らない）
// 書き間違いのまま古いメールまで読まないよう、読めない値なら止めて知らせる
function startDate_(text) {
  if (!text) return null;
  const m = /^(\d{4})[\/\-.](\d{1,2})[\/\-.](\d{1,2})(?:\s+(\d{1,2}):(\d{2}))?$/.exec(text);
  const y = m ? +m[1] : 0, mo = m ? +m[2] : 0, d = m ? +m[3] : 0, h = m && m[4] ? +m[4] : 0, mi = m && m[5] ? +m[5] : 0;
  const date = new Date(Date.UTC(y, mo - 1, d, h - 9, mi));
  const jst = new Date(date.getTime() + 9 * 3600 * 1000);
  if (!m || h > 23 || mi > 59 || jst.getUTCFullYear() !== y || jst.getUTCMonth() !== mo - 1 || jst.getUTCDate() !== d) {
    throw new Error('スクリプト プロパティの START_DATE が読めません（例 2026/10/01 または 2026/10/01 15:00）: ' + text);
  }
  return date;
}

// Gmail の検索: 7日以内・CSV つき ＋ 三映様から（SANEI_FROM）＋ このアドレスに届いた（CHECK_ADDRESS）
// ＋ START_DATE より後（Gmail の after: は秒で渡すと時刻まで正確）
function searchQuery_(s) {
  let q = SEARCH_BASE;
  if (s.start) q += ' after:' + Math.floor(s.start.getTime() / 1000);
  if (s.from.length) q += ' from:(' + s.from.join(' OR ') + ')';
  if (s.check) q += ' deliveredto:' + s.check;
  return q;
}

function fromSanei_(msg, s) {
  if (!s.from.length) return true;
  const sender = String(msg.getFrom() || '').toLowerCase();
  return s.from.some(a => sender.indexOf(a.toLowerCase()) >= 0);
}

// 件名に SUBJECT_WORDS のどれかが入っているか。全角/半角と空白のちがいは気にしない。未設定なら絞らない
function subjectOk_(msg, s) {
  if (!s.subjectWords.length) return true;
  const norm = t => String(t || '').normalize('NFKC').replace(/\s/g, '');
  const subject = norm(msg.getSubject());
  return s.subjectWords.some(w => subject.indexOf(norm(w)) >= 0);
}

function notifyTo_(s) {
  return s.notify.length ? s.notify.join(',') : Session.getEffectiveUser().getEmail();
}

// はじめに1回: 設定の欄を作り、5分おきのトリガーを作る。もう一度実行しても、変えた設定は消さない
function setup() {
  const props = PropertiesService.getScriptProperties();
  const current = props.getProperties();
  Object.keys(SETTINGS).forEach(key => {
    if (!(key in current)) props.setProperty(key, SETTINGS[key]);
  });
  const has = ScriptApp.getProjectTriggers().some(t => t.getHandlerFunction() === 'saveSaneiCsv');
  if (!has) ScriptApp.newTrigger('saveSaneiCsv').timeBased().everyMinutes(5).create();
  console.log(has ? '5分おきのトリガーは、すでにあります' : '5分おきのトリガーを作りました');
  return checkSettings();
}

// 今の設定と、それで対象になるメールの数を実行ログに出す（何も保存しない）
function checkSettings() {
  const s = settings_();
  const me = Session.getEffectiveUser().getEmail();
  const q = searchQuery_(s);
  const threads = GmailApp.search(q, 0, 50);
  const hasTrigger = ScriptApp.getProjectTriggers().some(t => t.getHandlerFunction() === 'saveSaneiCsv');
  const lines = [
    'このGASが見ている Gmail: ' + me,
    '三映様のアドレス（SANEI_FROM）: ' + (s.from.join(', ') || '未設定（送り主で絞らない。本番では入れてください）'),
    '三映CSVが届くアドレス（CHECK_ADDRESS）: ' + (s.check || '未設定（宛先で絞らない）'),
    '結果を知らせる先（NOTIFY_TO）: ' + notifyTo_(s),
    'CSVを残す日数（KEEP_DAYS）: ' + (s.keepDays ? s.keepDays + '日（過ぎたらゴミ箱へ）' : '0（消さない）'),
    'これより前に届いたメールは読まない（START_DATE）: ' +
      (s.start ? Utilities.formatDate(s.start, 'Asia/Tokyo', 'yyyy/MM/dd HH:mm') : '未設定（日付で絞らない。7日以内を全部読む）'),
    '件名にこの言葉があるメールだけ読む（SUBJECT_WORDS）: ' + (s.subjectWords.join(', ') || '未設定（件名で絞らない）'),
    'Gmail の検索: ' + q,
    'いま対象になるメール（7日以内・START_DATE 以降・CSV つき）: ' + threads.length + ' 件のスレッド',
    'そのうち件名に言葉が入っているメール: ' + threads.reduce((n, t) => n + t.getMessages()
      .filter(m => (!s.start || m.getDate() >= s.start) && fromSanei_(m, s) && subjectOk_(m, s)).length, 0) + ' 通',
    '5分おきのトリガー: ' + (hasTrigger ? 'あり' : 'なし（setup を実行してください）'),
  ];
  if (s.check && s.check.toLowerCase() !== String(me).toLowerCase()) {
    lines.push('※ CHECK_ADDRESS がこのアカウントと違います。そのアドレスに届くメールが、この Gmail に届いて（転送されて）いるか確かめてください');
  }
  console.log(lines.join('\n'));
  return lines;
}

// ---------------- 3日たったCSVを消す ----------------

// 1時間に1回だけ見る。KEEP_DAYS 日より前にドライブへ保存したCSVを、ゴミ箱へ移す（30日間は元に戻せる）
function cleanupIfDue_(root, log, s) {
  if (!s.keepDays) return;
  const props = PropertiesService.getScriptProperties();
  if (Date.now() - Number(props.getProperty('LAST_CLEANUP') || 0) < 60 * 60 * 1000) return;
  props.setProperty('LAST_CLEANUP', String(Date.now()));
  const removed = removeOldCsv_(root, s.keepDays);
  if (!removed.total) return;
  const parts = Object.keys(removed.byFolder).map(k => k + ' ' + removed.byFolder[k] + '件');
  log.appendRow([now_(), '', '', '', '', '削除', s.keepDays + '日たったCSVをゴミ箱へ: ' + parts.join('・')]);
  if (removed.unsent.length) {
    // 勘太郎へ渡す前に日数が過ぎたもの。気づけるように知らせる
    const body = ['「2_勘太郎用」に ' + s.keepDays + '日以上残っていた勘太郎CSVを、ゴミ箱へ移しました。',
      '勘太郎へ渡していない可能性があります。必要なら、ドライブの「ゴミ箱」から元に戻してください（30日間）。', '']
      .concat(removed.unsent.map(n => '・' + n), ['', 'フォルダ: ' + root.getUrl()]);
    MailApp.sendEmail(notifyTo_(s), '【三映CSV】勘太郎へ渡していないCSVを削除しました ' + removed.unsent.length + '件', body.join('\n'));
  }
}

function removeOldCsv_(root, keepDays) {
  const limit = Date.now() - keepDays * 24 * 60 * 60 * 1000;
  const result = { total: 0, byFolder: {}, unsent: [] };
  const walk = (folder, top) => {
    const files = folder.getFiles();
    while (files.hasNext()) {
      const f = files.next();
      if (f.isTrashed() || !/\.csv$/i.test(f.getName()) || f.getDateCreated().getTime() > limit) continue;
      f.setTrashed(true);
      result.total++;
      const where = top || PARENT_NAME;
      result.byFolder[where] = (result.byFolder[where] || 0) + 1;
      if (top === '2_勘太郎用') result.unsent.push(f.getName());
    }
    const subs = folder.getFolders();
    while (subs.hasNext()) {
      const sub = subs.next();
      if (sub.isTrashed()) continue;
      walk(sub, top || sub.getName());
      // 空になった日付のフォルダ（1_受信 の中）も片づける
      if (top === '1_受信' && isEmpty_(sub) && sub.getDateCreated().getTime() <= limit) sub.setTrashed(true);
    }
  };
  walk(root, '');
  return result;
}

function isEmpty_(folder) {
  const files = folder.getFiles();
  while (files.hasNext()) if (!files.next().isTrashed()) return false;
  const subs = folder.getFolders();
  while (subs.hasNext()) if (!subs.next().isTrashed()) return false;
  return true;
}

// ---------------- 読む・書く ----------------

// 三映CSVの文字を読む。UTF-8 でなければ Shift_JIS（㈱・№ などを含む Windows の文字コード MS932）
function readCsv_(blob) {
  let text = blob.getDataAsString('UTF-8');
  if (text.indexOf('\uFFFD') >= 0) {
    try { text = blob.getDataAsString('MS932'); } catch (e) { text = blob.getDataAsString('Shift_JIS'); }
  }
  return text.replace(/^\uFEFF/, '');
}

// 勘太郎CSVのファイル（UTF-8・BOM付き）
function csvBlob_(csv, name) {
  return Utilities.newBlob('').setDataFromString((RULES.output.bom ? '\uFEFF' : '') + csv, 'UTF-8')
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

// メールで知らせる（確認する案件・エラーがあれば件名に出す）
function notify_(root, results, s) {
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
  if (s.keepDays) lines.push('ドライブのCSVは ' + s.keepDays + '日たつとゴミ箱へ移ります（30日間は元に戻せます）。');
  MailApp.sendEmail(notifyTo_(s), subject, lines.join('\n'));
}

function day_(date) { return Utilities.formatDate(date, 'Asia/Tokyo', 'yyyy-MM-dd'); }
function time_(date) { return Utilities.formatDate(date, 'Asia/Tokyo', 'HHmm'); }
function now_() { return Utilities.formatDate(new Date(), 'Asia/Tokyo', 'yyyy/MM/dd HH:mm'); }

// 練習のやり直し用: 保存済みメールの記録を消す（次の実行で、7日以内のCSVつきメールをもう一度保存・変換する）。
// きれいにやり直すときは、先にドライブの「三映CSV連携」フォルダをゴミ箱に入れてから実行する
function resetPractice() {
  PropertiesService.getScriptProperties().deleteProperty('done');
}
