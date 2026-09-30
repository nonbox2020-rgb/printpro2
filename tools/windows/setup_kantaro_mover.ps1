# 勘太郎の移し係（Windows） かんたん設定
#
# 使い方: 同じフォルダの setup_kantaro_mover.bat をダブルクリックする（管理者でなくてよい）。
#   毎日このパソコンにログインして使う人の名前でログインした状態で実行する。
#   先にパソコン版Googleドライブを入れ、GAS を動かしている Google アカウントでログインしておく。
# 聞くのは2つだけ: 勘太郎のフォルダ（Enter で \\192.168.0.223\csv）と、
#   「2_勘太郎用」にすでにあるCSV（研修のダミーデータなど）を渡すかどうか。
# してくれること:
#   1. パソコン版Googleドライブの「三映CSV連携\2_勘太郎用」を探す
#   2. 勘太郎のフォルダに書き込めるか確かめる（つながらなければ、名前とパスワードを覚えさせる案内を出す）
#   3. 「ユーザーのフォルダ\kantaro-mover」に移し係（kantaro_mover.ps1）と設定を置く
#   4. タスクスケジューラに「kantaro-mover」を登録する（この人がログオンしている間、5分おき。画面は出ない）
#   5. 1回動かして、結果を見せる
# もう一度実行すると、勘太郎のフォルダを変えられる（テスト用のフォルダから本番の \\192.168.0.223\csv へ、など）。
# やめるとき: タスクスケジューラで「kantaro-mover」を右クリックして「無効」か「削除」。
#
# このファイルは UTF-8（BOM付き）で保存すること（Windows PowerShell 5.1 が日本語を正しく読むため）。

param([switch]$LoadOnly)   # テスト用: 関数を読み込むだけで、設定は始めない

$SetupLoadOnly = [bool]$LoadOnly   # 下で移し係を読み込むと $LoadOnly が上書きされるので、先に控える
$ErrorActionPreference = 'Stop'
$TaskName = 'kantaro-mover'
$DefaultDest = '\\192.168.0.223\csv'
$SkipName = '4_渡さなかった分'
$SetupDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MoverSource = Join-Path $SetupDir 'kantaro_mover.ps1'
if (-not (Test-Path -LiteralPath $MoverSource)) {
    Write-Host "kantaro_mover.ps1 が見つかりません。setup_kantaro_mover.bat と同じフォルダに置いてください: $SetupDir" -ForegroundColor Red
    Read-Host 'Enter で閉じます' | Out-Null
    exit 1
}
. $MoverSource -LoadOnly   # 移し係と同じ探し方・確かめ方を使う（Find-KantaroSource・Test-KantaroDest など）

function Get-MoverUserName { [Security.Principal.WindowsIdentity]::GetCurrent().Name }

# ① 勘太郎のフォルダを聞く。やめるなら $null
function Read-MoverDest([string]$current) {
    $default = $current
    if (-not $default) { $default = $DefaultDest }
    while ($true) {
        $in = ([string](Read-Host "① 勘太郎のフォルダ（Enter で $default のまま／Q で中止）")).Trim().Trim('"').Trim()
        if ($in -eq '') { $in = $default }
        if ($in -eq 'q' -or $in -eq 'Q') { return $null }
        if ($in.StartsWith('\\')) { return $in.TrimEnd('\') }   # 共有フォルダ（\\パソコン\共有名）
        # このパソコンのフォルダ（テスト用など）。無ければ作る
        try { $full = [IO.Path]::GetFullPath($in) } catch {
            Write-Host 'フォルダの場所として読めません。もう一度入れてください（例 \\192.168.0.223\csv）' -ForegroundColor Yellow
            continue
        }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
            $ans = ([string](Read-Host "$full はまだありません。作りますか？（Y/N）")).Trim()
            if ($ans -notmatch '^[yY]') { continue }
            [IO.Directory]::CreateDirectory($full) | Out-Null
        }
        return $full
    }
}

# 勘太郎のフォルダに書き込めるようになるまで案内する。書き込めれば $true、やめれば $false
function Confirm-MoverDest([string]$dest) {
    while ($true) {
        $state = Test-KantaroDest $dest
        if ($state -eq 'ok') {
            Write-Host "   → 書き込めます: $dest" -ForegroundColor Green
            return $true
        }
        if ($state -eq 'つながりません') {
            Write-Host "   → 勘太郎のフォルダ（$dest）につながりません。" -ForegroundColor Yellow
            if ($dest.StartsWith('\\')) {
                Write-Host '     エクスプローラーで開きます。名前（例 KANTAROXI\kantaro-share）とパスワードを入れ、'
                Write-Host '     「資格情報を記憶する」にチェックして OK を押してください。フォルダが開けば準備完了です。'
                Write-Host '     名前を聞かれずにエラーになるときは、勘太郎のパソコンの電源・ネットワーク・共有名を確かめてください。'
                try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dest + '"') } catch { }
            }
        } else {
            Write-Host "   → つながりましたが、書き込めません（$dest）。" -ForegroundColor Yellow
            Write-Host '     勘太郎のパソコンで、フォルダの「共有 → 詳細な共有 → アクセス許可」と「セキュリティ」の両方で、'
            Write-Host '     つなぐ名前（kantaro-share など）に「変更」を許可してください。'
        }
        $ans = ([string](Read-Host 'できたら Enter でもう一度確かめます（Q で中止）')).Trim()
        if ($ans -eq 'q' -or $ans -eq 'Q') { return $false }
    }
}

