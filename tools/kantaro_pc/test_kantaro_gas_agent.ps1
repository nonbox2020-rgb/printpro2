# 勘太郎のパソコンの受け取り係（GAS 版）を、偽物の GAS（fake_gas_webapp.py）の上で動かして確かめる。
#   pwsh -NoProfile -File tools/kantaro_pc/test_kantaro_gas_agent.ps1
# GAS・勘太郎のフォルダ・タスクスケジューラ・入力はすべて偽物（本物には触らない）。勘太郎CSVは tests/expected の架空サンプル。

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $Here)
$Expected = Join-Path (Join-Path $Root 'tests') 'expected'
$T = Join-Path ([IO.Path]::GetTempPath()) ('kantaro-gas-agent-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Pwsh = (Get-Process -Id $PID).Path
$Token = '0123456789abcdef' * 4
$script:failed = 0
function Check([bool]$ok, [string]$name) {
    if ($ok) { Write-Host "  OK  $name" } else { Write-Host "  NG  $name" -ForegroundColor Red; $script:failed++ }
}
function Mk([string]$p) { [IO.Directory]::CreateDirectory($p) | Out-Null; return $p }
function Names([string]$dir) { @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object) }
function SameBytes([string]$a, [string]$b) {
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($a)) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($b))
}
$samples = @(Get-ChildItem -LiteralPath (Join-Path $Expected 'sample_E_2026-10-09_long_weekend') -Filter '*.csv' | Sort-Object Name)

# 偽物の GAS を動かす
$gasRoot = Mk (Join-Path $T 'gas')
$gasOut = Join-Path $gasRoot '2_勘太郎用'
$gasDone = Join-Path $gasRoot '3_渡し済み'
$gasSkip = Join-Path $gasRoot '4_渡さなかった分'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'python3'
$psi.Arguments = '"' + (Join-Path $Here 'fake_gas_webapp.py') + '" "' + $gasRoot + '"'
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$server = [Diagnostics.Process]::Start($psi)
$port = $server.StandardOutput.ReadLine()
$Url = "http://127.0.0.1:$port/macros/s/TEST/exec"
function Put-Gas([int[]]$indexes) {
    foreach ($i in $indexes) { Copy-Item -LiteralPath $samples[$i].FullName -Destination (Join-Path $gasOut $samples[$i].Name) }
}

