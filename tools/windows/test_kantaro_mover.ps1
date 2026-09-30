# 勘太郎の移し係（Windows）を、偽物のフォルダの上で動かして確かめる。
#   pwsh -NoProfile -File tools/windows/test_kantaro_mover.ps1
# Googleドライブ・勘太郎のフォルダ・タスクスケジューラ・入力はすべて偽物（本物には触らない）。
# 勘太郎CSVは tests/expected の架空サンプルを使う。

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $Here)
$Expected = Join-Path (Join-Path $Root 'tests') 'expected'
$T = Join-Path ([IO.Path]::GetTempPath()) ('kantaro-mover-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Pwsh = (Get-Process -Id $PID).Path
$script:failed = 0
function Check([bool]$ok, [string]$name) {
    if ($ok) { Write-Host "  OK  $name" } else { Write-Host "  NG  $name" -ForegroundColor Red; $script:failed++ }
}
function Mk([string]$p) { [IO.Directory]::CreateDirectory($p) | Out-Null; return $p }
function Names([string]$dir) { @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object) }
function SameBytes([string]$a, [string]$b) {
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($a)) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($b))
}
$sampleE = Join-Path $Expected 'sample_E_2026-10-09_long_weekend'
$sampleFiles = @(Get-ChildItem -LiteralPath $sampleE -Filter '*.csv' | Sort-Object Name | Select-Object -First 3)
function Put-Csv([string]$dir, [int]$count) {
    foreach ($f in ($sampleFiles | Select-Object -First $count)) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dir $f.Name) }
}

$profileDir = Mk (Join-Path $T 'profile')
$env:USERPROFILE = $profileDir
$myDrive = Mk (Join-Path $profileDir 'マイドライブ')
$src = Mk (Join-Path (Join-Path $myDrive '三映CSV連携') '2_勘太郎用')
$done = Join-Path (Join-Path $myDrive '三映CSV連携') '3_渡し済み'
$dest = Mk (Join-Path $T 'kantaro')
$install = Mk (Join-Path $T 'install')
Copy-Item -LiteralPath (Join-Path $Here 'kantaro_mover.ps1') -Destination $install
$mover = Join-Path $install 'kantaro_mover.ps1'
$log = Join-Path $install 'mover.log'
function Set-Config([string]$d, [string]$s) {
    $c = New-Object PSObject -Property ([ordered]@{ destination = $d; source = $s })
    [IO.File]::WriteAllText((Join-Path $install 'config.json'), ($c | ConvertTo-Json), (New-Object Text.UTF8Encoding($true)))
}
function Run-Mover([string[]]$extra) {
    $out = & $Pwsh -NoProfile -File $mover @extra 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Log-Text { if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log) } else { '' } }
function State { $p = Join-Path $install 'state.txt'; if (Test-Path -LiteralPath $p) { ([IO.File]::ReadAllText($p)).Trim() } else { '' } }

