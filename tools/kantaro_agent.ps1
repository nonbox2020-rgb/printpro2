# 勘太郎パソコンの受け取り係
#
# 変換アプリが出力した勘太郎CSV（未取込）を受け取り、勘太郎の指定フォルダへ入れる。
# 入れ終わったらアプリに知らせる → アプリの画面で「取込済」に移る。
# タスクスケジューラで数分おき（1〜5分）に実行する（設定方法は README の「勘太郎パソコンの受け取り係」）。
#
# 設定: 同じフォルダの kantaro_agent.config.json（見本: kantaro_agent.config.sample.json）
# ログ: 同じフォルダの kantaro_agent.log
# このファイルは UTF-8（BOM付き）で保存すること（Windows PowerShell 5.1 が日本語を正しく読むため）。

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $here 'kantaro_agent.log'
$ledgerPath = Join-Path $here 'kantaro_agent.delivered.txt'   # 入れ終わったファイルの控え（二重に入れないため）

function Write-Log([string]$msg) {
    Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ('{0:yyyy/MM/dd HH:mm:ss} {1}' -f (Get-Date), $msg)
}

try {
    $cfg = Get-Content -LiteralPath (Join-Path $here 'kantaro_agent.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $base = $cfg.app_url.TrimEnd('/')
    $dest = $cfg.dest_folder
    $headers = @{ Authorization = 'Bearer ' + $cfg.token }
    # Render は TLS 1.2 以上。古い既定のままだと Windows PowerShell 5.1 がつながらない
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Test-Path -LiteralPath $dest -PathType Container)) {
        throw "指定フォルダが見つかりません: $dest"
    }

    # 未取込の一覧（日本語のファイル名が化けないよう、UTF-8 として読む）
    $res = Invoke-WebRequest -Uri "$base/api/agent/files" -Headers $headers -UseBasicParsing -TimeoutSec 120
    $list = [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray()) | ConvertFrom-Json

    $delivered = @{}
    if (Test-Path -LiteralPath $ledgerPath) {
        foreach ($line in (Get-Content -LiteralPath $ledgerPath -Encoding UTF8)) { $delivered[$line] = $true }
    }

    foreach ($f in $list.files) {
        # 出力1回ごとに id が違うので、同じ中身をもう一度出力した場合も新しいファイルとして届ける
        $key = $f.name + ' ' + $f.id + ' ' + $f.sha256
        $enc = [Uri]::EscapeDataString($f.name)
        if (-not $delivered.ContainsKey($key)) {
            # 途中のファイルを勘太郎に読まれないよう、別の名前で受け取ってから名前を変える
            $tmp = Join-Path $dest ($f.name + '.part')
            Invoke-WebRequest -Uri "$base/api/agent/files/$enc" -Headers $headers -UseBasicParsing -TimeoutSec 120 -OutFile $tmp
            $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
            if ($hash -ne $f.sha256) {
                Remove-Item -LiteralPath $tmp
                throw "受け取ったファイルが壊れています（次回もう一度受け取ります）: $($f.name)"
            }
            # 同じ名前がまだ残っていたら上書きしない（_2, _3 … を付ける）
            $name = $f.name
            $n = 1
            while (Test-Path -LiteralPath (Join-Path $dest $name)) {
                $n++
                $name = [IO.Path]::GetFileNameWithoutExtension($f.name) + "_$n" + [IO.Path]::GetExtension($f.name)
            }
            Move-Item -LiteralPath $tmp -Destination (Join-Path $dest $name)
            if ($cfg.write_done) {
                Set-Content -LiteralPath (Join-Path $dest ($name + '.done')) -Value (Get-Date -Format o)
            }
            Add-Content -LiteralPath $ledgerPath -Encoding UTF8 -Value $key
            Write-Log "受け取り: $($f.name) → $name"
        }
        # アプリに「受け取った」と知らせる。失敗しても次回もう一度知らせるだけで、ファイルは二重に入れない
        Invoke-WebRequest -Method Post -Uri "$base/api/agent/files/$enc/taken" -Headers $headers -UseBasicParsing -TimeoutSec 60 | Out-Null
    }
}
catch {
    Write-Log ('エラー: ' + $_.Exception.Message)
    exit 1
}
