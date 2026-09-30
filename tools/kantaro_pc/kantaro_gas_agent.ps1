# 勘太郎のパソコンの受け取り係（GAS 版）
#
# GAS の受け取り口（gas/step2_convert/4_webapp.gs のウェブアプリ）から、Googleドライブ「2_勘太郎用」に入った
# 勘太郎CSVを受け取り、勘太郎の csv フォルダへ入れる。入れたら GAS に知らせる → GAS が「3_渡し済み」へ移す。
# タスクスケジューラで、起動したときと5分おきに SYSTEM として動く（入れ方は setup_kantaro_gas_agent.bat）。
#
# 入れ方:
#   - 書きかけを勘太郎に読ませないよう「.名前.tmp」で書いてから、本当の名前に変える
#   - 同じ名前のファイルがまだ残っていたら上書きせず、_2、_3 … を付ける
#   - 入れたファイルは控え（kantaro_gas_agent.delivered.txt）に書く。GAS への知らせが届かなくても、次の回は知らせ直すだけで、二重には入れない
#   - つながらない・合言葉が違うときは何も動かさず、記録に「エラー: …」を残して、次の回にやり直す
#
# 設定: 同じフォルダの kantaro_gas_agent.config.json（url = ウェブアプリの URL、token = 合言葉、dest_folder = 勘太郎の csv フォルダ）
# 記録: 同じフォルダの kantaro_gas_agent.log
# このファイルは UTF-8（BOM付き）で保存すること（Windows PowerShell 4.0 / 5.1 が日本語を正しく読むため）。

param([switch]$LoadOnly)   # LoadOnly: 関数を読み込むだけ（かんたん設定とテストが使う）

$ErrorActionPreference = 'Stop'
$AgentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentLog = Join-Path $AgentDir 'kantaro_gas_agent.log'
$AgentLedger = Join-Path $AgentDir 'kantaro_gas_agent.delivered.txt'
$AgentConfigPath = Join-Path $AgentDir 'kantaro_gas_agent.config.json'

function Write-AgentLog([string]$message) {
    $line = (Get-Date).ToString('yyyy/MM/dd HH:mm:ss') + ' ' + $message
    try { [IO.File]::AppendAllText($AgentLog, $line + "`r`n", (New-Object Text.UTF8Encoding($true))) } catch { }
}

# GAS の受け取り口に聞く。答えは JSON。ok でなければ止める（Google はいったん別のアドレスへ回すが、そのままついて行く）
function Invoke-GasAgent([string]$url, [string]$token, [hashtable]$query) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $pairs = @('token=' + [Uri]::EscapeDataString($token))
    foreach ($key in $query.Keys) { $pairs += ([string]$key + '=' + [Uri]::EscapeDataString([string]$query[$key])) }
    $sep = '?'
    if ($url.Contains('?')) { $sep = '&' }
    $res = Invoke-WebRequest -Uri ($url + $sep + ($pairs -join '&')) -UseBasicParsing -TimeoutSec 120
    $text = [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray())
    if ($text.TrimStart().StartsWith('<')) {
        throw 'GAS の受け取り口から、JSON ではない答え（ログインの画面など）が返りました。ウェブアプリの「アクセスできるユーザー」が「全員」か、URL が「/exec」で終わっているかを確かめてください'
    }
    $obj = $text | ConvertFrom-Json
    if (-not $obj.ok) { throw ('GAS の受け取り口: ' + $obj.error) }
    return $obj
}

# 同じ名前があれば _2、_3 … を付けた、空いている名前
function Get-AgentUniqueName([string]$dir, [string]$name) {
    $ext = [IO.Path]::GetExtension($name)
    $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    $candidate = $name
    $n = 2
    while ((Test-Path -LiteralPath (Join-Path $dir $candidate)) -or
           (Test-Path -LiteralPath (Join-Path $dir ('.' + $candidate + '.tmp')))) {
        $candidate = $stem + '_' + $n + $ext
        $n++
    }
    return $candidate
}

# 入れ終わったファイルの控え（GAS のファイルの id）。長くなったら新しい2000件だけ残す
function Read-AgentLedger {
    $set = @{}
    if (Test-Path -LiteralPath $AgentLedger) {
        $lines = [IO.File]::ReadAllLines($AgentLedger, [Text.Encoding]::UTF8)
        if ($lines.Count -gt 5000) {
            $lines = $lines[($lines.Count - 2000)..($lines.Count - 1)]
            [IO.File]::WriteAllLines($AgentLedger, $lines, (New-Object Text.UTF8Encoding($false)))
        }
        foreach ($line in $lines) { if ($line) { $set[$line] = $true } }
    }
    return $set
}

function Add-AgentLedger([string]$id) {
    [IO.File]::AppendAllText($AgentLedger, $id + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

# 1つ受け取って、勘太郎のフォルダへ入れる。戻り値は入れた名前
function Receive-AgentFile($cfg, $item, [string]$dest) {
    $one = Invoke-GasAgent $cfg.url $cfg.token @{ action = 'file'; id = [string]$item.id }
    $bytes = [Convert]::FromBase64String([string]$one.data)
    if ($bytes.Length -ne [long]$one.size) {
        throw ('受け取ったファイルの大きさが違います（次の回にもう一度受け取ります）: ' + $item.name)
    }
    $name = [IO.Path]::GetFileName([string]$item.name)
    if (-not $name.ToLower().EndsWith('.csv')) { throw ('CSV ではないファイルは入れません: ' + $item.name) }
    $target = Get-AgentUniqueName $dest $name
    $tmp = Join-Path $dest ('.' + $target + '.tmp')
    try {
        [IO.File]::WriteAllBytes($tmp, $bytes)
        Move-Item -LiteralPath $tmp -Destination (Join-Path $dest $target)
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
    return $target
}

if ($LoadOnly) { return }

# ---------------- ここから ----------------

# 前の回がまだ動いていれば何もしない
$mutex = New-Object System.Threading.Mutex($false, 'Global\kantaro-gas-agent')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    if ((Test-Path -LiteralPath $AgentLog) -and (Get-Item -LiteralPath $AgentLog).Length -gt 1MB) {
        Move-Item -LiteralPath $AgentLog -Destination ($AgentLog + '.1') -Force
    }
    $cfg = [IO.File]::ReadAllText($AgentConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $dest = [string]$cfg.dest_folder
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) { throw "勘太郎のフォルダが見つかりません: $dest" }

    $delivered = Read-AgentLedger
    $list = Invoke-GasAgent $cfg.url $cfg.token @{ action = 'list' }
    foreach ($item in @($list.files)) {
        $id = [string]$item.id
        if (-not $delivered.ContainsKey($id)) {
            $target = Receive-AgentFile $cfg $item $dest
            Add-AgentLedger $id
            $delivered[$id] = $true
            Write-AgentLog ('受け取り: ' + $item.name + ' → ' + $target)
        }
        # GAS に「受け取った」と知らせる（→「3_渡し済み」へ）。届かなければ次の回に知らせ直す（ファイルは二重に入れない）
        Invoke-GasAgent $cfg.url $cfg.token @{ action = 'done'; id = $id } | Out-Null
    }
    exit 0
}
catch {
    Write-AgentLog ('エラー: ' + $_.Exception.Message)
    exit 1
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