# ② 「2_勘太郎用」にすでにあるCSV（研修のダミーデータなど）を、渡すか・渡さずによけるか決める
function Resolve-WaitingFiles([string]$src) {
    $waiting = @(Get-ChildItem -LiteralPath $src -File -Filter '*.csv' | Sort-Object Name)
    if ($waiting.Count -eq 0) { return }
    Write-Host ''
    Write-Host "「$OutName」に、まだ渡していないCSVが $($waiting.Count) 件あります（研修のダミーデータなども含みます）:" -ForegroundColor Yellow
    $waiting | Select-Object -First 15 | ForEach-Object { Write-Host "    - $($_.Name)" }
    if ($waiting.Count -gt 15) { Write-Host "    …ほか $($waiting.Count - 15) 件" }
    Write-Host '    Y = これも勘太郎のフォルダへ渡す'
    Write-Host "    N = 渡さない（ドライブの「$SkipName」へよける）"
    while ($true) {
        $ans = ([string](Read-Host '② Y か N（Enter で N）')).Trim()
        if ($ans -eq '' -or $ans -match '^[nN]') { break }
        if ($ans -match '^[yY]') {
            Write-Host '   → 渡します'
            return
        }
    }
    $skipDir = Join-Path (Split-Path -Parent $src) $SkipName
    [IO.Directory]::CreateDirectory($skipDir) | Out-Null
    foreach ($f in $waiting) {
        Move-Item -LiteralPath $f.FullName -Destination (Join-Path $skipDir (Get-UniqueName $skipDir $f.Name))
    }
    Write-Host "   → $($waiting.Count) 件を「$SkipName」へよけました（勘太郎へは渡しません）"
}

# 移し係・画面を出さずに動かすための小さなファイル・設定を置く。メモ帳などで BOM が消えていても、BOM付きで置き直す
function Install-Mover([string]$dir, [string]$dest, [string]$src) {
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $code = [IO.File]::ReadAllText($MoverSource, [Text.Encoding]::UTF8)
    if ($code -notmatch 'Send-KantaroFile') { throw "kantaro_mover.ps1 の中身が移し係ではありません: $MoverSource" }
    [IO.File]::WriteAllText((Join-Path $dir 'kantaro_mover.ps1'), $code, (New-Object Text.UTF8Encoding($true)))
    $vbs = @(
        "' Runs kantaro_mover.ps1 without showing a window (started by Task Scheduler).",
        'Dim fso, sh, dir',
        'Set fso = CreateObject("Scripting.FileSystemObject")',
        'Set sh = CreateObject("WScript.Shell")',
        'dir = fso.GetParentFolderName(WScript.ScriptFullName)',
        'WScript.Quit sh.Run("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & dir & "\kantaro_mover.ps1""", 0, True)'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $dir 'run_hidden.vbs'), $vbs + "`r`n", [Text.Encoding]::ASCII)
    $config = New-Object PSObject -Property ([ordered]@{ destination = $dest; source = $src })
    [IO.File]::WriteAllText((Join-Path $dir 'config.json'), ($config | ConvertTo-Json), (New-Object Text.UTF8Encoding($true)))
}

# タスクスケジューラの登録内容。ログオンしたときと、登録した時刻から5分おき（再起動しても続く）。
# パソコン版Googleドライブはログオン中の人にしか見えないので、その人がログオンしている間だけ動かす
function New-MoverTaskXml([string]$dir, [string]$user, [datetime]$start, [bool]$useWscript) {
    if ($useWscript) {
        # 画面を一瞬も出さない
        $command = Join-Path $env:WINDIR 'System32\wscript.exe'
        $arguments = '//B //Nologo "' + (Join-Path $dir 'run_hidden.vbs') + '"'
    } else {
        # wscript が無いパソコン（VBScript を止めたもの）: 動くたびに一瞬だけ窓が出る
        $command = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $dir 'kantaro_mover.ps1') + '"'
    }
    $cmd = [Security.SecurityElement]::Escape($command)
    $arg = [Security.SecurityElement]::Escape($arguments)
    $wd = [Security.SecurityElement]::Escape($dir)
    $who = [Security.SecurityElement]::Escape($user)
    $when = $start.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>TBM Co., Ltd.</Author>
    <Description>パソコン版Googleドライブの勘太郎CSV（三映CSV連携\2_勘太郎用）を、勘太郎のフォルダへ移す（ログオン中、5分おき）。設定: $wd</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$who</UserId>
      <Delay>PT2M</Delay>
    </LogonTrigger>
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
      <UserId>$who</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
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
      <WorkingDirectory>$wd</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Register-MoverTask([string]$taskName, [string]$xml) {
    try {
        Register-ScheduledTask -TaskName $taskName -Xml $xml -Force | Out-Null
    } catch {
        $first = $_.Exception.Message
        $ErrorActionPreference = 'Continue'
        $tmp = Join-Path $env:TEMP 'kantaro-mover-task.xml'
        [IO.File]::WriteAllText($tmp, $xml, [Text.Encoding]::Unicode)   # schtasks は UTF-16 の XML を読む
        $out = & schtasks.exe /Create /TN $taskName /XML $tmp /F 2>&1
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) { throw "タスクスケジューラに登録できませんでした: $first / $out" }
    }
}

