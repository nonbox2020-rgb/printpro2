# 勘太郎パソコンの受け取り係 かんたん設定
#
# 使い方: 同じフォルダの setup_kantaro_agent.bat をダブルクリックする（管理者の許可を求めます）。
# 聞くのは3つだけ: 変換アプリのURL・合言葉（AGENT_TOKEN）・印刷勘太郎の指定フォルダ。
# してくれること:
#   1. 変換アプリにつながるか確かめる（まだ受け取っていないCSVがあれば、一覧を見せて確認する）
#   2. C:\kantaro-agent に受け取り係（kantaro_agent.ps1）と設定ファイルを置く
#   3. タスクスケジューラに「kantaro-agent」を登録する
#      （パソコンが動いている間、5分おき。SYSTEM として動くので、画面は出ず、だれもログオンしていなくても動く）
#   4. 1回動かして、うまくいったか確かめる
# もう一度実行すると、URL・合言葉・フォルダを変えられる（受け取り済みの控えは残るので、二重には届かない）。
# やめるとき: タスクスケジューラで「kantaro-agent」を削除し、C:\kantaro-agent フォルダを削除する。
#
# このファイルは UTF-8（BOM付き）で保存すること（Windows PowerShell 5.1 が日本語を正しく読むため）。

param([switch]$LoadOnly)   # テスト用: 関数を読み込むだけで、設定は始めない

$ErrorActionPreference = 'Stop'
$TaskName = 'kantaro-agent'
$InstallDir = 'C:\kantaro-agent'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 貼り付けたURLを「https://ホスト名」の形にそろえる（/login.html などが付いていても消す）。読めなければ $null
function ConvertTo-AppUrl([string]$text) {
    $t = $text.Trim().Trim('"').Trim()
    if ($t -eq '') { return $null }
    if ($t -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $t = 'https://' + $t }
    $u = $null
    if (-not [Uri]::TryCreate($t, [UriKind]::Absolute, [ref]$u)) { return $null }
    if (($u.Scheme -ne 'https' -and $u.Scheme -ne 'http') -or $u.Host -eq '') { return $null }
    $local = ($u.Host -eq 'localhost') -or ($u.Host -eq '127.0.0.1')
    if ($u.Scheme -eq 'http' -and -not $local -and $u.IsDefaultPort) {
        # Render は https。http のままだと合言葉が暗号化されずに流れるので、https に直す
        $u = New-Object Uri ('https://' + $u.Authority)
    }
    return $u.GetLeftPart([UriPartial]::Authority)
}

# 新しい合言葉（英数字32文字。暗号用の乱数から作る）
function New-AgentToken {
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [Convert]::ToBase64String($bytes).Replace('+', 'x').Replace('/', 'y')
}

# 受け取り係と同じ方法で、変換アプリに未取込の一覧を聞いてみる
function Test-AppConnection([string]$url, [string]$token) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $res = Invoke-WebRequest -Uri "$url/api/agent/files" -Headers @{ Authorization = 'Bearer ' + $token } -UseBasicParsing -TimeoutSec 120
        $list = [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray()) | ConvertFrom-Json
        $files = @()
        if ($list.files) { $files = @($list.files) }
        return @{ Ok = $true; Files = $files }
    }
    catch {
        $message = $_.Exception.Message
        $code = 0
        if ($null -ne $_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 401) {
            $why = '合言葉が違います。Render の AGENT_TOKEN と同じ値か確かめてください。Render で保存した直後なら、入れ替えが終わるまで1〜2分待ってください（AGENT_TOKEN が未設定のときも、この表示になります）'
        } elseif ($code -eq 404) {
            $why = 'このURLに変換アプリ（受け取り係に対応したもの）が見つかりません。ブラウザで変換アプリを開いたときのアドレスか確かめてください'
        } elseif ($code -ne 0) {
            $why = "変換アプリがエラーを返しました（$code）。少し待ってから、もう一度試してください"
        } else {
            $why = "つながりません。URLとインターネットを確かめてください（$message）"
        }
        return @{ Ok = $false; Code = $code; Reason = $why }
    }
}

function Read-AppUrl([string]$current) {
    while ($true) {
        if ($current) {
            $in = [string](Read-Host "① 変換アプリのURL（Enter で $current のまま）")
            if ($in.Trim() -eq '') { return $current }
        } else {
            $in = [string](Read-Host '① 変換アプリのURL（例 https://xxxx.onrender.com）を貼り付けて Enter')
        }
        $u = ConvertTo-AppUrl $in
        if ($u) { return $u }
        Write-Host 'URLとして読めません。ブラウザで変換アプリを開いたときのアドレスを貼り付けてください。' -ForegroundColor Yellow
    }
}

