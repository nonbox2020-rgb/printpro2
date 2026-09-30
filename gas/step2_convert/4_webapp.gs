// ===== 勘太郎のパソコンの受け取り口（ウェブアプリ）=====
// 勘太郎のパソコンの受け取り係（tools/kantaro_pc/）が、5分おきにここへ取りに来る。
// 合言葉（スクリプト プロパティ AGENT_TOKEN）を知っている相手にだけ「2_勘太郎用」の勘太郎CSVを渡し、
// 受け取ったと知らせが来たら「3_渡し済み」へ移す（二度渡さない）。1_main.gs と同じプロジェクトに置く。
//
// ■ 入れ方（1回だけ）
//   1. makeAgentToken を実行 → 実行ログに出た合言葉を控える（勘太郎のパソコンのかんたん設定で貼る）
//   2. 右上の「デプロイ」→「新しいデプロイ」→ 左の歯車「ウェブアプリ」
//      → 次のユーザーとして実行「自分」→ アクセスできるユーザー「全員」→「デプロイ」
//      → 出てきた「ウェブアプリ」の URL（…/exec で終わる）を控える
//   コードを直したとき: 「デプロイ」→「デプロイを管理」→ 鉛筆 → バージョン「新バージョン」→「デプロイ」（URL は変わらない）
//
// ■ 受け取り係とのやりとり（GET。答えはいつも JSON。ok が false ならエラー）
//   ?action=ping&token=…          つながるか確かめる
//   ?action=list&token=…          渡すファイルの一覧 { files: [{ id, name, size }] }（古い順）
//   ?action=file&id=…&token=…     1つのファイルの中身 { name, size, data（base64） }
//   ?action=done&id=…&token=…     受け取った → 「3_渡し済み」へ
//   ?action=skip&id=…&token=…     渡さない（かんたん設定で「渡さない」を選んだとき）→ 「4_渡さなかった分」へ
//
// ■ 見張り: saveSaneiCsv（5分おき）が watchPickup_ も動かす。「2_勘太郎用」に30分以上残っている
//   CSVがあれば「勘太郎のパソコンが受け取っていません」とメールで1回知らせる（受け取られたら「元にもどりました」）

const PICKUP_ALERT_MINUTES = 30;

function doGet(e) {
  const p = (e && e.parameter) || {};
  const props = PropertiesService.getScriptProperties();
  const token = props.getProperty('AGENT_TOKEN');
  if (!token || String(p.token || '') !== token) return agentJson_({ ok: false, error: '合言葉が違います' });
  try {
    props.setProperty('AGENT_LAST_SEEN', String(Date.now()));
    const root = childFolder_(DriveApp.getRootFolder(), PARENT_NAME);
    const out = childFolder_(root, '2_勘太郎用');
    const action = String(p.action || 'list');
    if (action === 'ping') return agentJson_({ ok: true, account: Session.getEffectiveUser().getEmail() });
    if (action === 'list') {
      return agentJson_({ ok: true, files: agentFiles_(out).map(f => ({ id: f.getId(), name: f.getName(), size: f.getSize() })) });
    }
    const file = agentFile_(out, p.id);
    if (action === 'file') {
      if (!file) return agentJson_({ ok: false, error: 'このファイルは渡せません（もう渡したか、ありません）: ' + p.id });
      const bytes = file.getBlob().getBytes();
      return agentJson_({ ok: true, name: file.getName(), size: bytes.length, data: Utilities.base64Encode(bytes) });
    }
    if (action === 'done' || action === 'skip') {
      if (file) {
        file.moveTo(childFolder_(root, action === 'done' ? '3_渡し済み' : '4_渡さなかった分'));
        try {
          openLog_(root).appendRow([now_(), '', '', '', '', file.getName(),
            action === 'done' ? '勘太郎のパソコンが受け取りました' : '勘太郎へ渡さずによけました（かんたん設定で「渡さない」）']);
        } catch (err) { /* 記録できなくても、受け取りは止めない */ }
      }
      return agentJson_({ ok: true });   // もう移したものでも ok（同じ知らせが2回来ても大丈夫）
    }
    return agentJson_({ ok: false, error: '知らない action です: ' + action });
  } catch (err) {
    return agentJson_({ ok: false, error: String((err && err.message) || err) });
  }
}