try {
    Write-Host '== 移し係: 確かめるだけ（-Check）'
    Set-Config $dest ''
    Put-Csv $src 3
    $r = Run-Mover @('-Check')
    Check ($r.Code -eq 0) '終了コード 0'
    Check ($r.Out -match [regex]::Escape("Googleドライブ: $src")) 'ユーザーのフォルダの「マイドライブ」の中から「2_勘太郎用」を見つける'
    Check ($r.Out -match '書き込めます') '勘太郎のフォルダに書き込めることを確かめる'
    Check ($r.Out -match '渡すファイル: 3 件') '渡すファイルは3件'
    Check ((Names $dest).Count -eq 0 -and (Names $src).Count -eq 3) '何も動かさない'
    Check (-not (Test-Path -LiteralPath $log)) '記録も書かない'

    Write-Host '== 移し係: 渡す'
    $r = Run-Mover @()
    Check ($r.Code -eq 0) '終了コード 0'
    $want = @($sampleFiles | ForEach-Object { $_.Name })
    Check (((Names $dest) -join '|') -eq ($want -join '|')) '勘太郎のフォルダに3件（書きかけの .tmp は残らない）'
    $same = $true
    foreach ($f in $sampleFiles) { if (-not (SameBytes $f.FullName (Join-Path $dest $f.Name))) { $same = $false } }
    Check $same '中身は1バイトも変わらない'
    Check ((Names $src).Count -eq 0) '「2_勘太郎用」は空になる'
    Check (((Names $done) -join '|') -eq ($want -join '|')) '渡したファイルは「3_渡し済み」へ'
    Check (([regex]::Matches((Log-Text), '渡しました: ')).Count -eq 3) '記録に「渡しました」が3行'
    Check ((State) -eq 'ok') '状態は ok'

    Write-Host '== 移し係: 同じ名前がもう一度届く'
    Put-Csv $src 2
    $r = Run-Mover @()
    Check ($r.Code -eq 0) '終了コード 0'
    $n2 = $sampleFiles[0].Name -replace '\.csv$', '_2.csv'
    Check ((Test-Path -LiteralPath (Join-Path $dest $n2)) -and (Names $dest).Count -eq 5) '勘太郎のフォルダでは上書きせず _2 を付ける'
    Check ((Test-Path -LiteralPath (Join-Path $done $n2)) -and (Names $done).Count -eq 5) '「3_渡し済み」でも _2 を付ける'
    Check ((Log-Text) -match [regex]::Escape($sampleFiles[0].Name + ' → ' + $n2)) '記録に元の名前と渡した名前'

    Write-Host '== 移し係: 渡すものが無い'
    $before = Log-Text
    $r = Run-Mover @()
    Check ($r.Code -eq 0 -and (Log-Text) -eq $before) '何もせず終わる（記録も増えない）'

    Write-Host '== 移し係: 勘太郎のフォルダにつながらない'
    Set-Config (Join-Path $T 'no-such-share') ''
    Put-Csv $src 1
    $r = Run-Mover @()
    Check ($r.Code -eq 1) '終了コード 1'
    Check ((Names $src).Count -eq 1) 'ファイルはドライブに残す'
    Check ((Log-Text) -match 'につながりません') '記録に「つながりません」'
    $first = State
    Check ($first -match '^wait \d+$') 'すぐには知らせず、はじめて失敗した時刻を控える'
    $r = Run-Mover @()
    Check ($r.Code -eq 1 -and (State) -eq $first) '15分たつまでは知らせない'
    [IO.File]::WriteAllText((Join-Path $install 'state.txt'), 'wait ' + (Get-Date).AddMinutes(-20).Ticks)
    $r = Run-Mover @()
    Check ($r.Code -eq 1 -and (State) -eq 'ng') '15分以上続いたら知らせる（状態は ng）'
    $r = Run-Mover @()
    Check ($r.Code -eq 1 -and (State) -eq 'ng') '知らせるのは1回だけ'

    Write-Host '== 移し係: つながるようになった（設定の場所が古くても探し直す）'
    Set-Config $dest (Join-Path $T 'old-drive-letter')
    $r = Run-Mover @()
    Check ($r.Code -eq 0) '終了コード 0'
    Check ((Names $src).Count -eq 0 -and (Names $dest).Count -eq 6) '残っていたファイルを渡す'
    Check ((Log-Text) -match '元にもどりました' -and (State) -eq 'ok') '記録に「元にもどりました」、状態は ok'

    Write-Host '== 移し係: 前の回がまだ動いている'
    Put-Csv $src 1
    $holder = New-Object System.Threading.Mutex($false, 'Local\kantaro-mover')
    Check ($holder.WaitOne(0)) '（テスト）目印を先に取る'
    $r = Run-Mover @()
    Check ($r.Code -eq 0 -and (Names $src).Count -eq 1) '何もせず終わる'
    $holder.ReleaseMutex(); $holder.Dispose()
    $r = Run-Mover @()
    Check ($r.Code -eq 0 -and (Names $src).Count -eq 0) '目印が消えたら渡す'

    Write-Host '== 移し係: Googleドライブが見つからない'
    Rename-Item -LiteralPath (Join-Path $myDrive '三映CSV連携') -NewName '三映CSV連携_止めた'
    $r = Run-Mover @()
    Check ($r.Code -eq 1 -and (Log-Text) -match '見つかりません') '終了コード 1、記録に「見つかりません」'
    Rename-Item -LiteralPath (Join-Path $myDrive '三映CSV連携_止めた') -NewName '三映CSV連携'

    # ---------------- かんたん設定 ----------------
    Write-Host '== かんたん設定（入力・タスクスケジューラは偽物）'
    $env:USERPROFILE = Mk (Join-Path $T 'profile2')
    $myDrive2 = Mk (Join-Path $env:USERPROFILE 'My Drive')
    $src2 = Mk (Join-Path (Join-Path $myDrive2 '三映CSV連携') '2_勘太郎用')
    $env:WINDIR = Mk (Join-Path $T 'win')
    Mk (Join-Path $env:WINDIR 'System32') | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $env:WINDIR 'System32') 'wscript.exe'), '')
    $env:TEMP = Mk (Join-Path $T 'temp')
    . (Join-Path $Here 'setup_kantaro_mover.ps1') -LoadOnly

    $script:answers = New-Object System.Collections.Queue
    $script:prompts = @()
    function Read-Host([string]$Prompt) {
        $script:prompts += $Prompt
        if ($script:answers.Count -eq 0) { throw "（テスト）答えが足りません: $Prompt" }
        return $script:answers.Dequeue()
    }
    $script:xml = $null
    $script:explorer = @()
    $script:lastResult = $null
    function Register-ScheduledTask([string]$TaskName, [string]$Xml, [switch]$Force) { $script:xml = $Xml; $script:taskName = $TaskName }
    function Start-ScheduledTask([string]$TaskName) {
        $mv = Join-Path (Join-Path $env:USERPROFILE 'kantaro-mover') 'kantaro_mover.ps1'
        & $Pwsh -NoProfile -File $mv | Out-Null
        $script:lastResult = $LASTEXITCODE
    }
    function Get-ScheduledTask([string]$TaskName) { [pscustomobject]@{ State = 'Ready' } }
    function Get-ScheduledTaskInfo([string]$TaskName) { [pscustomobject]@{ LastRunTime = (Get-Date); LastTaskResult = $script:lastResult } }
    function Start-Sleep([int]$Seconds) { }
    function Start-Process([string]$FilePath, $ArgumentList) { $script:explorer += [string]$ArgumentList }
    function Get-MoverUserName { 'KANTAROXI\岩崎' }
    $installDir = Join-Path $env:USERPROFILE 'kantaro-mover'

    Write-Host '-- 1回目: テスト用のフォルダへ。研修のダミーデータ2件は渡さずによける'
    Put-Csv $src2 2
    $testDest = Join-Path $T 'テスト用の勘太郎フォルダ'
    foreach ($a in @($testDest, 'Y', '')) { $script:answers.Enqueue($a) }
    Invoke-MoverSetup
    Check ($script:answers.Count -eq 0) '聞かれたのは3つ（フォルダ・作るか・残りのCSV）'
    Check ($script:prompts[0] -match [regex]::Escape('\\192.168.0.223\csv')) 'はじめは \\192.168.0.223\csv を勧める'
    Check (Test-Path -LiteralPath $testDest -PathType Container) 'テスト用のフォルダを作る'
    $skip = Join-Path (Join-Path $myDrive2 '三映CSV連携') '4_渡さなかった分'
    Check ((Names $skip).Count -eq 2 -and (Names $src2).Count -eq 0) 'N（Enter）なら「4_渡さなかった分」へよける'
    Check ((Names $testDest).Count -eq 0) 'よけたものは渡さない'
    $bytes = [IO.File]::ReadAllBytes((Join-Path $installDir 'kantaro_mover.ps1'))
    Check ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) '移し係は BOM 付きで置く'
    $cfg = [IO.File]::ReadAllText((Join-Path $installDir 'config.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    Check ($cfg.destination -eq $testDest -and $cfg.source -eq $src2) '設定に勘太郎のフォルダとドライブの場所'
    $vbs = [IO.File]::ReadAllBytes((Join-Path $installDir 'run_hidden.vbs'))
    Check (@($vbs | Where-Object { $_ -gt 127 }).Count -eq 0) 'run_hidden.vbs は英数字だけ（どのWindowsでも読める）'
    [xml]$doc = $script:xml
    $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    Check ($script:taskName -eq 'kantaro-mover') 'タスクの名前は kantaro-mover'
    Check ($doc.SelectSingleNode('//t:Principal/t:LogonType', $ns).InnerText -eq 'InteractiveToken') 'ログオン中だけ動く（ドライブが見えるのはログオン中だけ）'
    Check ($doc.SelectSingleNode('//t:Principal/t:UserId', $ns).InnerText -eq 'KANTAROXI\岩崎') 'この人のタスクとして登録'
    Check ($doc.SelectSingleNode('//t:TimeTrigger/t:Repetition/t:Interval', $ns).InnerText -eq 'PT5M') '5分おき'
    Check ($doc.SelectSingleNode('//t:LogonTrigger/t:UserId', $ns).InnerText -eq 'KANTAROXI\岩崎') 'ログオンしたときにも動く'
    Check ($doc.SelectSingleNode('//t:Exec/t:Command', $ns).InnerText -match 'wscript\.exe$') '画面を出さずに動かす（wscript）'
    Check ($doc.SelectSingleNode('//t:Exec/t:Arguments', $ns).InnerText -match 'run_hidden\.vbs"$') 'run_hidden.vbs を動かす'
    Check ($script:lastResult -eq 0) '1回動かして、うまくいく'

    Write-Host '-- 2回目: 本番のフォルダへ切りかえ。残っていたCSVは Y で渡す'
    $realDest = Mk (Join-Path $T '勘太郎の本番フォルダ')
    Put-Csv $src2 2
    $script:prompts = @()
    foreach ($a in @($realDest, 'y')) { $script:answers.Enqueue($a) }
    Invoke-MoverSetup
    Check ($script:prompts[0] -match [regex]::Escape($testDest)) '前回のフォルダを勧める'
    Check ((Names $realDest).Count -eq 2 -and (Names $src2).Count -eq 0) 'Y なら、1回目の実行で渡す'
    $cfg = [IO.File]::ReadAllText((Join-Path $installDir 'config.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    Check ($cfg.destination -eq $realDest) '設定は本番のフォルダに変わる'

    Write-Host '-- 3回目: 共有フォルダにつながらないので中止'
    $script:explorer = @()
    foreach ($a in @('\\192.168.0.223\csv\', 'q')) { $script:answers.Enqueue($a) }
    Invoke-MoverSetup
    Check ($script:explorer.Count -eq 1 -and $script:explorer[0] -eq '"\\192.168.0.223\csv"') 'エクスプローラーで共有フォルダを開いて、パスワードを覚えさせる案内'
    $cfg = [IO.File]::ReadAllText((Join-Path $installDir 'config.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    Check ($cfg.destination -eq $realDest) '中止したら何も変えない'

    Write-Host '-- ドライブが見つからない'
    Rename-Item -LiteralPath (Join-Path $myDrive2 '三映CSV連携') -NewName '三映CSV連携_止めた'
    $script:prompts = @()
    Invoke-MoverSetup
    Check ($script:prompts.Count -eq 0) '何も聞かずに、準備のしかたを出して終わる'
}
finally {
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed -gt 0) {
    Write-Host "❌ $($script:failed) 件が期待と違います" -ForegroundColor Red
    exit 1
}
Write-Host '✅ 勘太郎の移し係（Windows）は期待どおりに動きます' -ForegroundColor Green
