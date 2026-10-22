# inject_lib.ps1 — font table model, slot planning, custom encoding, glyph render/write.
# Dot-source:  . <项目根>\tools\inject_lib.ps1
# Depends: System.Drawing (GDI) for glyph rendering.
$ErrorActionPreference = "Stop"
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch {}
Add-Type -AssemblyName System.Drawing

$script:SJIS = [System.Text.Encoding]::GetEncoding(932)
$script:FONT_W = 1024
$script:FONT_PXOFF = 0x3E
$script:SjisRunPat = [System.Text.RegularExpressions.Regex]::new('(?:[\x81-\x9F\xE0-\xFC][\x40-\x7E\x80-\xFC]){2,}', 'Compiled')

# y-ranges of the 53 glyph rows in 00006.bmp (from capacity analysis)
$script:FONT_BANDS = @(
    (1,24),(28,50),(53,75),(81,103),(105,129),(131,154),(157,180),(183,206),
    (210,285),(287,311),(314,336),(340,361),(366,387),(392,413),(418,439),
    (444,465),(470,491),(496,517),(522,543),(548,569),(574,595),(600,621),
    (626,647),(652,673),(678,699),(704,725),(730,751),(756,777),(782,803),
    (808,829),(834,855),(860,881),(886,907),(912,933),(938,959),(964,985),
    (990,1011),(1016,1037),(1042,1063),(1068,1089),(1094,1115),(1120,1141),
    (1146,1167),(1172,1193),(1198,1219),(1224,1245),(1250,1271),(1276,1297),
    (1302,1323),(1328,1349),(1354,1374)
)

function Get-RowY([int]$r) {
    if ($r -le 7) { return $script:FONT_BANDS[$r][0] }
    if ($r -le 10) { return $script:FONT_BANDS[8][0] + ($r - 8) * 25 }
    return $script:FONT_BANDS[9 + ($r - 11)][0]
}

function Get-RowH([int]$r) {
    if ($r -le 7) { return $script:FONT_BANDS[$r][1] - $script:FONT_BANDS[$r][0] + 1 }
    if ($r -le 10) { return 25 }
    $b = $script:FONT_BANDS[9 + ($r - 11)]
    return $b[1] - $b[0] + 1
}

function Read-FontTable([string]$path) {
    $data = [System.IO.File]::ReadAllBytes($path)
    $rows = New-Object 'System.Collections.Generic.List[int[]]'
    $cur = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0; $i + 1 -lt $data.Length; $i += 2) {
        $code = (([int]$data[$i]) -shl 8) -bor ([int]$data[$i + 1])
        if ($code -eq 0x0D0A) { $rows.Add($cur.ToArray()); $cur.Clear() }
        else { [void]$cur.Add($code) }
    }
    if ($cur.Count -gt 0) { $rows.Add($cur.ToArray()) }
    return ,$rows
}

