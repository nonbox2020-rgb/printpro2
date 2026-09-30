# 勘太郎のパソコンの受け取り係（GAS 版） かんたん設定
#
# 使い方: 同じフォルダの setup_kantaro_gas_agent.bat をダブルクリックする（管理者の許可を求めます）。
# 聞くのは3つ: GAS の受け取り口の URL（…/exec）・合言葉（GAS の makeAgentToken で出たもの）・勘太郎の csv フォルダ。
# してくれること:
#   1. GAS の受け取り口につながるか確かめる（まだ渡していないCSVがあれば一覧を見せて、渡すか・よけるかを聞く）
#   2. C:\kantaro-gas-agent に受け取り係（kantaro_gas_agent.ps1）と設定を置く（管理者と SYSTEM だけが読める）
#   3. タスクスケジューラに「kantaro-gas-agent」を登録する
#      （パソコンが動いている間、起動したときと5分おき。SYSTEM として動くので、画面は出ず、だれもログオンしていなくても動く）
#   4. 1回動かして、うまくいったか確かめる
# もう一度実行すると、URL・合言葉・フォルダを変えられる（テスト用のフォルダから本番の csv フォルダへ、など）。
# やめるとき: タスクスケジューラで「kantaro-gas-agent」を削除し、C:\kantaro-gas-agent フォルダを削除する。
#
# このファイルは UTF-8（BOM付き）で保存すること（Windows PowerShell 4.0 / 5.1 が日本語を正しく読むため）。

param([switch]$LoadOnly)   # テスト用: 関数を読み込むだけで、設定は始めない

$SetupLoadOnly = [bool]$LoadOnly   # 下で受け取り係を読み込むと $LoadOnly が上書きされるので、先に控える
$ErrorActionPreference = 'Stop'
$TaskName = 'kantaro-gas-agent'
$InstallDir = 'C:\kantaro-gas-agent'
$DefaultDest = 'C:\Program Files\FileMaker\FileMaker Server\Data\Documents\csv'
$AgentSource = Join-Path $PSScriptRoot 'kantaro_gas_agent.ps1'
if (Test-Path -LiteralPath $AgentSource) {
    . $AgentSource -LoadOnly   # 受け取り係と同じ聞き方（Invoke-GasAgent）で確かめる
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 貼り付けた URL を、受け取り口の URL（https://script.google.com/macros/s/…/exec）にそろえる。読めなければ $null
function ConvertTo-GasUrl([string]$text) {
    $t = $text.Trim().Trim('"').Trim()
    $t = ($t -split '[?#]')[0]
    # Google Workspace の URL（/a/macros/会社のドメイン/s/…）は、だれでも使える形（/macros/s/…）に直す
    $t = $t -replace '^https://script\.google\.com/a/macros/[^/]+/s/', 'https://script.google.com/macros/s/'
    if ($t -match '^https://script\.google\.com/macros/s/[A-Za-z0-9_-]+/exec$') { return $t }
    if ($t -match '^http://127\.0\.0\.1:\d+/macros/s/[A-Za-z0-9_-]+/exec$') { return $t }   # テスト用
    return $null
}

function Read-GasUrl([string]$current) {
    while ($true) {
        if ($current) {
            $in = [string](Read-Host "① GAS の受け取り口の URL（Enter で前回と同じ）")
            if ($in.Trim() -eq '') { return $current }
        } else {
            $in = [string](Read-Host '① GAS の受け取り口の URL（https://script.google.com/macros/s/…/exec）を貼り付けて Enter')
        }
        $u = ConvertTo-GasUrl $in
        if ($u) { return $u }
        Write-Host 'URL として読めません。GAS の「デプロイ」で出た「ウェブアプリ」の URL（/exec で終わる）を貼り付けてください。' -ForegroundColor Yellow
    }
}

# 合言葉。実行ログの行ごと貼り付けても、合言葉の部分だけを取り出す
function Read-GasToken([string]$current) {
    while ($true) {
        if ($current) {
            $in = [string](Read-Host '② 合言葉（Enter で前回と同じ）')
            if ($in.Trim() -eq '') { return $current }
        } else {
            $in = [string](Read-Host '② 合言葉（GAS で makeAgentToken を実行して出たもの）を貼り付けて Enter')
        }
        $m = [regex]::Match($in, '[0-9A-Fa-f]{32,}')
        if ($m.Success) { return $m.Value }
        if ($in.Trim() -ne '') { return $in.Trim() }
    }
}

# つながるか。@{ Ok; Reason }
function Test-GasConnection([string]$url, [string]$token) {
    try {
        Invoke-GasAgent $url $token @{ action = 'ping' } | Out-Null
        return @{ Ok = $true }
    } catch {
        $message = $_.Exception.Message
        if ($message -match '合言葉') {
            $why = '合言葉が違います。GAS で makeAgentToken を実行し、実行ログに出た合言葉を貼り付けてください。'
        } elseif ($message -match 'JSON ではない') {
            $why = $message
        } else {
            $why = "GAS につながりません。インターネットと URL を確かめてください（$message）"
        }
        return @{ Ok = $false; Reason = $why }
    }
}

# 勘太郎の csv フォルダを選ぶ窓。使えないとき・やめたときは $null
function Select-FolderDialog {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '勘太郎の csv フォルダ（CSV を入れるフォルダ）を選んでください'
        $dlg.ShowNewFolderButton = $true
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true   # 窓がこの黒い画面の後ろに隠れないように
        try {
            if ([string]$dlg.ShowDialog($owner) -eq 'OK') { return $dlg.SelectedPath }
        } finally { $owner.Dispose() }
    } catch { }
    return $null
}

