<#
  Stock Count - local collector (Windows, no internet needed)
  -----------------------------------------------------------
  The PDTs upload their counts here (app: menu > Upload to server). Each upload REPLACES that
  device's rows, so corrections are never counted twice. After every upload the server rebuilds
  one locked Excel file per branch in the Output folder:

      Output\Stock_Count_<year>_<branch>.xlsx      (PI template layout, ready for SAP)
      Output\Stock_Count_Log_<year>_<branch>.xlsx  (log: every scan as its own line, in scan order)

  Open http://<this PC>:8080 in a browser to see which PDTs have uploaded and download the files.

  Install once with Install.cmd (runs as administrator). It starts automatically with Windows.
#>

$Port   = 8080
$Here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Data   = Join-Path $Here 'data\devices'
$Arch   = Join-Path $Here 'data\archive'
$Out    = Join-Path $Here 'Output'
$LogF   = Join-Path $Here 'server.log'
$KeyF   = Join-Path $Here 'key.txt'
$Inv    = [System.Globalization.CultureInfo]::InvariantCulture
$Utf8   = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Web
foreach ($d in @($Data, $Arch, $Out)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

function Log($msg) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg
    Add-Content -Path $LogF -Value $line -Encoding UTF8
}
function Get-Key { if (Test-Path $KeyF) { (Get-Content $KeyF -Raw).Trim() } else { '' } }
function Esc([string]$s) {
    if ($null -eq $s) { return '' }
    $s = $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
    return ($s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
}
function Safe-Name([string]$s) { ($s -replace '[^A-Za-z0-9_-]', '-').Trim('-') }
function To-Dec($v) {
    $d = [decimal]0
    if ($null -ne $v -and [decimal]::TryParse(([string]$v).Replace(',', '.'), [System.Globalization.NumberStyles]::Number, $Inv, [ref]$d)) { return $d }
    return [decimal]0
}
function Fmt-Dec([decimal]$d) { $s = $d.ToString('0.######', $Inv); if ($s -eq '-0') { '0' } else { $s } }

# Excel's legacy 16-bit protection hash (locks the sheet with a random, unstored password)
function Legacy-Hash([string]$pw) {
    $h = 0
    $chars = $pw.ToCharArray(); [array]::Reverse($chars)
    foreach ($c in $chars) {
        $h = (($h -shr 14) -band 1) -bor (($h -shl 1) -band 0x7fff)
        $h = $h -bxor [int]$c
    }
    $h = (($h -shr 14) -band 1) -bor (($h -shl 1) -band 0x7fff)
    $h = $h -bxor $pw.Length -bxor 0xCE4B
    return ('{0:X4}' -f $h)
}
function Random-Password {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $b = New-Object byte[] 15; $rng.GetBytes($b)
    return -join ($b | ForEach-Object { $chars[$_ % $chars.Length] })
}

# Writes a locked .xlsx (same layout as the app's export). $rows = list of string arrays.
function Write-Xlsx([string]$path, $header, $rows, $textCols = @(6), $widths = @(12, 12, 10, 10, 10, 10, 16, 12, 12, 12, 13)) {
    $lock = Legacy-Hash (Random-Password)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols>')
    for ($c = 0; $c -lt $widths.Count; $c++) { [void]$sb.Append("<col min=`"$($c + 1)`" max=`"$($c + 1)`" width=`"$($widths[$c])`" customWidth=`"1`"/>") }
    [void]$sb.Append('</cols><sheetData>')
    $all = @(,$header) + $rows
    $letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    for ($r = 0; $r -lt $all.Count; $r++) {
        [void]$sb.Append("<row r=`"$($r + 1)`">")
        $row = $all[$r]
        for ($c = 0; $c -lt $row.Count; $c++) {
            $v = [string]$row[$c]
            if ($v -eq '') { continue }
            $ref = "$($letters[$c])$($r + 1)"
            $style = 0; if ($r -eq 0) { $style = 1 }
            # Codes (material, barcode, shelf) always stay text so long codes keep every digit
            if ($r -gt 0 -and $textCols -notcontains $c -and $v -match '^-?\d{1,9}(\.\d+)?$') {
                [void]$sb.Append("<c r=`"$ref`" s=`"$style`"><v>$v</v></c>")
            } else {
                [void]$sb.Append("<c r=`"$ref`" s=`"$style`" t=`"inlineStr`"><is><t>$(Esc $v)</t></is></c>")
            }
        }
        [void]$sb.Append('</row>')
    }
    [void]$sb.Append('</sheetData>')
    [void]$sb.Append("<sheetProtection password=`"$lock`" sheet=`"1`" objects=`"1`" scenarios=`"1`" formatCells=`"1`" formatColumns=`"1`" formatRows=`"1`" insertColumns=`"1`" insertRows=`"1`" insertHyperlinks=`"1`" deleteColumns=`"1`" deleteRows=`"1`" sort=`"1`" autoFilter=`"1`" pivotTables=`"1`"/></worksheet>")

    $parts = [ordered]@{
        '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>'
        '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
        'xl/workbook.xml' = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><workbook xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`" xmlns:r=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships`"><workbookProtection lockStructure=`"1`" lockWindows=`"1`" workbookPassword=`"$lock`"/><sheets><sheet name=`"Sheet1`" sheetId=`"1`" r:id=`"rId1`"/></sheets></workbook>"
        'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
        'xl/styles.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyProtection="1"><protection locked="1" hidden="0"/></xf><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyProtection="1"><protection locked="1" hidden="0"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'
        'xl/worksheets/sheet1.xml' = $sb.ToString()
    }
    $tmp = "$path.tmp"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    $fs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    foreach ($name in $parts.Keys) {
        $e = $zip.CreateEntry($name)
        $w = New-Object System.IO.StreamWriter($e.Open(), $Utf8)
        $w.Write($parts[$name]); $w.Close()
    }
    $zip.Dispose(); $fs.Close()
    Move-Item -Path $tmp -Destination $path -Force   # fails only if the file is open in Excel
}

# Rebuilds Output\Stock_Count_<year>_<branch>.xlsx from all device uploads.
function Rebuild {
    $now = Get-Date
    $today = $now.ToString('dd.MM.yyyy'); $year = $now.ToString('yyyy')
    $plants = @{}
    foreach ($f in Get-ChildItem -Path $Data -Filter *.json) {
        $up = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @($up.rows)) {
            if ($null -eq $r) { continue }
            $plant = [string]$r.plant
            if (-not $plants.ContainsKey($plant)) { $plants[$plant] = @{ plan = ''; groups = [ordered]@{}; log = New-Object System.Collections.ArrayList } }
            $p = $plants[$plant]
            if (-not $p.plan -and $r.planDate) { $p.plan = [string]$r.planDate }
            $mat = [string]$r.material; if (-not $mat) { $mat = [string]$r.barcode }
            $key = @([string]$r.storageLoc, $mat, [string]$r.stockType, [string]$r.uom) -join '|'
            if (-not $p.groups.Contains($key)) {
                $p.groups[$key] = @{ sloc = [string]$r.storageLoc; mat = $mat; type = [string]$r.stockType; uom = [string]$r.uom; qty = [decimal]0; zero = $false }
            }
            $g = $p.groups[$key]
            $g.qty += (To-Dec $r.quantity)
            $isZero = ($r.zeroCount -eq $true -or [string]$r.zeroCount -eq 'X')
            if ($isZero) { $g.zero = $true }
            # Log: every scanned line as it is, duplicates kept
            $ms = [long]0; if ($r.scannedMs) { $ms = [long]$r.scannedMs }
            $ln = [long]0; if ($r.line) { $ln = [long]$r.line }
            [void]$p.log.Add(@{ ms = $ms; line = $ln; dev = [string]$up.device; at = [string]$r.scannedAt; sloc = [string]$r.storageLoc
                shelf = [string]$r.shelf; bc = [string]$r.barcode; mat = $mat; desc = [string]$r.description; type = [string]$r.stockType
                cq = [string]$r.countedQty; cu = [string]$r.countedUom; qty = [string]$r.quantity; uom = [string]$r.uom; zero = $isZero })
        }
    }
    $header = @('DATE', 'PLAN_DATE', 'GJAHR', 'PLANT', 'STGE_LOC', 'ITEM', 'MATERIAL', 'STOCK_TYPE', 'ENTRY_QNT', 'ENTRY_UOM', 'ZERO_COUNT')
    $written = @()
    foreach ($plant in ($plants.Keys | Sort-Object)) {
        $p = $plants[$plant]
        $plan = $p.plan; if (-not $plan) { $plan = $today }
        $rows = New-Object System.Collections.ArrayList
        $i = 0
        foreach ($g in ($p.groups.Values | Sort-Object { $_.sloc }, { $_.mat })) {
            $i++
            $zero = ''; if ($g.zero -and $g.qty -eq 0) { $zero = 'X' }
            [void]$rows.Add(@($today, $plan, $year, $plant, $g.sloc, [string]$i, $g.mat, $g.type, (Fmt-Dec $g.qty), $g.uom, $zero))
        }
        $name = 'Stock_Count_' + $year + '_' + (Safe-Name $(if ($plant) { $plant } else { 'no-branch' })) + '.xlsx'
        try { Write-Xlsx (Join-Path $Out $name) $header $rows; $written += $name }
        catch { Log "Could not write $name (is it open in Excel?): $($_.Exception.Message)" }

        # Log file: one line per scan, in the order scanned (all PDTs together)
        $logRows = New-Object System.Collections.ArrayList
        $i = 0
        foreach ($l in ($p.log | Sort-Object { $_.ms }, { $_.dev }, { $_.line })) {
            $i++
            $zero = ''; if ($l.zero -and (To-Dec $l.qty) -eq 0) { $zero = 'X' }
            [void]$logRows.Add(@([string]$i, $l.at, $l.dev, $plant, $l.sloc, $l.shelf, $l.bc, $l.mat, $l.desc, $l.type, $l.cq, $l.cu, $l.qty, $l.uom, $zero))
        }
        $logHeader = @('NO', 'SCANNED_AT', 'DEVICE', 'PLANT', 'STGE_LOC', 'SHELF', 'BARCODE', 'MATERIAL', 'DESCRIPTION', 'STOCK_TYPE', 'COUNTED_QTY', 'COUNTED_UOM', 'ENTRY_QNT', 'ENTRY_UOM', 'ZERO_COUNT')
        $logName = 'Stock_Count_Log_' + $year + '_' + (Safe-Name $(if ($plant) { $plant } else { 'no-branch' })) + '.xlsx'
        try { Write-Xlsx (Join-Path $Out $logName) $logHeader $logRows @(5, 6, 7) @(6, 20, 18, 8, 10, 10, 16, 14, 36, 11, 13, 13, 11, 11, 12); $written += $logName }
        catch { Log "Could not write $logName (is it open in Excel?): $($_.Exception.Message)" }
    }
    # Remove files of branches that no longer have counts
    foreach ($f in Get-ChildItem -Path $Out -Filter 'Stock_Count_*.xlsx') {
        if ($written -notcontains $f.Name) { try { Remove-Item $f.FullName -Force } catch {} }
    }
}

function Send($ctx, [int]$code, [string]$type, $bytes) {
    $res = $ctx.Response
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}
function Send-Json($ctx, $obj, [int]$code = 200) { Send $ctx $code 'application/json; charset=utf-8' ($Utf8.GetBytes(($obj | ConvertTo-Json -Compress))) }
function Send-Html($ctx, [string]$html) { Send $ctx 200 'text/html; charset=utf-8' ($Utf8.GetBytes($html)) }

function Status-Page([string]$note) {
    $dev = ''
    foreach ($f in (Get-ChildItem -Path $Data -Filter *.json | Sort-Object LastWriteTime -Descending)) {
        $up = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $branches = (@($up.rows) | ForEach-Object { $_.plant } | Sort-Object -Unique) -join ', '
        $dev += "<tr><td>$(Esc $up.device)</td><td>$(Esc $branches)</td><td>$(@($up.rows).Count)</td><td>$(Esc $up.uploadedAt)</td></tr>"
    }
    if (-not $dev) { $dev = '<tr><td colspan="4">No uploads yet</td></tr>' }
    $files = ''
    foreach ($f in (Get-ChildItem -Path $Out -Filter *.xlsx | Sort-Object Name)) {
        $files += "<li><a href=`"/files/$([uri]::EscapeDataString($f.Name))`">$(Esc $f.Name)</a> <small>($($f.LastWriteTime.ToString('dd.MM.yyyy HH:mm')))</small></li>"
    }
    if (-not $files) { $files = '<li>No files yet</li>' }
    $msg = ''; if ($note) { $msg = "<p class=`"note`">$(Esc $note)</p>" }
    return @"
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30"><title>Stock Count server</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222;max-width:900px}h1{color:#2E358F;margin-bottom:4px}
table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:6px 10px;text-align:left}th{background:#2E358F;color:#fff}
li{margin:6px 0}a{color:#2E358F;font-weight:600}.note{background:#e8f5e9;padding:8px 12px;border-radius:6px}
form{margin-top:28px;padding:12px;border:1px solid #f0c0c0;border-radius:6px;background:#fff8f8}small{color:#777}</style></head><body>
<h1>Stock Count server</h1><small>Updated $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss') &middot; refreshes every 30 s</small>$msg
<h2>PI files (one per branch)</h2><ul>$files</ul>
<h2>Uploads</h2><table><tr><th>Device</th><th>Branch</th><th>Items</th><th>Last upload</th></tr>$dev</table>
<form method="post" action="/clear"><b>Start a new count</b><br><small>Moves all uploads and files to data\archive (nothing is deleted).</small><br><br>
Password: <input type="password" name="key"> <button type="submit">Clear all counts</button></form>
</body></html>
"@
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
$listener.Start()
Log "Server started on port $Port"

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $req = $ctx.Request
        $path = $req.Url.AbsolutePath.TrimEnd('/')
        if ($req.HttpMethod -eq 'POST' -and ($path -eq '/upload' -or $path -eq '')) {
            $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd() | ConvertFrom-Json
            $key = Get-Key
            if (-not $key -or [string]$body.key -ne $key) { Send-Json $ctx @{ ok = $false; error = 'Wrong key' }; Log "Rejected upload from $($req.RemoteEndPoint): wrong key"; continue }
            $device = ([string]$body.device).Trim()
            if (-not $device) { Send-Json $ctx @{ ok = $false; error = 'Missing device name' }; continue }
            $rows = @(); if ($null -ne $body.rows) { $rows = @($body.rows) }
            $save = [ordered]@{ device = $device; uploadedAt = (Get-Date -Format 'dd.MM.yyyy HH:mm:ss'); rows = $rows }
            [System.IO.File]::WriteAllText((Join-Path $Data ((Safe-Name $device) + '.json')), ($save | ConvertTo-Json -Depth 6), $Utf8)
            Rebuild
            Log "Upload from $device ($($req.RemoteEndPoint)): $($rows.Count) items"
            Send-Json $ctx @{ ok = $true; rows = $rows.Count }
        }
        elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/clear') {
            $form = [System.Web.HttpUtility]::ParseQueryString((New-Object System.IO.StreamReader($req.InputStream)).ReadToEnd())
            $key = Get-Key
            if ($key -and $form['key'] -eq $key) {
                $dest = Join-Path $Arch (Get-Date -Format 'yyyy-MM-dd_HHmmss')
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                Get-ChildItem -Path $Data | Move-Item -Destination $dest -Force
                Get-ChildItem -Path $Out -Filter *.xlsx | Move-Item -Destination $dest -Force
                Log "All counts cleared (archived to $dest)"
                Send-Html $ctx (Status-Page "All counts cleared. Previous uploads and files are in $dest")
            } else {
                Send-Html $ctx (Status-Page 'Wrong password, nothing was cleared.')
            }
        }
        elseif ($req.HttpMethod -eq 'GET' -and $path -like '/files/*') {
            $name = Split-Path -Leaf ([uri]::UnescapeDataString($path.Substring(7)))
            $file = Join-Path $Out $name
            if ((Test-Path $file) -and $name -like '*.xlsx') {
                $ctx.Response.AddHeader('Content-Disposition', "attachment; filename=`"$name`"")
                Send $ctx 200 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' ([System.IO.File]::ReadAllBytes($file))
            } else { Send $ctx 404 'text/plain' ($Utf8.GetBytes('Not found')) }
        }
        elseif ($req.HttpMethod -eq 'GET') {
            Send-Html $ctx (Status-Page '')
        }
        else { Send $ctx 405 'text/plain' ($Utf8.GetBytes('Method not allowed')) }
    } catch {
        Log "Error: $($_.Exception.Message)"
        try { Send-Json $ctx @{ ok = $false; error = $_.Exception.Message } 500 } catch {}
    }
}
