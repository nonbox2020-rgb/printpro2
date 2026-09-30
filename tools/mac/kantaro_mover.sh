#!/bin/bash
# 勘太郎の移し係（Mac）
# パソコン版Googleドライブの「三映CSV連携/2_勘太郎用」にある勘太郎CSVを、
# 勘太郎のパソコンの共有フォルダ（例 smb://kantaro-share@192.168.0.223/csv）へ移す。
# launchd などで5分おきに動かす想定（入れ方・止め方を案内する setup はまだ無い。いまは Windows 版 tools/windows を使う）。
#
#   bash kantaro_mover.sh            いま1回動かす
#   bash kantaro_mover.sh --check    何も移さずに、見つけた場所・書き込めるか・渡すファイルを出す
#
# 渡し方:
#   - 共有フォルダへ「.名前.tmp」でコピー → 大きさを確かめる → 本当の名前に変える
#     （勘太郎が書きかけのファイルを読まないように）。同じ名前があれば _2、_3 … を付ける
#   - 渡し終えたファイルは、ドライブの「3_渡し済み」へ移す（記録として残り、二度渡さない）
#   - 共有フォルダにつながらないときは何も動かさず、次の回にやり直す（通知は1回だけ）
# 記録: このファイルと同じフォルダの mover.log

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HERE/mover.log"
STATE="$HERE/.state"
LOCK="$HERE/.lock"

# 設定（同じフォルダの config.sh で上書きする）
SHARE_URL='smb://kantaro-share@192.168.0.223/csv'
PARENT_NAME='三映CSV連携'
OUT_NAME='2_勘太郎用'
DONE_NAME='3_渡し済み'
SRC_DIR=''   # 空なら自動で探す
# shellcheck source=/dev/null
[ -f "$HERE/config.sh" ] && . "$HERE/config.sh"

MODE='run'
[ "${1:-}" = '--check' ] && MODE='check'

CP_OPTS=''
[ "$(uname)" = 'Darwin' ] && CP_OPTS='-X'   # Mac の拡張属性（._ で始まるファイル）を持ちこまない

say() { [ -t 1 ] || [ "$MODE" = 'check' ] && printf '%s\n' "$*"; return 0; }
log() {
  [ "$MODE" = 'check' ] || printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
  say "$*"
}
notify() {
  local msg
  # shellcheck disable=SC1003
  msg=$(printf '%s' "$1" | tr -d '"\\')
  osascript -e "display notification \"$msg\" with title \"勘太郎の移し係\"" >/dev/null 2>&1 || true
}
# うまくいかない: 記録して、続けて失敗している間は1回だけ通知する
fail() {
  log "エラー: $1"
  if [ "$MODE" = 'run' ] && [ "$(cat "$STATE" 2>/dev/null)" != 'ng' ]; then
    notify "$1"
    echo ng > "$STATE"
  fi
  exit 1
}
recovered() {
  [ "$MODE" = 'run' ] || return 0
  if [ "$(cat "$STATE" 2>/dev/null)" = 'ng' ]; then
    log '元にもどりました'
    notify '元にもどりました'
  fi
  echo ok > "$STATE"
}

size_of() { wc -c < "$1" | tr -d ' '; }

# 同じ名前があれば _2、_3 … を付けた、空いている名前
unique_name() {
  local dir=$1 name=$2 stem ext cand n
  case "$name" in
    ?*.*) stem=${name%.*} ext=".${name##*.}" ;;
    *) stem=$name ext='' ;;
  esac
  cand=$name
  n=2
  while [ -e "$dir/$cand" ] || [ -e "$dir/.$cand.tmp" ]; do
    cand="${stem}_$n$ext"
    n=$((n + 1))
  done
  printf '%s\n' "$cand"
}

# Googleドライブの「三映CSV連携/2_勘太郎用」
find_src() {
  local d
  if [ -n "$SRC_DIR" ]; then
    [ -d "$SRC_DIR" ] && printf '%s\n' "$SRC_DIR" && return 0
    return 1
  fi
  for d in "$HOME"/Library/CloudStorage/GoogleDrive-*/*/"$PARENT_NAME"/"$OUT_NAME" \
           /Volumes/GoogleDrive*/*/"$PARENT_NAME"/"$OUT_NAME" \
           "$HOME"/Google\ Drive*/*/"$PARENT_NAME"/"$OUT_NAME" \
           "$HOME"/*/"$PARENT_NAME"/"$OUT_NAME"; do
    [ -d "$d" ] && printf '%s\n' "$d" && return 0
  done
  return 1
}

