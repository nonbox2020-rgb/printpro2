# 勘太郎の移し係（Windows）
# パソコン版Googleドライブの「三映CSV連携\2_勘太郎用」にある勘太郎CSVを、
# 勘太郎が読むフォルダ（例 \\192.168.0.223\csv）へ移す。
# タスクスケジューラが5分おきに動かす（入れ方は setup_kantaro_mover.bat）。
#
#   kantaro_mover.ps1          いま1回動かす
#   kantaro_mover.ps1 -Check   何も移さずに、見つけた場所・書き込めるか・渡すファイルを出す
#
# 渡し方:
#   - 勘太郎のフォルダへ「.名前.tmp」でコピー → 大きさを確かめる → 本当の名前に変える
#     （勘太郎が書きかけのファイルを読まないように）。同じ名前があれば _2、_3 … を付ける
#   - 渡し終えたファイルは、ドライブの「3_渡し済み」へ移す（記録として残り、二度渡さない）
#   - 勘太郎のフォルダにつながらないときは何も動かさず、次の回にやり直す（15分以上続いたら1回だけ知らせる）
# 設定: 同じフォルダの config.json（destination = 勘太郎のフォルダ、source = ドライブの場所。見つからなければ自動で探す）
# 記録: 同じフォルダの mover.log
#
# このファイルは UTF-8（BOM付き）で保存すること（Windows PowerShell 5.1 が日本語を正しく読むため）。

param([switch]$Check, [switch]$LoadOnly)   # LoadOnly: 関数を読み込むだけ（設定の道具とテストが使う）

$ErrorActionPreference = 'Stop'
$ParentName = '三映CSV連携'
$OutName = '2_勘太郎用'
$DoneName = '3_渡し済み'
$MoverDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MoverLog = Join-Path $MoverDir 'mover.log'
$MoverState = Join-Path $MoverDir 'state.txt'
$MoverConfig = Join-Path $MoverDir 'config.json'

function Write-MoverLog([string]$message) {
    Write-Host $message
    if ($Check) { return }
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $message
    try { [IO.File]::AppendAllText($MoverLog, $line + "`r`n", (New-Object Text.UTF8Encoding($true))) } catch { }
}

# 画面の右下に知らせる（うまく出せなくても止めない）。
# 型は文字で指定する（[System.Windows.Forms...] と書くと、読み込む前に型を探して失敗することがある）
function Show-MoverNotice([string]$message) {
    if ($env:OS -ne 'Windows_NT') { return }
    try {
        if ($message.Length -gt 200) { $message = $message.Substring(0, 200) + '…' }
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $icon = New-Object -TypeName 'System.Windows.Forms.NotifyIcon'
        $icons = 'System.Drawing.SystemIcons' -as [type]
        $icon.Icon = $icons::Information
        $icon.Visible = $true
        $icon.ShowBalloonTip(15000, '勘太郎の移し係', $message, 'Info')
        Start-Sleep -Seconds 8
        $icon.Dispose()
    } catch { }
}

function Get-MoverState {
    if (Test-Path -LiteralPath $MoverState) { return ([string](Get-Content -LiteralPath $MoverState -Raw)).Trim() }
    return ''
}

function Set-MoverState([string]$state) {
    try { [IO.File]::WriteAllText($MoverState, $state) } catch { }
}

# うまくいかない: 記録して終わる。
# 状態（state.txt）: ok / wait はじめて失敗した時刻 / ng（知らせ済み）。
# 15分以上続いたときだけ、1回知らせる（ログオン直後にパソコン版Googleドライブが起動するまでの間や、
# ネットワークが少し切れただけでは知らせない）
function Stop-WithError([string]$message) {
    Write-MoverLog ('エラー: ' + $message)
    if (-not $Check) {
        $state = Get-MoverState
        if ($state -eq 'ng') {
            # もう知らせた
        } elseif ($state -match '^wait (\d+)$') {
            if (((Get-Date) - (New-Object DateTime ([long]$matches[1]))).TotalMinutes -ge 15) {
                Show-MoverNotice $message
                Set-MoverState 'ng'
            }
        } else {
            Set-MoverState ('wait ' + (Get-Date).Ticks)
        }
    }
    exit 1
}

function Set-MoverRecovered {
    if ($Check) { return }
    $state = Get-MoverState
    if ($state -eq 'ng') {
        Write-MoverLog '元にもどりました'
        Show-MoverNotice '元にもどりました。勘太郎のフォルダへ渡せています'
    } elseif ($state -like 'wait *') {
        Write-MoverLog '元にもどりました'
    }
    if ($state -ne 'ok') { Set-MoverState 'ok' }
}

