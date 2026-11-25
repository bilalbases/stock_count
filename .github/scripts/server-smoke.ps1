# Smoke test for local-server/StockCountServer.ps1 (runs on the Linux build machine with pwsh).
# Two PDTs upload ~2,500 lines each; both must be answered within seconds, and the worker must
# then write the PI files in the background.
$ErrorActionPreference = 'Stop'
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('scs-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item local-server/StockCountServer.ps1 $dir
Set-Content -Path (Join-Path $dir 'key.txt') -Value 'testkey'
$server = Start-Process pwsh -ArgumentList '-NoProfile', '-File', (Join-Path $dir 'StockCountServer.ps1') -PassThru
try {
    Start-Sleep -Seconds 8
    foreach ($dev in 'PDT-A', 'PDT-B') {
        $rows = foreach ($i in 1..2500) {
            @{ line = $i; scannedAt = '24.11.2026 07:00:00'; scannedMs = 1764000000000 + $i; planDate = '24.11.2026'; plant = '1010'
               storageLoc = '1001'; shelf = 'A1'; material = [string](100000 + ($i % 700)); barcode = '629' + $i; description = "Item $i"
               stockType = 'SALES LOCATION'; quantity = '2'; uom = 'EA'; countedQty = '2'; countedUom = 'EA'; zeroCount = $false }
        }
        $body = @{ key = 'testkey'; device = $dev; rows = @($rows) } | ConvertTo-Json -Depth 5 -Compress
        $t = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-RestMethod -Method Post -Uri 'http://localhost:8080/upload' -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
        Write-Host "$dev answered in $([math]::Round($t.Elapsed.TotalSeconds, 1)) s: ok=$($r.ok) rows=$($r.rows)"
        if (-not $r.ok -or $r.rows -ne 2500) { throw "Upload from $dev failed" }
        if ($t.Elapsed.TotalSeconds -gt 20) { throw "Upload from $dev took too long" }
    }
    $page = Invoke-WebRequest -Uri 'http://localhost:8080/' -TimeoutSec 30 -UseBasicParsing
    Write-Host "Status page: $($page.StatusCode)"
    $deadline = (Get-Date).AddMinutes(8)
    do { Start-Sleep -Seconds 5; $done = Select-String -Path (Join-Path $dir 'server.log') -Pattern 'Files updated with' -Quiet } until ($done -or (Get-Date) -gt $deadline)
    Get-Content (Join-Path $dir 'server.log') | Write-Host
    Get-ChildItem -Recurse $dir | ForEach-Object { Write-Host $_.FullName }
    if (-not $done) { throw 'The worker did not update the files' }
} finally {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
}