# 共有フォルダが Mac のどこに開いているか（開いていなければ空）
share_host() { local u=${SHARE_URL#smb://}; u=${u%%/*}; printf '%s\n' "${u##*@}"; }
share_name() { local u=${SHARE_URL#smb://}; u=${u#*/}; printf '%s\n' "${u%/}"; }
mount_point() {
  local host share
  host=$(share_host)
  share=$(share_name)
  mount | grep -i -F -e "@$host/$share on " -e "//$host/$share on " | head -n 1 |
    sed -E 's/^.* on (.*) \(smbfs.*$/\1/'
}
# キーチェーンに保存したパスワードで開く（60秒で見切る）
mount_share() {
  local pid i
  osascript -e "mount volume \"$SHARE_URL\"" >/dev/null 2>&1 &
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 60 ]; do
    sleep 1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 0
}

# 1つのファイルを渡す: $1=ドライブのファイル $2=共有フォルダ
deliver() {
  local f=$1 mp=$2 name target tmp err
  name=$(basename "$f")
  target=$(unique_name "$mp" "$name")
  tmp="$mp/.$target.tmp"
  # shellcheck disable=SC2086
  if ! err=$(cp $CP_OPTS "$f" "$tmp" 2>&1); then
    rm -f "$tmp"
    log "エラー: $name を共有フォルダへコピーできませんでした（次の回にやり直します）: $err"
    case "$err" in
      *'not permitted'*) log 'Mac の許可が足りません。システム設定 → プライバシーとセキュリティ → ファイルとフォルダ で、bash の「ネットワークボリューム」を許可してください' ;;
    esac
    return 1
  fi
  if [ "$(size_of "$f")" != "$(size_of "$tmp")" ]; then
    rm -f "$tmp"
    log "エラー: $name のコピーが途中で切れました（次の回にやり直します）"
    return 1
  fi
  if ! mv "$tmp" "$mp/$target" 2>>"$LOG"; then
    rm -f "$tmp"
    log "エラー: $name の名前を変えられませんでした（次の回にやり直します）"
    return 1
  fi
  mkdir -p "$DONE_DIR"
  if ! mv "$f" "$DONE_DIR/$(unique_name "$DONE_DIR" "$name")" 2>>"$LOG"; then
    log "注意: $name は渡しましたが「$DONE_NAME」へ移せませんでした。二度渡さないよう、ドライブで手で移してください"
    notify "$name を「$DONE_NAME」へ移せませんでした。手で移してください"
  fi
  log "渡しました: $name → $target"
  return 0
}

# ---------------- ここから ----------------

# 前の回がまだ動いていれば何もしない（30分以上残った目印は、止まった回の残りとして消す）
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rm -rf "$LOCK"' EXIT

if [ -f "$LOG" ] && [ "$(size_of "$LOG")" -gt 1000000 ]; then mv -f "$LOG" "$LOG.1"; fi

if [ -d "$HOME/Library/CloudStorage" ] && ! ls "$HOME/Library/CloudStorage" >/dev/null 2>&1; then
  fail 'Mac の許可が足りません。システム設定 → プライバシーとセキュリティ で bash にファイルへのアクセスを許可してください'
fi
SRC=$(find_src) ||
  fail "Googleドライブの「$PARENT_NAME/$OUT_NAME」が見つかりません。パソコン版Googleドライブが動いているか確かめてください"
DONE_DIR="$(dirname "$SRC")/$DONE_NAME"

FILES=()
NFILES=0
for f in "$SRC"/*.csv "$SRC"/*.CSV; do
  [ -f "$f" ] || continue
  FILES+=("$f")
  NFILES=$((NFILES + 1))
done

if [ "$MODE" = 'check' ]; then
  say "Googleドライブ: $SRC"
  MP=$(mount_point)
  [ -n "$MP" ] || { mount_share; MP=$(mount_point); }
  if [ -z "$MP" ]; then
    say "共有フォルダ: つながりません（$SHARE_URL）"
  elif mkdir "$MP/.kantaro-mover-test.tmp" 2>/dev/null && rmdir "$MP/.kantaro-mover-test.tmp"; then
    say "共有フォルダ: $MP（書き込めます）"
  else
    say "共有フォルダ: $MP（書き込めません。共有とセキュリティの「変更」の許可を確かめてください）"
  fi
  say "渡すファイル: $NFILES 件"
  for f in ${FILES[@]+"${FILES[@]}"}; do say "  - $(basename "$f")"; done
  exit 0
fi

# 渡すものが無ければ、共有フォルダには触らない
if [ "$NFILES" -eq 0 ]; then
  recovered
  exit 0
fi

MP=$(mount_point)
if [ -z "$MP" ]; then
  mount_share
  MP=$(mount_point)
fi
[ -n "$MP" ] ||
  fail "勘太郎の共有フォルダ（$SHARE_URL）につながりません。勘太郎のパソコンの電源とネットワークを確かめてください。ファイルはドライブに残し、次の回に渡します"

errors=0
for f in "${FILES[@]}"; do
  deliver "$f" "$MP" || errors=$((errors + 1))
done
[ "$errors" -eq 0 ] || fail "$errors 件を渡せませんでした（ドライブに残し、次の回にやり直します）"
recovered
exit 0