function Read-MoverConfig([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

# 同じ名前があれば _2、_3 … を付けた、空いている名前
function Get-UniqueName([string]$dir, [string]$name) {
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

# Googleドライブの「三映CSV連携\2_勘太郎用」を探す。
# ドライブの文字（G: など）や「マイドライブ」「My Drive」の違い、ミラーリング（ユーザーのフォルダの中）でも見つける
function Find-KantaroSource([string[]]$roots) {
    if (-not $roots) {
        $roots = @()
        if ($env:USERPROFILE) { $roots += $env:USERPROFILE }   # ミラーリング（ユーザーのフォルダの中）
        try {
            foreach ($d in [IO.DriveInfo]::GetDrives()) {
                try { if ($d.IsReady) { $roots += $d.RootDirectory.FullName } } catch { }
            }
        } catch { }
    }
    foreach ($root in $roots) {
        # 読めないドライブ（CD・切れたネットワークドライブ・権限の無いフォルダなど）はとばして、探し続ける
        try {
            foreach ($top in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                $candidates = @($top.FullName)
                if ($top.Name -eq '共有ドライブ' -or $top.Name -eq 'Shared drives') {
                    $candidates += @(Get-ChildItem -LiteralPath $top.FullName -Directory -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.FullName })
                }
                foreach ($c in $candidates) {
                    try {
                        $path = Join-Path (Join-Path $c $ParentName) $OutName
                        if (Test-Path -LiteralPath $path -PathType Container) { return $path }
                    } catch { }
                }
            }
        } catch { }
    }
    return $null
}

# 設定に書いた場所があればそこ。無ければ（ドライブの文字が変わったときなど）探し直す
function Resolve-KantaroSource($config) {
    if ($config -and $config.source -and (Test-Path -LiteralPath ([string]$config.source) -PathType Container)) {
        return [string]$config.source
    }
    return Find-KantaroSource
}

# 勘太郎のフォルダに書き込めるか: 'ok' / 'つながりません' / '書き込めません'
function Test-KantaroDest([string]$dest) {
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) { return 'つながりません' }
    $probe = Join-Path $dest ('.kantaro-mover-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
    try {
        [IO.Directory]::CreateDirectory($probe) | Out-Null
        [IO.Directory]::Delete($probe)
        return 'ok'
    } catch {
        return '書き込めません'
    }
}

# 1つのファイルを渡す。うまくいけば $true（うまくいかなければドライブに残し、次の回にやり直す）
function Send-KantaroFile([IO.FileInfo]$file, [string]$dest, [string]$doneDir) {
    $target = Get-UniqueName $dest $file.Name
    $tmp = Join-Path $dest ('.' + $target + '.tmp')
    try {
        Copy-Item -LiteralPath $file.FullName -Destination $tmp -Force
        $copied = (Get-Item -LiteralPath $tmp -Force).Length
        if ($copied -ne $file.Length) { throw ('コピーが途中で切れました（' + $copied + ' / ' + $file.Length + ' バイト）') }
        Rename-Item -LiteralPath $tmp -NewName $target
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-MoverLog ('エラー: ' + $file.Name + ' を勘太郎のフォルダへコピーできませんでした（次の回にやり直します）: ' + $_.Exception.Message)
        return $false
    }
    try {
        [IO.Directory]::CreateDirectory($doneDir) | Out-Null
        Move-Item -LiteralPath $file.FullName -Destination (Join-Path $doneDir (Get-UniqueName $doneDir $file.Name))
    } catch {
        Write-MoverLog ('注意: ' + $file.Name + ' は渡しましたが「' + $DoneName + '」へ移せませんでした。二度渡さないよう、ドライブで手で移してください: ' + $_.Exception.Message)
        Show-MoverNotice ($file.Name + ' は渡しましたが「' + $DoneName + '」へ移せませんでした。二度渡さないよう、手で移してください')
    }
    Write-MoverLog ('渡しました: ' + $file.Name + ' → ' + $target)
    return $true
}

if ($LoadOnly) { return }

# ---------------- ここから ----------------

# 前の回がまだ動いていれば何もしない
$mutex = New-Object System.Threading.Mutex($false, 'Local\kantaro-mover')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    if ((Test-Path -LiteralPath $MoverLog) -and (Get-Item -LiteralPath $MoverLog).Length -gt 1MB) {
        Move-Item -LiteralPath $MoverLog -Destination ($MoverLog + '.1') -Force
    }

    $config = Read-MoverConfig $MoverConfig
    if (-not $config -or -not $config.destination) {
        Stop-WithError ('設定がありません（' + $MoverConfig + '）。setup_kantaro_mover.bat をもう一度実行してください')
    }
    $dest = [string]$config.destination
    $src = Resolve-KantaroSource $config
    if (-not $src) {
        Stop-WithError ('Googleドライブの「' + $ParentName + '\' + $OutName + '」が見つかりません。パソコン版Googleドライブが動いていて、ログインしているか確かめてください')
    }
    $doneDir = Join-Path (Split-Path -Parent $src) $DoneName
    $files = @(Get-ChildItem -LiteralPath $src -File -Filter '*.csv' | Sort-Object Name)

    if ($Check) {
        Write-Host ('Googleドライブ: ' + $src)
        $state = Test-KantaroDest $dest
        if ($state -eq 'ok') { $state = '書き込めます' }
        Write-Host ('勘太郎のフォルダ: ' + $dest + '（' + $state + '）')
        Write-Host ('渡すファイル: ' + $files.Count + ' 件')
        foreach ($f in $files) { Write-Host ('  - ' + $f.Name) }
        exit 0
    }

    # 渡すものが無ければ、勘太郎のフォルダには触らない
    if ($files.Count -eq 0) {
        Set-MoverRecovered
        exit 0
    }
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) {
        Stop-WithError ('勘太郎のフォルダ（' + $dest + '）につながりません。勘太郎のパソコンの電源とネットワークを確かめてください。ファイルはドライブに残し、次の回に渡します')
    }
    $errors = 0
    foreach ($f in $files) {
        if (-not (Send-KantaroFile $f $dest $doneDir)) { $errors++ }
    }
    if ($errors -gt 0) {
        Stop-WithError ([string]$errors + ' 件を渡せませんでした（ドライブに残し、次の回にやり直します）')
    }
    Set-MoverRecovered
    exit 0
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