function Write-FontTable($rows, [string]$path) {
    $ms = New-Object System.IO.MemoryStream
    foreach ($row in $rows) {
        foreach ($c in $row) {
            [void]$ms.WriteByte([byte](($c -shr 8) -band 0xFF))
            [void]$ms.WriteByte([byte]($c -band 0xFF))
        }
        [void]$ms.WriteByte(0x0D); [void]$ms.WriteByte(0x0A)
    }
    [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
}

# ---------- retained codes ----------
$script:TalkPat = [regex]'talk\(\s*("(?:[^"\\]|\\.)*"|null)\s*,\s*("[^"]*"|null)\s*,\s*("(?:[^"\\]|\\.)*")\s*,\s*([^)]*)\)'

function Get-DbCodes([byte[]]$bytes) {
    $list = New-Object 'System.Collections.Generic.List[int]'
    $i = 0
    while ($i -lt $bytes.Length) {
        $b = [int]$bytes[$i]
        if ($b -lt 0x80) { $i++; continue }
        if ($i + 1 -lt $bytes.Length) {
            $t = [int]$bytes[$i + 1]
            $isLead = ($b -ge 0x81 -and $b -le 0x9F) -or ($b -ge 0xE0 -and $b -le 0xFC)
            $isTrail = ($t -ge 0x40 -and $t -le 0x7E) -or ($t -ge 0x80 -and $t -le 0xFC)
            if ($isLead -and $isTrail) { $list.Add((($b -shl 8) -bor $t)); $i += 2; continue }
        }
        $i++
    }
    return $list.ToArray()
}

function Test-TextLike([byte[]]$raw) {
    if ($raw.Length -eq 0) { return $false }
    if ($raw.Length -ge 4 -and $raw[0] -eq 0x54 -and $raw[1] -eq 0x49 -and $raw[2] -eq 0x4D -and $raw[3] -eq 0x32) { return $false }   # "TIM2"
    $bad = 0
    foreach ($b in $raw) {
        $v = [int]$b
        if ($v -eq 9 -or $v -eq 10 -or $v -eq 13) { continue }
        if ($v -lt 0x20 -or $v -eq 0x7F) { $bad++ }
    }
    if (($bad / $raw.Length) -ge 0.01) { return $false }
    # strict SJIS decode: real text never throws; image data usually does
    try {
        $strict = [System.Text.Encoding]::GetEncoding(932, [System.Text.EncoderFallback]::ExceptionFallback, [System.Text.DecoderFallback]::ExceptionFallback)
        [void]$strict.GetString($raw)
    } catch { return $false }
    return $true
}

function Get-RetainedCodes([string]$sceneDir, [string]$normalDir, [string[]]$TranslatedScenes = $null, [hashtable]$SysMap = $null, [string]$TransDir = $null, [hashtable]$Speakers = $null, [hashtable]$BattleMap = $null) {
    # codes that must keep their glyph: SCENE_ID scripts (minus talk arg3 = dialogue
    # being replaced, ONLY for lines whose translation is actually Chinese; arg2 speaker
    # names masked when speakers.tsv replaces them) + NORMAL text-like files.
    # SysMap strings are globally replaced and their glyphs may be freed.
    # Per-line rule: a talk line whose zh (from <TransDir>\<sid>.tsv) still contains kana
    # stays Japanese in-game -> its codes MUST be retained. Lines without tsv entry = Japanese.
    $trans = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($TranslatedScenes) { foreach ($s in $TranslatedScenes) { [void]$trans.Add($s) } }
    $sysPairs = @()
    if ($SysMap -and $SysMap.Count -gt 0) {
        $sysPairs = $SysMap.Keys | Sort-Object { -$_.Length } | ForEach-Object { ,@('"' + $_ + '"') }
    }
    if ($Speakers -and $Speakers.Count -gt 0) {
        $sysPairs += $Speakers.Keys | Sort-Object { -$_.Length } | ForEach-Object { ,@('"' + $_ + '"') }
    }
    $ret = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($f in [System.IO.Directory]::GetFiles($sceneDir, "*.nut")) {
        $sid = [System.IO.Path]::GetFileNameWithoutExtension($f)
        $text = $script:SJIS.GetString([System.IO.File]::ReadAllBytes($f))
        if ($sysPairs.Count -gt 0) { foreach ($sp in $sysPairs) { $text = $text.Replace($sp[0], '""') } }
        if (-not $trans.Contains($sid)) {
            # scene stays Japanese: keep ALL its codes
            foreach ($c in (Get-DbCodes ($script:SJIS.GetBytes($text)))) { [void]$ret.Add($c) }
            continue
        }
        # per-line: mask only talk args replaced by real Chinese
        $lineZh = $null
        if ($TransDir) {
            $tsv = Join-Path $TransDir ($sid + ".tsv")
            if (Test-Path $tsv) {
                $lineZh = @{}
                foreach ($ln in [System.IO.File]::ReadAllLines($tsv, [System.Text.Encoding]::UTF8)) {
                    if ($ln -eq "") { continue }
                    $p = $ln -split "`t", 3
                    if ($p.Count -eq 3) { $lineZh[$p[0]] = $p[2] }
                }
            }
        }
        $kept = New-Object 'System.Text.StringBuilder'
        $pos = 0
        $mi = 0
        foreach ($m in $script:TalkPat.Matches($text)) {
            $seg = $text.Substring($pos, $m.Groups[3].Index - $pos)
            $isZh = $false
            if ($lineZh -and $lineZh.ContainsKey([string]$mi)) {
                $zh = $lineZh[[string]$mi]
                # U+30FB (・) is legit in zh name separators — not kana
                if ($zh -notmatch '[\u3040-\u309F\u30A0-\u30FA\u30FC-\u30FF]') { $isZh = $true }
            }
            if (-not $isZh) {
                [void]$kept.Append($seg)
                [void]$kept.Append($m.Groups[3].Value)   # japanese line: keep codes
            } else {
                # translated line: speaker name (arg1) also replaced by text_inject -> drop its codes
                $g1 = $m.Groups[1].Value
                if ($Speakers -and $g1 -and $g1 -ne "null" -and $g1.Length -ge 2 -and $Speakers.ContainsKey($g1.Substring(1, $g1.Length - 2))) {
                    $g1i = $m.Groups[1]
                    $seg = $text.Substring($pos, $g1i.Index - $pos) + $text.Substring($g1i.Index + $g1i.Length, $m.Groups[3].Index - ($g1i.Index + $g1i.Length))
                }
                [void]$kept.Append($seg)
            }
            $pos = $m.Groups[3].Index + $m.Groups[3].Length
            $mi++
        }
        [void]$kept.Append($text.Substring($pos))
        foreach ($c in (Get-DbCodes ($script:SJIS.GetBytes($kept.ToString())))) { [void]$ret.Add($c) }
    }
    foreach ($f in [System.IO.Directory]::GetFiles($normalDir)) {
        $name = [System.IO.Path]::GetFileName($f)
        $ext = [System.IO.Path]::GetExtension($f)
        if ($ext -in ".png", ".bmp", ".tm2") { continue }
        if ($name.StartsWith("00005") -or $name.StartsWith("00006")) { continue }
        $raw = [System.IO.File]::ReadAllBytes($f)
        if ($raw.Length -eq 0) { continue }
        if ($name -eq "00068.bin" -or $name -eq "00070.bin") {
            # battle data: retain codes of SJIS runs NOT replaced by battle_map
            if ($BattleMap -and $BattleMap.Count -gt 0) {
                $latin1 = [System.Text.Encoding]::GetEncoding(28591)
                $s = $latin1.GetString($raw)
                foreach ($m in $script:SjisRunPat.Matches($s)) {
                    $run = $script:SJIS.GetString($latin1.GetBytes($m.Value))
                    if ($BattleMap.ContainsKey($run)) { continue }
                    foreach ($c in (Get-DbCodes ($latin1.GetBytes($m.Value)))) { [void]$ret.Add($c) }
                }
            }
            continue
        }
        if (Test-TextLike $raw) {
            foreach ($c in (Get-DbCodes $raw)) { [void]$ret.Add($c) }
        }
    }
    return $ret
}

# ---------- slot plan ----------
function New-SlotPlan($tableRows, $retained) {
    # freeable slots: table codes not in retained; grid holes: rows shorter than 42
    $slots = New-Object 'System.Collections.Generic.List[object]'
    for ($r = 0; $r -lt $tableRows.Count; $r++) {
        $row = $tableRows[$r]
        for ($c = 0; $c -lt $row.Count; $c++) {
            if (-not $retained.Contains($row[$c])) {
                $slots.Add([pscustomobject]@{ Row = $r; Col = $c; Kind = 'freed' })
            }
        }
        for ($c = $row.Count; $c -lt 42; $c++) {
            $slots.Add([pscustomobject]@{ Row = $r; Col = $c; Kind = 'grid' })
        }
    }
    return ,$slots
}

# ---------- encoding ----------
$script:LEAD = @(0x81..0x9F) + @(0xE0..0xEA)
$script:TRAIL = @(0x40..0x7E) + @(0x80..0xFC)

function New-Encoding([string[]]$chars, [System.Collections.Generic.HashSet[int]]$avoid) {
    # assign each char a unique valid SJIS pair not in avoid (all original table codes)
    $used = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($c in $avoid) { [void]$used.Add($c) }
    $map = @{}
    foreach ($ch in $chars) {
        if ($map.ContainsKey($ch)) { continue }
        $found = 0
        foreach ($lead in $script:LEAD) {
            if ($found) { break }
            foreach ($trail in $script:TRAIL) {
                $code = ($lead -shl 8) -bor $trail
                if (-not $used.Contains($code)) {
                    [void]$used.Add($code)
                    $map[$ch] = $code
                    $found = $code
                    break
                }
            }
        }
        if (-not $found) { throw "code space exhausted at char $ch" }
    }
    return $map
}

# ---------- font bitmap ----------
function Read-FontBmp([string]$path) {
    $data = [System.IO.File]::ReadAllBytes($path)
    $w = [BitConverter]::ToInt32($data, 0x12)
    $hRaw = [BitConverter]::ToInt32($data, 0x16)
    $h = [Math]::Abs($hRaw)
    $rowBytes = [Math]::Floor((($w + 31) / 32)) * 4
    return @{ Data = $data; W = $w; H = $h; HRaw = $hRaw; RowBytes = $rowBytes; PxOff = $script:FONT_PXOFF }
}

function Set-FontPixel($bmp, [int]$x, [int]$y, [int]$v) {
    $srcY = if ($bmp.HRaw -gt 0) { $bmp.H - 1 - $y } else { $y }
    $idx = $bmp.PxOff + $srcY * $bmp.RowBytes + [Math]::Floor($x / 8)
    $bit = 7 - ($x % 8)
    if ($v) { $bmp.Data[$idx] = $bmp.Data[$idx] -bor (1 -shl $bit) }
    else { $bmp.Data[$idx] = $bmp.Data[$idx] -band (-bnot (1 -shl $bit)) -band 0xFF }
}

function Write-Glyph($bmp, [int]$row, [int]$col, [string]$ch, [string]$fontName = "Microsoft YaHei") {
    # Render on a fixed 32x32 canvas with UNIFORM font size for all rows,
    # then crop the center 24px-wide region. This ensures every glyph shares
    # the same baseline and visual size, fixing "一上一下" and size mismatch.
    $x0 = 1 + $col * 24
    $y0 = Get-RowY $row
    $cw = 24
    $chh = Get-RowH $row
    for ($y = 0; $y -lt $chh; $y++) {
        for ($x = 0; $x -lt $cw; $x++) { Set-FontPixel $bmp ($x0 + $x) ($y0 + $y) 0 }
    }
    $canvas = 32
    $fs = 21
    $size = New-Object System.Drawing.Bitmap($canvas, $canvas)
    $g = [System.Drawing.Graphics]::FromImage($size)
    $g.Clear([System.Drawing.Color]::White)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $font = New-Object System.Drawing.Font($fontName, $fs, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rectF = New-Object System.Drawing.RectangleF(0, 0, $canvas, $canvas)
    $g.DrawString($ch, $font, [System.Drawing.Brushes]::Black, $rectF, $sf)
    $cropX = ($canvas - $cw) / 2
    $cropY = ($canvas - $cw) / 2
    $rectData = New-Object System.Drawing.Rectangle(0, 0, $canvas, $canvas)
    $px = $size.LockBits($rectData, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $stride = $px.Stride
    $buf = New-Object byte[] ($stride * $canvas)
    [System.Runtime.InteropServices.Marshal]::Copy($px.Scan0, $buf, 0, $buf.Length)
    $size.UnlockBits($px)
    for ($y = 0; $y -lt $chh; $y++) {
        for ($x = 0; $x -lt $cw; $x++) {
            $sx = [int]$cropX + $x
            $sy = [int]$cropY + $y
            if ($sx -ge 0 -and $sx -lt $canvas -and $sy -ge 0 -and $sy -lt $canvas) {
                $o = $sy * $stride + $sx * 3
                $gray = ($buf[$o] + $buf[$o + 1] + $buf[$o + 2]) / 3
                if ($gray -lt 128) { Set-FontPixel $bmp ($x0 + $x) ($y0 + $y) 1 }
            }
        }
    }
    $g.Dispose(); $size.Dispose(); $font.Dispose()
}

function Save-FontBmp($bmp, [string]$path) {
    [System.IO.File]::WriteAllBytes($path, $bmp.Data)
}

# ---------- text encoding for scripts ----------
function ConvertTo-GameBytes([string]$text, [hashtable]$encMap) {
    # ASCII passthrough; custom-mapped chars -> 2-byte code; rest -> Shift-JIS
    $out = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($c in $text.ToCharArray()) {
        $o = [int]$c
        if ($o -lt 0x80) { $out.Add([byte]$o) }
        elseif ($encMap.ContainsKey([string]$c)) {
            $code = $encMap[[string]$c]
            $out.Add([byte](($code -shr 8) -band 0xFF))
            $out.Add([byte]($code -band 0xFF))
        } else {
            try {
                $b = $script:SJIS.GetBytes([string]$c)
                foreach ($bb in $b) { $out.Add($bb) }
            } catch {
                throw "unencodable char: [$([int]$c)] $c"
            }
        }
    }
    return $out.ToArray()
}