function Read-Token([string]$current) {
    if ($current) {
        $in = [string](Read-Host '② 合言葉 AGENT_TOKEN（Enter で前回と同じ）')
        if ($in.Trim() -eq '') { return $current }
    } else {
        $in = [string](Read-Host '② 合言葉 AGENT_TOKEN を貼り付けて Enter（まだ決めていなければ、何も入れずに Enter）')
    }
    $in = ($in.Trim() -replace '^AGENT_TOKEN\s*=\s*', '').Trim('"').Trim()
    if ($in -ne '') { return $in }

    $token = New-AgentToken
    $copied = $true
    try { Set-Clipboard -Value $token } catch { $copied = $false }
    Write-Host ''
    Write-Host '新しい合言葉を作りました:' -ForegroundColor Cyan
    Write-Host "    $token"
    if ($copied) { Write-Host '（コピー済みです。そのまま貼り付けられます）' }
    Write-Host 'ブラウザで Render を開き、変換アプリの Environment に AGENT_TOKEN を追加して（あれば値を置き換えて）、'
    Write-Host 'この合言葉を貼り付けて保存してください。保存すると、Render が変換アプリを入れ替えます（1〜2分）。'
    Read-Host '終わったら Enter' | Out-Null
    return $token
}

# 指定フォルダを選ぶ窓。使えないとき・やめたときは $null
function Select-FolderDialog {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '印刷勘太郎の指定フォルダ（CSVを入れるフォルダ）を選んでください'
        $dlg.ShowNewFolderButton = $false
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true   # 窓がこの黒い画面の後ろに隠れないように
        try {
            if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
        } finally { $owner.Dispose() }
    } catch { }
    return $null
}

# 受け取り係は SYSTEM として動くため、ネットワーク上のフォルダ（\\サーバー、割り当てたドライブ）には入れられない
function Test-LocalFolder([string]$path) {
    if ($path.StartsWith('\\')) { return $false }
    $root = [IO.Path]::GetPathRoot($path)
    if (-not $root) { return $false }
    return (New-Object IO.DriveInfo $root).DriveType -ne [IO.DriveType]::Network
}

function Read-DestFolder([string]$current) {
    while ($true) {
        $path = $null
        if ($current -and (Test-Path -LiteralPath $current -PathType Container)) {
            $in = [string](Read-Host "③ 勘太郎の指定フォルダ（Enter で $current のまま／C で選び直す）")
            if ($in.Trim() -eq '') { $path = $current }
        }
        if (-not $path) {
            Write-Host '③ 別の窓が開きます。印刷勘太郎の指定フォルダ（CSVを入れるフォルダ）を選んで「OK」を押してください。'
            $path = Select-FolderDialog
        }
        if (-not $path) {
            $path = ([string](Read-Host 'フォルダの場所を入力してください（例 C:\Kantaro\取込。Q で中止）')).Trim().Trim('"')
            if ($path -match '^(q|ｑ)$') { return $null }
            if ($path -eq '') { continue }
        }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            Write-Host "フォルダが見つかりません: $path" -ForegroundColor Yellow
            $current = $null
            continue
        }
        if (-not (Test-LocalFolder $path)) {
            throw 'ネットワーク上のフォルダ（\\サーバー名 や Z: など）は、このかんたん設定では使えません。TBM に連絡してください。'
        }
        return (Resolve-Path -LiteralPath $path).ProviderPath
    }
}

function Read-AgentConfig([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Write-AgentConfig([string]$path, [string]$url, [string]$token, [string]$dest, [bool]$writeDone) {
    $json = [ordered]@{ app_url = $url; token = $token; dest_folder = $dest; write_done = $writeDone } | ConvertTo-Json
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
}

# 受け取り係をコピーする。メモ帳などで BOM が消えていても、BOM付きで置き直す
function Install-AgentScript([string]$src, [string]$dst) {
    $code = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
    if ($code -notmatch 'api/agent/files') { throw "kantaro_agent.ps1 の中身が受け取り係ではありません: $src" }
    [IO.File]::WriteAllText($dst, $code, (New-Object Text.UTF8Encoding($true)))
}

# 受け取り係は SYSTEM として動くので、管理者以外は中身を書き換えられないようにする（読むのはだれでもよい）
function Protect-InstallDir([string]$dir) {
    $ErrorActionPreference = 'Continue'   # icacls の表示では止めない（うまくいったかは終了コードで見る）
    $out = & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$dir の権限を設定できませんでした: $out" }
}

# タスクスケジューラの登録内容。起動時と、登録した時刻から5分おき（再起動しても続く）
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
    <Description>三映CSV→勘太郎CSV変換アプリが出力したCSVを受け取り、印刷勘太郎の指定フォルダへ入れる（5分おき）。設定: $dir</Description>
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
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
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
        $tmp = Join-Path $env:TEMP 'kantaro-agent-task.xml'
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
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        $state = [string](Get-ScheduledTask -TaskName $taskName).State
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        # 今回の1回が終わったものだけを見る（267009 = 実行中、267011 = まだ一度も動いていない）
        if ($state -ne 'Running' -and $info.LastRunTime -ge $startedAt -and
            $info.LastTaskResult -ne 267009 -and $info.LastTaskResult -ne 267011) { return $info.LastTaskResult }
        Start-Sleep -Seconds 2
    }
    return $null
}