// はじめに1回: 合言葉を作る（もうあれば、それを出すだけ）。作り直すときは、スクリプト プロパティの AGENT_TOKEN を消してから実行
function makeAgentToken() {
  const props = PropertiesService.getScriptProperties();
  let token = props.getProperty('AGENT_TOKEN');
  if (!token) {
    token = (Utilities.getUuid() + Utilities.getUuid()).replace(/-/g, '');
    props.setProperty('AGENT_TOKEN', token);
    console.log('合言葉を作りました。');
  }
  console.log('合言葉（勘太郎のパソコンのかんたん設定で貼る）: ' + token);
  return token;
}

function agentJson_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

// 「2_勘太郎用」の勘太郎CSV（ゴミ箱の中は除く）。古い順
function agentFiles_(out) {
  const list = [];
  const it = out.getFiles();
  while (it.hasNext()) {
    const f = it.next();
    if (!f.isTrashed() && /\.csv$/i.test(f.getName())) list.push(f);
  }
  return list.sort((a, b) => (a.getDateCreated() - b.getDateCreated()) || (a.getName() < b.getName() ? -1 : 1));
}

// id のファイルが「2_勘太郎用」にあれば返す（ほかの場所のファイルは渡さない）
function agentFile_(out, id) {
  if (!id) return null;
  let f;
  try { f = DriveApp.getFileById(String(id)); } catch (err) { return null; }
  if (f.isTrashed()) return null;
  const parents = f.getParents();
  while (parents.hasNext()) {
    if (parents.next().getId() === out.getId()) return f;
  }
  return null;
}

// 見張り（saveSaneiCsv から）。合言葉を作ったあと（受け取り係を使い始めてから）だけ見る
function watchPickup_(root, s) {
  const props = PropertiesService.getScriptProperties();
  if (!props.getProperty('AGENT_TOKEN')) return;
  const limit = Date.now() - PICKUP_ALERT_MINUTES * 60 * 1000;
  const waiting = agentFiles_(childFolder_(root, '2_勘太郎用')).filter(f => f.getDateCreated().getTime() <= limit);
  const alerted = props.getProperty('PICKUP_ALERTED') === '1';
  const last = Number(props.getProperty('AGENT_LAST_SEEN') || 0);
  const lastText = last ? Utilities.formatDate(new Date(last), 'Asia/Tokyo', 'yyyy/MM/dd HH:mm') : 'まだ一度も来ていません';
  if (waiting.length && !alerted) {
    const body = ['「2_勘太郎用」に、' + PICKUP_ALERT_MINUTES + '分以上たっても勘太郎のパソコンが受け取っていないCSVがあります。',
      '勘太郎のパソコンの電源・ネットワークと、タスクスケジューラの「kantaro-gas-agent」を確かめてください。',
      '勘太郎のパソコンが最後に取りに来た時刻: ' + lastText, '']
      .concat(waiting.map(f => '・' + f.getName()), ['', 'フォルダ: ' + root.getUrl()]);
    MailApp.sendEmail(notifyTo_(s), '【三映CSV】勘太郎のパソコンが受け取っていません ' + waiting.length + '件', body.join('\n'));
    props.setProperty('PICKUP_ALERTED', '1');
  } else if (!waiting.length && alerted) {
    MailApp.sendEmail(notifyTo_(s), '【三映CSV】勘太郎のパソコンの受け取りが元にもどりました',
      '「2_勘太郎用」に残っていたCSVを、勘太郎のパソコンが受け取りました。\n最後に取りに来た時刻: ' + lastText);
    props.deleteProperty('PICKUP_ALERTED');
  }
}