# 登録したタスクを1回動かし、終わるまで待つ。戻り値は終了コード（0 = うまくいった）。時間内に終わらなければ $null
function Invoke-MoverOnce([string]$taskName) {
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

function Show-MoverLogTail([string]$logPath) {
    if (Test-Path -LiteralPath $logPath) {
        Write-Host '記録の最後の行:'
        Get-Content -LiteralPath $logPath -Encoding UTF8 -Tail 8 | ForEach-Object { Write-Host "    $_" }
    }
}

function Invoke-MoverSetup {
    Write-Host ''
    Write-Host '=== 勘太郎の移し係（Windows） かんたん設定 ===' -ForegroundColor Cyan
    Write-Host "パソコン版Googleドライブの「$ParentName\$OutName」に入った勘太郎CSVを、5分おきに勘太郎のフォルダへ移すようにします。"
    Write-Host ''

    $src = Find-KantaroSource
    if (-not $src) {
        Write-Host "Googleドライブの「$ParentName\$OutName」が見つかりません。" -ForegroundColor Yellow
        Write-Host '  - パソコン版Googleドライブを入れ、GAS を動かしている Google アカウントでログインしてください'
        Write-Host "  - エクスプローラーで「Google Drive」→「マイドライブ」→「$ParentName」→「$OutName」が開ければ準備完了です"
        Write-Host '  - 準備ができたら、もう一度 setup_kantaro_mover.bat を実行してください'
        return
    }
    Write-Host "Googleドライブ: $src" -ForegroundColor Green

    $installDir = Join-Path $env:USERPROFILE 'kantaro-mover'
    $current = $null
    $old = Read-MoverConfig (Join-Path $installDir 'config.json')
    if ($old -and $old.destination) { $current = [string]$old.destination }

    $dest = Read-MoverDest $current
    if (-not $dest) { Write-Host '中止しました（何も変えていません）'; return }
    if (-not (Confirm-MoverDest $dest)) { Write-Host '中止しました（何も変えていません）'; return }

    Resolve-WaitingFiles $src

    Install-Mover $installDir $dest $src
    Write-Host "移し係を置きました: $installDir"

    $useWscript = Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\wscript.exe')
    $xml = New-MoverTaskXml $installDir (Get-MoverUserName) (Get-Date).AddMinutes(1) $useWscript
    Register-MoverTask $TaskName $xml
    Write-Host "タスクスケジューラに「$TaskName」を登録しました（ログオン中、5分おき）" -ForegroundColor Green

    Write-Host '1回動かして確かめます…'
    try {
        $result = Invoke-MoverOnce $TaskName
    } catch {
        Write-Host '（タスクから動かせなかったので、この画面で動かします）'
        & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installDir 'kantaro_mover.ps1')
        $result = $LASTEXITCODE
    }
    Show-MoverLogTail (Join-Path $installDir 'mover.log')
    Write-Host ''
    if ($result -eq 0) {
        Write-Host '設定できました。このパソコンにログオンしている間、5分おきに動きます（画面は出ません）。' -ForegroundColor Green
    } elseif ($null -eq $result) {
        Write-Host '1回目がまだ終わっていません。数分後に記録を見てください。' -ForegroundColor Yellow
    } else {
        Write-Host "1回目がうまくいきませんでした（終了コード $result）。上の記録を見てください。5分後にもう一度動きます。" -ForegroundColor Yellow
    }
    Write-Host "  記録: $(Join-Path $installDir 'mover.log')（メモ帳で開けます）"
    Write-Host "  やめるとき: タスクスケジューラで「$TaskName」を右クリックして「無効」か「削除」"
    if ($dest -eq $DefaultDest -or $dest.StartsWith('\\')) {
        Write-Host '  ご注意: 本番の勘太郎のフォルダにつないだので、ここから先はダミーデータを送らないでください（勘太郎に取り込まれます）' -ForegroundColor Yellow
    }
}

if ($SetupLoadOnly) { return }
try {
    Invoke-MoverSetup
} catch {
    Write-Host ('うまくいきませんでした: ' + $_.Exception.Message) -ForegroundColor Red
}
Write-Host ''
Read-Host 'Enter で閉じます' | Out-Null