# 受け取り係は SYSTEM として動くため、ネットワーク上のフォルダ（\\サーバー、割り当てたドライブ）には入れられない
function Test-LocalFolder([string]$path) {
    if ($path.StartsWith('\\')) { return $false }
    $root = [IO.Path]::GetPathRoot($path)
    if (-not $root) { return $false }
    if ($root -eq '/') { return $true }   # テスト用（Linux）
    return (New-Object IO.DriveInfo $root).DriveType -ne [IO.DriveType]::Network
}

function Read-DestFolder([string]$current) {
    if (-not $current -and (Test-Path -LiteralPath $DefaultDest -PathType Container)) { $current = $DefaultDest }
    while ($true) {
        $path = $null
        if ($current) {
            $in = ([string](Read-Host "③ 勘太郎の csv フォルダ（Enter で $current ／ほかのフォルダは場所を入力 ／C で選ぶ窓 ／Q で中止）")).Trim().Trim('"')
            if ($in -eq '') { $path = $current }
            elseif ($in -match '^(q|ｑ)$') { return $null }
            elseif ($in -notmatch '^(c|ｃ)$') { $path = $in }
        } else {
            $in = ([string](Read-Host '③ 勘太郎の csv フォルダの場所を入力（C で選ぶ窓 ／Q で中止）')).Trim().Trim('"')
            if ($in -match '^(q|ｑ)$') { return $null }
            if ($in -ne '' -and $in -notmatch '^(c|ｃ)$') { $path = $in }
        }
        if (-not $path) {
            Write-Host '別の窓が開きます。フォルダを選んで「OK」を押してください。'
            $path = Select-FolderDialog
            if (-not $path) { continue }
        }
        if (-not (Test-LocalFolder $path)) {
            Write-Host 'ネットワーク上のフォルダ（\\パソコン名 や Z: など）は使えません。このパソコンの中のフォルダを選んでください。' -ForegroundColor Yellow
            $current = $null
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            $ans = [string](Read-Host "$path はまだありません。作りますか？（テスト用のフォルダなど）Y/N")
            if ($ans -notmatch '^\s*(y|ｙ)') { $current = $null; continue }
            [IO.Directory]::CreateDirectory($path) | Out-Null
        }
        return (Resolve-Path -LiteralPath $path).ProviderPath
    }
}

# まだ渡していないCSVを見せて、渡すか（Y）・よけるか（N）を聞く。やめるなら $false
function Resolve-PendingFiles([string]$url, [string]$token, [string]$dest) {
    $files = @((Invoke-GasAgent $url $token @{ action = 'list' }).files)
    if ($files.Count -eq 0) { return $true }
    Write-Host ''
    Write-Host "GAS に、まだ勘太郎へ渡していないCSVが $($files.Count) 件あります（研修のダミーデータなども含みます）:" -ForegroundColor Yellow
    $files | Select-Object -First 15 | ForEach-Object { Write-Host "    $($_.name)" }
    if ($files.Count -gt 15) { Write-Host "    ほか $($files.Count - 15) 件" }
    Write-Host "    Y = 渡す（設定が終わると、すぐ $dest に届きます）"
    Write-Host '    N = 渡さない（Googleドライブの「4_渡さなかった分」へよけます）'
    Write-Host '    Q = 中止'
    while ($true) {
        $ans = ([string](Read-Host 'Y / N / Q（Enter で N）')).Trim()
        if ($ans -match '^(q|ｑ)') { return $false }
        if ($ans -match '^(y|ｙ)') { Write-Host '   → 渡します'; return $true }
        if ($ans -eq '' -or $ans -match '^(n|ｎ)') { break }
    }
    foreach ($f in $files) { Invoke-GasAgent $url $token @{ action = 'skip'; id = [string]$f.id } | Out-Null }
    Write-Host "   → $($files.Count) 件を「4_渡さなかった分」へよけました（勘太郎へは渡しません）"
    return $true
}