try {
    $agentDir = Mk (Join-Path $T 'agent')
    Copy-Item -LiteralPath (Join-Path $Here 'kantaro_gas_agent.ps1') -Destination $agentDir
    $agent = Join-Path $agentDir 'kantaro_gas_agent.ps1'
    $log = Join-Path $agentDir 'kantaro_gas_agent.log'
    $ledger = Join-Path $agentDir 'kantaro_gas_agent.delivered.txt'
    $dest = Mk (Join-Path $T '勘太郎のcsv')
    function Set-AgentConfig([string]$u, [string]$tok, [string]$d) {
        $c = New-Object PSObject -Property ([ordered]@{ url = $u; token = $tok; dest_folder = $d })
        [IO.File]::WriteAllText((Join-Path $agentDir 'kantaro_gas_agent.config.json'), ($c | ConvertTo-Json))
    }
    function Run-Agent {
        $out = & $Pwsh -NoProfile -File $agent 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Out = $out }
    }
    function Log-Text { if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log) } else { '' } }

    Write-Host '== 受け取り係: 受け取って、勘太郎のフォルダへ入れる'
    Set-AgentConfig $Url $Token $dest
    Put-Gas @(0, 1, 2)
    $r = Run-Agent
    Check ($r.Code -eq 0) '終了コード 0'
    $want = @($samples[0..2] | ForEach-Object { $_.Name })
    Check (((Names $dest) -join '|') -eq ($want -join '|')) '勘太郎のフォルダに3件（書きかけの .tmp は残らない）'
    $same = $true
    foreach ($f in $samples[0..2]) { if (-not (SameBytes $f.FullName (Join-Path $dest $f.Name))) { $same = $false } }
    Check $same '中身は1バイトも変わらない'
    Check ((Names $gasOut).Count -eq 0 -and (Names $gasDone).Count -eq 3) 'GAS に知らせて、「3_渡し済み」へ移してもらう'
    Check (([regex]::Matches((Log-Text), '受け取り: ')).Count -eq 3) '記録に「受け取り」が3行'
    Check (([IO.File]::ReadAllLines($ledger)).Count -eq 3) '入れたファイルを控える'

    Write-Host '== 受け取り係: 同じ名前が勘太郎のフォルダに残っている'
    Put-Gas @(0)
    $r = Run-Agent
    $n2 = $samples[0].Name -replace '\.csv$', '_2.csv'
    Check ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $dest $n2))) '上書きせず _2 を付ける'

    Write-Host '== 受け取り係: 入れたのに、GAS への知らせが届かなかった'
    Put-Gas @(3)
    [IO.File]::WriteAllText((Join-Path $gasRoot 'fail_done'), '1')
    $r = Run-Agent
    Check ($r.Code -eq 1 -and (Test-Path -LiteralPath (Join-Path $dest $samples[3].Name))) '入れたが、知らせが届かず終了コード 1'
    Check ((Names $gasOut).Count -eq 1) 'GAS には残っている'
    $count = (Names $dest).Count
    $r = Run-Agent
    Check ($r.Code -eq 0 -and (Names $dest).Count -eq $count) '次の回は知らせ直すだけで、二重には入れない'
    Check ((Names $gasOut).Count -eq 0) 'GAS は「3_渡し済み」へ移す'

    Write-Host '== 受け取り係: うまくいかないとき（何も動かさず、記録に残す）'
    Put-Gas @(1)
    Set-AgentConfig $Url 'wrong-token' $dest
    $r = Run-Agent
    Check ($r.Code -eq 1 -and (Log-Text) -match '合言葉が違います' -and (Names $gasOut).Count -eq 1) '合言葉が違う'
    Set-AgentConfig ($Url -replace '/TEST/', '/LOGIN/') $Token $dest
    $r = Run-Agent
    Check ($r.Code -eq 1 -and (Log-Text) -match 'JSON ではない答え') 'ウェブアプリを「全員」に公開していない（ログインの画面が返る）'
    Set-AgentConfig 'http://127.0.0.1:9/macros/s/TEST/exec' $Token $dest
    $r = Run-Agent
    Check ($r.Code -eq 1) 'GAS につながらない'
    Set-AgentConfig $Url $Token (Join-Path $T 'no-such-folder')
    $r = Run-Agent
    Check ($r.Code -eq 1 -and (Log-Text) -match '勘太郎のフォルダが見つかりません') '勘太郎のフォルダが無い'
    Set-AgentConfig $Url $Token $dest
    $r = Run-Agent
    Check ($r.Code -eq 0 -and (Names $gasOut).Count -eq 0) '直れば、残っていたものを受け取る'

    Write-Host '== 受け取り係: 前の回がまだ動いている'
    Put-Gas @(2)
    $holder = New-Object System.Threading.Mutex($false, 'Global\kantaro-gas-agent')
    Check ($holder.WaitOne(0)) '（テスト）目印を先に取る'
    $r = Run-Agent
    Check ($r.Code -eq 0 -and (Names $gasOut).Count -eq 1) '何もせず終わる'
    $holder.ReleaseMutex(); $holder.Dispose()
    $r = Run-Agent
    Check ($r.Code -eq 0 -and (Names $gasOut).Count -eq 0) '目印が消えたら受け取る'

    # ---------------- かんたん設定 ----------------
    Write-Host '== かんたん設定（入力・タスクスケジューラ・権限は偽物）'
    . (Join-Path $Here 'setup_kantaro_gas_agent.ps1') -LoadOnly
    $InstallDir = Mk (Join-Path $T 'install')
    $DefaultDest = Join-Path $T 'no-default'
    $script:answers = New-Object System.Collections.Queue
    $script:prompts = @()
    function Read-Host([string]$Prompt) {
        $script:prompts += $Prompt
        if ($script:answers.Count -eq 0) { throw "（テスト）答えが足りません: $Prompt" }
        return $script:answers.Dequeue()
    }
    $script:xml = $null; $script:user = $null; $script:protected = $null; $script:lastResult = $null
    function Protect-InstallDir([string]$dir) { $script:protected = $dir }
    function Register-ScheduledTask([string]$TaskName, [string]$Xml, [string]$User, [switch]$Force) {
        $script:xml = $Xml; $script:taskName = $TaskName; $script:user = $User
    }
    function Start-ScheduledTask([string]$TaskName) {
        & $Pwsh -NoProfile -File (Join-Path $InstallDir 'kantaro_gas_agent.ps1') | Out-Null
        $script:lastResult = $LASTEXITCODE
    }
    function Get-ScheduledTask([string]$TaskName) { [pscustomobject]@{ State = 'Ready' } }
    function Get-ScheduledTaskInfo([string]$TaskName) { [pscustomobject]@{ LastRunTime = (Get-Date); LastTaskResult = $script:lastResult } }
    function Start-Sleep([int]$Seconds) { }
    function Select-FolderDialog { $null }

    Write-Host '-- 1回目: 合言葉を間違えて入れ直す・テスト用のフォルダ・残っていたCSVはよける'
    Put-Gas @(0, 1)
    $testDest = Join-Path $T 'テスト用のcsv'
    foreach ($a in @(($Url + '?usp=sharing'), 'wrong-token', '', $Url, "合言葉（勘太郎のパソコンのかんたん設定で貼る）: $Token", $testDest, 'Y', '')) {
        $script:answers.Enqueue($a)
    }
    Invoke-Setup
    Check ($script:answers.Count -eq 0) '聞かれたのは8つ（URL・合言葉 → やり直し → URL・合言葉 → フォルダ・作るか・残りのCSV）'
    $cfg = [IO.File]::ReadAllText((Join-Path $InstallDir 'kantaro_gas_agent.config.json')) | ConvertFrom-Json
    Check ($cfg.url -eq $Url) 'URL の後ろの ?usp=… は取る'
    Check ($cfg.token -eq $Token) '実行ログの行ごと貼っても、合言葉だけを取り出す'
    Check ($cfg.dest_folder -eq $testDest -and (Test-Path -LiteralPath $testDest)) 'テスト用のフォルダを作って、設定する'
    Check ((Names $gasOut).Count -eq 0 -and (Names $gasSkip).Count -eq 2 -and (Names $testDest).Count -eq 0) 'N（Enter）なら「4_渡さなかった分」へよけて、勘太郎へは渡さない'
    $bytes = [IO.File]::ReadAllBytes((Join-Path $InstallDir 'kantaro_gas_agent.ps1'))
    Check ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) '受け取り係は BOM 付きで置く'
    Check ($script:protected -eq $InstallDir) '置き場所を、管理者と SYSTEM だけが読めるようにする（合言葉が入るため）'
    [xml]$doc = $script:xml
    $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    Check ($script:taskName -eq 'kantaro-gas-agent' -and $script:user -eq 'SYSTEM') 'タスク「kantaro-gas-agent」を SYSTEM で登録'
    Check ($doc.SelectSingleNode('//t:Principal/t:UserId', $ns).InnerText -eq 'S-1-5-18') 'だれもログオンしていなくても動く（SYSTEM）'
    Check ($null -ne $doc.SelectSingleNode('//t:BootTrigger', $ns)) '起動したときにも動く'
    Check ($doc.SelectSingleNode('//t:TimeTrigger/t:Repetition/t:Interval', $ns).InnerText -eq 'PT5M') '5分おき'
    Check ($doc.SelectSingleNode('//t:Exec/t:Arguments', $ns).InnerText -match 'kantaro_gas_agent\.ps1"$') '受け取り係を動かす'
    Check ($script:lastResult -eq 0) '1回動かして、うまくいく'

    Write-Host '-- 2回目: 本番のフォルダへ切りかえ・残っていたCSVは渡す'
    Put-Gas @(2)
    $realDest = Mk (Join-Path $T '本番のcsv')
    $script:prompts = @()
    foreach ($a in @('', '', $realDest, 'y')) { $script:answers.Enqueue($a) }
    Invoke-Setup
    Check ($script:prompts[0] -match '前回と同じ' -and $script:prompts[1] -match '前回と同じ') 'URL と合言葉は前回のまま使える'
    Check ($script:prompts[2] -match [regex]::Escape($testDest)) 'フォルダは前回の場所を勧める'
    Check ((Names $realDest).Count -eq 1 -and (Names $gasOut).Count -eq 0) 'Y なら、1回目の実行で本番のフォルダへ渡す'

    Write-Host '-- ネットワーク上のフォルダは使えない'
    foreach ($a in @('', '', '\\server\csv', 'q')) { $script:answers.Enqueue($a) }
    Invoke-Setup
    $cfg = [IO.File]::ReadAllText((Join-Path $InstallDir 'kantaro_gas_agent.config.json')) | ConvertFrom-Json
    Check ($script:answers.Count -eq 0 -and $cfg.dest_folder -eq $realDest) '\\パソコン名\… は断り、中止したら何も変えない'

    Write-Host '-- URL の形'
    Check ((ConvertTo-GasUrl 'https://script.google.com/a/macros/yushin-p.co.jp/s/AKfy_x-1/exec') -eq 'https://script.google.com/macros/s/AKfy_x-1/exec') 'Google Workspace の URL（/a/macros/会社のドメイン/…）は、だれでも使える形に直す'
    Check ($null -eq (ConvertTo-GasUrl 'https://script.google.com/macros/s/AKfy/dev')) '/dev（テスト用のURL）は受け付けない'
    Check ($null -eq (ConvertTo-GasUrl 'https://example.com/macros/s/AKfy/exec')) 'Google 以外は受け付けない'
}
finally {
    try { $server.Kill() } catch { }
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed -gt 0) {
    Write-Host "❌ $($script:failed) 件が期待と違います" -ForegroundColor Red
    exit 1
}
Write-Host '✅ 勘太郎のパソコンの受け取り係（GAS 版）は期待どおりに動きます' -ForegroundColor Green
