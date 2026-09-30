// 三映CSVを Gmail から Googleドライブの「連携用フォルダ」へ保存する
const FOLDER_NAME = '連携用フォルダ';   // 保存先のフォルダ名
const LABEL_NAME = 'sanei-saved';       // 保存したメールに付ける目印
const SEARCH = 'has:attachment filename:csv newer_than:7d';

function saveSaneiCsv() {
  const folder = getFolder_();
  const label = GmailApp.getUserLabelByName(LABEL_NAME) || GmailApp.createLabel(LABEL_NAME);
  const props = PropertiesService.getScriptProperties();
  const done = JSON.parse(props.getProperty('done') || '[]');   // 保存し終わったメールのID
  GmailApp.search(SEARCH, 0, 50).forEach(thread => {
    thread.getMessages().forEach(msg => {
      if (done.includes(msg.getId())) return;               // 保存済みのメールはとばす
      msg.getAttachments().forEach(att => {
        if (!/\.csv$/i.test(att.getName())) return;         // CSV だけ
        const time = Utilities.formatDate(msg.getDate(), 'Asia/Tokyo', 'yyyyMMdd_HHmm_');
        folder.createFile(att.copyBlob().setName(time + att.getName()));
        console.log('保存しました: ' + time + att.getName());
      });
      done.push(msg.getId());
    });
    thread.addLabel(label);
  });
  props.setProperty('done', JSON.stringify(done.slice(-300)));  // 最近の300通だけ覚える
}

function getFolder_() {
  const found = DriveApp.getFoldersByName(FOLDER_NAME);
  return found.hasNext() ? found.next() : DriveApp.createFolder(FOLDER_NAME);
}