function Read-AgentConfig([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $null }
}

function Write-AgentConfig([string]$path, [string]$url, [string]$token, [string]$dest) {
    $json = New-Object PSObject -Property ([ordered]@{ url = $url; token = $token; dest_folder = $dest }) | ConvertTo-Json
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
}

# 受け取り係を置く。メモ帳などで BOM が消えていても、BOM付きで置き直す
function Install-AgentScript([string]$src, [string]$dst) {
    $code = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
    if ($code -notmatch 'Receive-AgentFile') { throw "kantaro_gas_agent.ps1 の中身が受け取り係ではありません: $src" }
    [IO.File]::WriteAllText($dst, $code, (New-Object Text.UTF8Encoding($true)))
}

# 設定に合言葉が入るので、管理者と SYSTEM だけが読み書きできるようにする
function Protect-InstallDir([string]$dir) {
    $ErrorActionPreference = 'Continue'   # icacls の表示では止めない（うまくいったかは終了コードで見る）
    $out = & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$dir の権限を設定できませんでした: $out" }
}

# タスクスケジューラの登録内容。起動時と、登録した時刻から5分おき（再起動しても続く）。SYSTEM として動く
function New-AgentTaskXml([string]$agentPath, [string]$workDir, [datetime]$start) {
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $agentPath + '"'
    $cmd = [Security.SecurityElement]::Escape($ps)
    $arg = [Security.SecurityElement]::Escape($arguments)
    $dir = [Security.SecurityElement]::Escape($workDir)
    $when = $start.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>TBM Co., Ltd.</Author>
    <Description>GAS（Googleドライブ「2_勘太郎用」）の勘太郎CSVを受け取り、勘太郎の csv フォルダへ入れる（5分おき）。設定: $dir</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Repetition>
        <Interval>PT5M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
    </BootTrigger>
    <TimeTrigger>
      <Repetition>
        <Interval>PT5M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$when</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$cmd</Command>
      <Arguments>$arg</Arguments>
      <WorkingDirectory>$dir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Register-AgentTask([string]$taskName, [string]$xml) {
    try {
        Register-ScheduledTask -TaskName $taskName -Xml $xml -User 'SYSTEM' -Force | Out-Null
    } catch {
        $first = $_.Exception.Message
        $ErrorActionPreference = 'Continue'
        $tmp = Join-Path $env:TEMP 'kantaro-gas-agent-task.xml'
        [IO.File]::WriteAllText($tmp, $xml, [Text.Encoding]::Unicode)   # schtasks は UTF-16 の XML を読む
        $out = & schtasks.exe /Create /TN $taskName /XML $tmp /RU SYSTEM /F 2>&1
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) { throw "タスクスケジューラに登録できませんでした: $first / $out" }
    }
}

# 登録したタスクを1回動かし、終わるまで待つ。戻り値は終了コード（0 = 成功）。時間内に終わらなければ $null
function Invoke-AgentOnce([string]$taskName) {
    $startedAt = (Get-Date).AddSeconds(-5)
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 3
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
        $state = [string](Get-ScheduledTask -TaskName $taskName).State
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        # 今回の1回が終わったものだけを見る（267009 = 実行中、267011 = まだ一度も動いていない）
        if ($state -ne 'Running' -and $info.LastRunTime -ge $startedAt -and
            $info.LastTaskResult -ne 267009 -and $info.LastTaskResult -ne 267011) { return [int]$info.LastTaskResult }
        Start-Sleep -Seconds 2
    }
    return $null
}

function Show-LogTail([string]$logPath) {
    if (Test-Path -LiteralPath $logPath) {
        Write-Host '記録の最後の行:'
        Get-Content -LiteralPath $logPath -Encoding UTF8 -Tail 8 | ForEach-Object { Write-Host "    $_" }
    }
}