function Show-LogTail([string]$logPath) {
    if (Test-Path -LiteralPath $logPath) {
        Write-Host '記録の最後の行:'
        Get-Content -LiteralPath $logPath -Encoding UTF8 -Tail 5 | ForEach-Object { Write-Host "    $_" }
    }
}

function Invoke-Setup {
    Write-Host ''
    Write-Host '=== 勘太郎パソコンの受け取り係 かんたん設定 ===' -ForegroundColor Cyan
    Write-Host '変換アプリで出力したCSVを、このパソコンが5分おきに受け取り、勘太郎の指定フォルダへ入れるようにします。'
    Write-Host ''

    $agentSrc = Join-Path $PSScriptRoot 'kantaro_agent.ps1'
    if (-not (Test-Path -LiteralPath $agentSrc)) {
        throw 'このファイルと同じフォルダに kantaro_agent.ps1 がありません。3つのファイルを同じフォルダに入れてください。'
    }
    $cfgPath = Join-Path $InstallDir 'kantaro_agent.config.json'
    $agentPath = Join-Path $InstallDir 'kantaro_agent.ps1'
    $logPath = Join-Path $InstallDir 'kantaro_agent.log'

    $url = $null; $token = $null; $dest = $null; $writeDone = $false
    $old = Read-AgentConfig $cfgPath
    if ($old) {
        $url = $old.app_url; $token = $old.token; $dest = $old.dest_folder; $writeDone = [bool]$old.write_done
        Write-Host '前回の設定が見つかりました。変えない項目は、そのまま Enter を押してください。'
    }

    # ① ② URL と合言葉。つながるまで繰り返す
    while ($true) {
        $url = Read-AppUrl $url
        $token = Read-Token $token
        Write-Host '変換アプリにつないでいます…（最初は1分ほどかかることがあります）'
        $conn = Test-AppConnection $url $token
        if ($conn.Ok) { Write-Host 'つながりました。' -ForegroundColor Green; break }
        Write-Host $conn.Reason -ForegroundColor Yellow
        $ans = [string](Read-Host 'Enter でもう一度（URL・合言葉を入れ直せます）／Q で中止')
        if ($ans -match '^\s*(q|ｑ)') { Write-Host '中止しました。このパソコンの設定は何も変えていません。'; return }
    }

    # ③ 指定フォルダ
    $dest = Read-DestFolder $dest
    if (-not $dest) { Write-Host '中止しました。このパソコンの設定は何も変えていません。'; return }

    # まだ受け取っていないCSVがあれば、届く前に見てもらう（研修で試したCSVなどが紛れていないか）
    $files = $conn.Files
    if ($files.Count -gt 0) {
        Write-Host ''
        Write-Host "変換アプリに、まだ受け取っていないCSVが $($files.Count) 件あります。設定が終わると、すぐ指定フォルダへ届きます:" -ForegroundColor Yellow
        $files | Select-Object -First 10 | ForEach-Object { Write-Host "    $($_.name)" }
        if ($files.Count -gt 10) { Write-Host "    ほか $($files.Count - 10) 件" }
        $ans = [string](Read-Host '届いてよければ Y、やめるなら N')
        if ($ans -notmatch '^\s*(y|ｙ|はい)') { Write-Host '中止しました。このパソコンの設定は何も変えていません。'; return }
    }

    # 置く・登録する
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Protect-InstallDir $InstallDir
    Install-AgentScript $agentSrc $agentPath
    Write-AgentConfig $cfgPath $url $token $dest $writeDone
    $xml = New-AgentTaskXml $agentPath $InstallDir (Get-Date)
    Register-AgentTask $TaskName $xml
    Write-Host "タスクスケジューラに「$TaskName」を登録しました（5分おき）。"

    # 1回動かして確かめる
    Write-Host '試しに1回動かしています…'
    $result = Invoke-AgentOnce $TaskName
    Write-Host ''
    if ($result -eq 0) {
        Write-Host '設定が終わりました。' -ForegroundColor Green
        Write-Host "  受け取り係の場所: $InstallDir"
        Write-Host "  記録（受け取ったファイルとエラー）: $logPath"
        Write-Host '  このパソコンが動いている間、5分おきに変換アプリを見に行きます。'
        Write-Host '  変換アプリの画面の下に「勘太郎パソコンの受け取り係：最終確認 …」と時刻が出ていれば、動いています。'
        Write-Host '  設定に使った3つのファイルは、消してかまいません。'
    } elseif ($null -eq $result) {
        Write-Host '登録はできましたが、試しの1回がまだ終わっていません。数分後に、変換アプリの画面で最終確認の時刻を見てください。' -ForegroundColor Yellow
        Show-LogTail $logPath
    } else {
        Write-Host "登録はできましたが、試しの1回がうまくいきませんでした（終了コード $result）。" -ForegroundColor Red
        Show-LogTail $logPath
        Write-Host 'この画面の写真を撮って TBM に送ってください。（この画面ではつながったのに失敗する場合は、社内のプロキシの設定が必要かもしれません）'
    }
}

if ($LoadOnly) { return }

try { $Host.UI.RawUI.WindowTitle = '受け取り係のかんたん設定' } catch { }
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