function Invoke-Setup {
    Write-Host ''
    Write-Host '=== 勘太郎のパソコンの受け取り係（GAS 版） かんたん設定 ===' -ForegroundColor Cyan
    Write-Host 'GAS が変換した勘太郎CSVを、このパソコンが5分おきに受け取り、勘太郎の csv フォルダへ入れるようにします。'
    Write-Host ''
    if (-not (Test-Path -LiteralPath $AgentSource)) {
        throw 'このファイルと同じフォルダに kantaro_gas_agent.ps1 がありません。3つのファイルを同じフォルダに入れてください。'
    }
    $cfgPath = Join-Path $InstallDir 'kantaro_gas_agent.config.json'
    $agentPath = Join-Path $InstallDir 'kantaro_gas_agent.ps1'
    $logPath = Join-Path $InstallDir 'kantaro_gas_agent.log'

    $url = $null; $token = $null; $dest = $null
    $old = Read-AgentConfig $cfgPath
    if ($old) {
        $url = [string]$old.url; $token = [string]$old.token; $dest = [string]$old.dest_folder
        Write-Host '前回の設定が見つかりました。変えない項目は、そのまま Enter を押してください。'
    }

    # ① ② URL と合言葉。つながるまで繰り返す
    while ($true) {
        $url = Read-GasUrl $url
        $token = Read-GasToken $token
        Write-Host 'GAS につないでいます…'
        $conn = Test-GasConnection $url $token
        if ($conn.Ok) { Write-Host 'つながりました。' -ForegroundColor Green; break }
        Write-Host $conn.Reason -ForegroundColor Yellow
        $ans = [string](Read-Host 'Enter でもう一度（URL・合言葉を入れ直せます）／Q で中止')
        if ($ans -match '^\s*(q|ｑ)') { Write-Host '中止しました。このパソコンの設定は何も変えていません。'; return }
        $url = $null; $token = $null
    }

    # ③ 勘太郎の csv フォルダ
    $dest = Read-DestFolder $dest
    if (-not $dest) { Write-Host '中止しました。このパソコンの設定は何も変えていません。'; return }

    # まだ渡していないCSV（研修のダミーデータなど）を、渡すか・よけるか
    if (-not (Resolve-PendingFiles $url $token $dest)) { Write-Host '中止しました。このパソコンの設定は何も変えていません。'; return }

    # 置く・登録する
    [IO.Directory]::CreateDirectory($InstallDir) | Out-Null
    Protect-InstallDir $InstallDir
    Install-AgentScript $AgentSource $agentPath
    Write-AgentConfig $cfgPath $url $token $dest
    $xml = New-AgentTaskXml $agentPath $InstallDir (Get-Date)
    Register-AgentTask $TaskName $xml
    Write-Host "タスクスケジューラに「$TaskName」を登録しました（起動したときと5分おき）。"

    # 1回動かして確かめる
    Write-Host '試しに1回動かしています…'
    $result = Invoke-AgentOnce $TaskName
    Write-Host ''
    if ($result -eq 0) {
        Write-Host '設定が終わりました。' -ForegroundColor Green
        Write-Host "  受け取り係の場所: $InstallDir"
        Write-Host "  勘太郎の csv フォルダ: $dest"
        Write-Host "  記録（受け取ったファイルとエラー）: $logPath"
        Write-Host '  このパソコンが動いている間、5分おきに GAS へ取りに行きます（だれもログオンしていなくても動きます）。'
        Write-Host '  設定に使った3つのファイルは、消してかまいません。'
    } elseif ($null -eq $result) {
        Write-Host '登録はできましたが、試しの1回がまだ終わっていません。数分後に記録を見てください。' -ForegroundColor Yellow
        Show-LogTail $logPath
    } else {
        Write-Host "登録はできましたが、試しの1回がうまくいきませんでした（終了コード $result）。" -ForegroundColor Red
        Show-LogTail $logPath
        Write-Host 'この画面の写真を撮って TBM に送ってください。'
    }
}

if ($SetupLoadOnly) { return }

try { $Host.UI.RawUI.WindowTitle = '受け取り係（GAS 版）のかんたん設定' } catch { }
if (-not (Test-Admin)) {
    # 管理者として開き直す（「このアプリがデバイスに変更を加えることを許可しますか？」→「はい」）
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
    } catch {
        Write-Host '管理者の許可が得られませんでした。もう一度実行して「はい」を押してください。' -ForegroundColor Red
        Read-Host 'Enter で閉じます' | Out-Null
    }
    return
}
try {
    Invoke-Setup
} catch {
    Write-Host ''
    Write-Host ('うまくいきませんでした: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'この画面の写真を撮って TBM に送ってください。'
}
Read-Host 'Enter で閉じます' | Out-Null
