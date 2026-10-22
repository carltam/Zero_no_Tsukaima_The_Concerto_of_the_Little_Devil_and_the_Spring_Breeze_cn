# build_all.ps1 — 零之使魔·协奏曲 中文化全自动构建管线（PowerShell 版）。
# 流程：还原原版文件 -> 扫描保留码 -> 生成编码+字库 -> 注入文本 -> 重打包 -> 重建 ISO -> 自校验。
# 所有路径均相对于本项目根目录（本脚本位于 <项目根>\tools\ 下），项目可整体拷贝迁移。
# Usage:
#   & <项目根>\tools\build_all.ps1 [-Smoke] [-OutDir ...] [-TransDir ...] [-FontPath ...] [-FontPx 22] [-PythonCmd python] [-SkipIso]
param(
    [switch]$Smoke,
    [string]$OutDir = "",
    [string]$TransDir = "",
    [string]$FontPath = "C:\Windows\Fonts\msyh.ttc",
    [int]$FontPx = 22,
    [string]$PythonCmd = "python",
    [switch]$SkipIso
)

$ErrorActionPreference = "Stop"
# ---- 项目路径（全部由脚本位置推导，零硬编码） ----
$Root      = Split-Path $PSScriptRoot -Parent      # 项目根目录
$Tools     = $PSScriptRoot                          # 工具目录
$BaseDir   = Join-Path $Root "base"                 # 原版抽取的纯净文件
$RomIso    = Join-Path $Root "rom\01.iso"           # 原版日文 ISO
$AssetsDir = Join-Path $Root "assets"               # 汉化图片素材
if (-not $OutDir)   { $OutDir   = Join-Path $Root "output\build" }
if (-not $TransDir) { $TransDir = Join-Path $Root "text" }
. "$Tools\inject_lib.ps1"
. "$Tools\rebuild_lib.ps1"
. "$Tools\text_inject.ps1"
$work = Join-Path $Root "_build_work"
if (Test-Path $work) { [System.IO.Directory]::Delete($work, $true) }
foreach ($d in @("$work\normal_pristine", "$work\scene_pristine", "$OutDir")) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# 1. pristine sources
Write-Output "[1/8] extracting pristine archives..."
if ($Smoke) {
    $bin = [System.IO.File]::ReadAllBytes("$BaseDir\SCENE_ID.BIN.orig")
    $entries = Get-ArchiveEntries "$BaseDir\SCENE_ID.HD.orig"
    foreach ($e in $entries) {
        if ($e.Index -gt 6) { continue }        # 00005 scene + neighbours for scan
        if ($e.Size -eq 0) { continue }
        $raw = New-Object byte[] $e.Size
        [Array]::Copy($bin, $e.Off, $raw, 0, $e.Size)
        $step = Get-EntryStep $raw
        if ($step -gt 0) { $data = [ZCodec]::Decompress($raw) } else { $data = $raw }
        [System.IO.File]::WriteAllBytes((Join-Path "$work\scene_pristine" (("{0:d5}.nut" -f $e.Index))), $data)
    }
    $binN = [System.IO.File]::ReadAllBytes("$BaseDir\NORMAL.BIN.orig")
    $entriesN = Get-ArchiveEntries "$BaseDir\NORMAL.HD.orig"
    foreach ($e in $entriesN) {
        if ($e.Size -eq 0) { continue }
        $raw = New-Object byte[] $e.Size
        [Array]::Copy($binN, $e.Off, $raw, 0, $e.Size)
        $step = Get-EntryStep $raw
        if ($step -gt 0) { $data = [ZCodec]::Decompress($raw) } else { $data = $raw }
        [System.IO.File]::WriteAllBytes((Join-Path "$work\normal_pristine" (("{0:d5}.bin" -f $e.Index))), $data)
    }
} else {
    [void](Extract-Archive "$BaseDir\SCENE_ID.HD.orig" "$BaseDir\SCENE_ID.BIN.orig" "$work\scene_pristine" ".nut")
    [void](Extract-Archive "$BaseDir\NORMAL.HD.orig" "$BaseDir\NORMAL.BIN.orig" "$work\normal_pristine" ".bin")
}
# rename NORMAL table/font to canonical names (entry 5 -> 00005.dat, 6 -> 00006.bmp)
[System.IO.File]::Move((Join-Path "$work\normal_pristine" "00005.bin"), (Join-Path "$work\normal_pristine" "00005.dat"))
[System.IO.File]::Move((Join-Path "$work\normal_pristine" "00006.bin"), (Join-Path "$work\normal_pristine" "00006.bmp"))

# 2. retained codes
Write-Output "[2/8] scanning retained codes..."
$tsvFiles = Get-ChildItem $TransDir -Filter "*.tsv" | Where-Object { $_.Name -match '^\d{5}\.tsv$' }
if ($Smoke) { $tsvFiles = $tsvFiles | Where-Object { $_.Name -eq "00005.tsv" } }
$sysMap = Get-SystemMap (Join-Path $TransDir "system_map.tsv")
$speakersMap = Get-SpeakerMap (Join-Path $TransDir "speakers.tsv")
$battleMap = Get-SystemMap (Join-Path $TransDir "battle_text.tsv")
$translatedScenes = @($tsvFiles | ForEach-Object { $_.BaseName })
$retained = Get-RetainedCodes "$work\scene_pristine" "$work\normal_pristine" $translatedScenes $sysMap $TransDir $speakersMap $battleMap
Write-Output ("  retained: {0} (system map: {1} strings)" -f $retained.Count, $sysMap.Count)

# 3. charset from translations (+ speaker zh names + system text zh)
Write-Output "[3/8] collecting charset..."
$freq = @{}
foreach ($tf in $tsvFiles) {
    foreach ($ln in [System.IO.File]::ReadAllLines($tf.FullName, [System.Text.Encoding]::UTF8)) {
        if ($ln -eq "") { continue }
        $p = $ln -split "`t", 3
        if ($p.Count -lt 3) { continue }
        $zh = $p[2].Replace('\n', "")
        foreach ($c in $zh.ToCharArray()) {
            if ([int]$c -ge 0x80) {
                $k = [string]$c
                if ($freq.ContainsKey($k)) { $freq[$k]++ } else { $freq[$k] = 1 }
            }
        }
    }
}
foreach ($ln in [System.IO.File]::ReadAllLines("$TransDir\speakers.tsv", [System.Text.Encoding]::UTF8)) {
    $p = $ln -split "`t", 2
    if ($p.Count -eq 2) {
        foreach ($c in $p[1].ToCharArray()) {
            if ([int]$c -ge 0x80) {
                $k = [string]$c
                if ($freq.ContainsKey($k)) { $freq[$k]++ } else { $freq[$k] = 1 }
            }
        }
    }
}
$sysMapFile = Join-Path $TransDir "system_map.tsv"
if (Test-Path $sysMapFile) {
    foreach ($ln in [System.IO.File]::ReadAllLines($sysMapFile, [System.Text.Encoding]::UTF8)) {
        if ($ln -eq "") { continue }
        $p = $ln -split "`t", 2
        if ($p.Count -eq 2) {
            foreach ($c in $p[1].ToCharArray()) {
                if ([int]$c -ge 0x80) {
                    $k = [string]$c
                    if ($freq.ContainsKey($k)) { $freq[$k]++ } else { $freq[$k] = 1 }
                }
            }
        }
    }
}
# battle text zh chars (skills/items/descriptions/names/bios)
$battleFile = Join-Path $TransDir "battle_text.tsv"
if (Test-Path $battleFile) {
    foreach ($ln in [System.IO.File]::ReadAllLines($battleFile, [System.Text.Encoding]::UTF8)) {
        if ($ln -eq "") { continue }
        $p = $ln -split "`t", 2
        if ($p.Count -eq 2) {
            foreach ($c in $p[1].ToCharArray()) {
                if ([int]$c -ge 0x80) {
                    $k = [string]$c
                    if ($freq.ContainsKey($k)) { $freq[$k]++ } else { $freq[$k] = 1 }
                }
            }
        }
    }
}
# ELF music-mode song titles (patched into SLPS_257.09.bin, must be in charset)
$elfSongsFile = "$TransDir\elf_songs.tsv"
if (Test-Path $elfSongsFile) {
    foreach ($ln in [System.IO.File]::ReadAllLines($elfSongsFile, [System.Text.Encoding]::UTF8)) {
        if ($ln -eq "") { continue }
        $p = $ln -split "`t", 3
        if ($p.Count -eq 3) {
            foreach ($c in $p[2].ToCharArray()) {
                if ([int]$c -ge 0x80) {
                    $k = [string]$c
                    if ($freq.ContainsKey($k)) { $freq[$k]++ } else { $freq[$k] = 1 }
                }
            }
        }
    }
}
$chars = $freq.Keys | Sort-Object
Write-Output ("  unique chars: {0}" -f $chars.Count)

# 4. slot plan + capacity check (with native-code reuse)
Write-Output "[4/8] slot plan..."
$tableRows = Read-FontTable (Join-Path "$work\normal_pristine" "00005.dat")
$fontCodeSet = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($row in $tableRows) { foreach ($c in $row) { [void]$fontCodeSet.Add($c) } }
$strictEnc = [System.Text.Encoding]::GetEncoding(932, [System.Text.EncoderFallback]::ExceptionFallback, [System.Text.DecoderFallback]::ExceptionFallback)
$native = New-Object 'System.Collections.Generic.List[string]'
$custom = New-Object 'System.Collections.Generic.List[string]'
foreach ($ch in $chars) {
    try {
        $nb = $strictEnc.GetBytes($ch)
        if ($nb.Length -eq 2 -and $fontCodeSet.Contains((([int]$nb[0]) -shl 8) -bor ([int]$nb[1]))) { $native.Add($ch); continue }
    } catch {}
    $custom.Add($ch)
}
# native codes used by zh text keep their glyph: protect from slot freeing.
# native 字复用原表里自己的格子，既不必新开槽、也不该把这些格子再扣一遍。
$protected = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($c in $retained) { [void]$protected.Add($c) }
$nativeCodes = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($ch in $native) {
    try {
        $nb = $strictEnc.GetBytes($ch)
        if ($nb.Length -eq 2) {
            $nc = (([int]$nb[0]) -shl 8) -bor ([int]$nb[1])
            [void]$nativeCodes.Add($nc)
            [void]$protected.Add($nc)
        }
    } catch {}
}
# 可用槽规则（必须保护 native 的格子！）：
#   native 字 = cp932 能编码且码在原表中。文本直接写原码，字形留在原格。
#   如果把 native 的格子分给 custom，native 的码就从码表里消失，
#   游戏二分查找失败 -> 该字显示成回退字形「、」。这就是上次截图 bug 的根因。
#   所以可用槽 = 网格 - retained占格 - native独占格。
$slotsAll = New-SlotPlan $tableRows $retained
$slots = New-Object 'System.Collections.Generic.List[object]'
foreach ($s in $slotsAll) {
    $code = 0
    if ($s.Kind -ne 'grid' -and $s.Row -lt $tableRows.Count -and $s.Col -lt $tableRows[$s.Row].Count) {
        $code = $tableRows[$s.Row][$s.Col]
    }
    if ($code -ne 0 -and $nativeCodes.Contains($code)) { continue }
    [void]$slots.Add($s)
}
$retCells = 0
foreach ($row in $tableRows) { foreach ($c in $row) { if ($retained.Contains($c)) { $retCells++ } } }
Write-Output ("  chars: {0} = {1} native + {2} custom" -f $chars.Count, $native.Count, $custom.Count)
Write-Output ("  grid: {0} x 42, retained {1} codes / {2} cells, native solo {3}, free slots {4}" -f $tableRows.Count, $retained.Count, $retCells, $nativeCodes.Count, $slots.Count)
Write-Output ("  free slots: {0} (need {1}) {2}" -f $slots.Count, $custom.Count, $(if ($slots.Count -ge $custom.Count) { "OK" } else { "OVERFLOW" }))
if ($slots.Count -lt $custom.Count) { throw "charset exceeds capacity: custom {0} > free slots {1} (need to substitute {2} low-freq chars)" -f $custom.Count, $slots.Count, ($custom.Count - $slots.Count) }

# 5. encoding + font table + uniform glyph render (ALL chars re-rendered with one font)
Write-Output "[5/8] building encoding + font..."
$origCodes = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($row in $tableRows) { foreach ($c in $row) { [void]$origCodes.Add($c) } }
$encMap = New-Encoding $custom $origCodes
# assign slots by frequency (most frequent chars get first slots — order irrelevant, but deterministic)
$customSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($c in $custom) { [void]$customSet.Add($c) }
$byFreq = $freq.GetEnumerator() | Sort-Object { -$_.Value }, Key | ForEach-Object { $_.Key } | Where-Object { $customSet.Contains($_) }
$i = 0
$encByCode = @{}
foreach ($ch in $byFreq) {
    $slot = $slots[$i]
    $row = $tableRows[$slot.Row]
    $newList = New-Object 'System.Collections.Generic.List[int]'
    foreach ($c in $row) { $newList.Add($c) }
    if ($slot.Col -lt $newList.Count) { $newList[$slot.Col] = $encMap[$ch] }
    else { $newList.Add($encMap[$ch]) }
    $tableRows[$slot.Row] = $newList.ToArray()
    $encByCode[$encMap[$ch]] = $ch
    $i++
}
# the game binary-searches the flat code array, so the final table must be
# globally ascending. Re-sort all codes and re-chunk into 42-wide rows
# (original layout: 52 rows x 42 + short last row, 53 bands in the font strip).
$allCodes = New-Object 'System.Collections.Generic.List[int]'
foreach ($row in $tableRows) { foreach ($c in $row) { [void]$allCodes.Add($c) } }
$sortedCodes = $allCodes.ToArray()
[Array]::Sort($sortedCodes)
$seen = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($c in $sortedCodes) { if (-not $seen.Add($c)) { throw ("duplicate font code {0:X4}" -f $c) } }
if ($sortedCodes.Length -gt 53 * 42) { throw ("table exceeds 53x42 font grid: {0}" -f $sortedCodes.Length) }
$tableRows = New-Object 'System.Collections.Generic.List[int[]]'
for ($si = 0; $si -lt $sortedCodes.Length; $si += 42) {
    $take = [Math]::Min(42, $sortedCodes.Length - $si)
    $r = New-Object int[] $take
    [Array]::Copy($sortedCodes, $si, $r, 0, $take)
    [void]$tableRows.Add($r)
}
Write-FontTable $tableRows (Join-Path "$work\normal_pristine" "00005.dat")
# slot positions must follow the SORTED table (renderer places glyphs by these)
$slotLog = New-Object 'System.Collections.Generic.List[string]'
for ($ri = 0; $ri -lt $tableRows.Count; $ri++) {
    for ($ci = 0; $ci -lt $tableRows[$ri].Count; $ci++) {
        $code = $tableRows[$ri][$ci]
        if ($encByCode.ContainsKey($code)) {
            $slotLog.Add(("{0}`trow{1}`tcol{2}`t{3:X4}" -f $encByCode[$code], $ri, $ci, $code))
        }
    }
}
if ($slotLog.Count -ne $encByCode.Count) { throw ("slot log mismatch: {0} placed vs {1} custom chars" -f $slotLog.Count, $encByCode.Count) }
[System.IO.File]::WriteAllLines("$OutDir\injected_slots.txt", $slotLog)
# native list must exist BEFORE the renderer runs (renderer re-draws native chars too)
$natLines = foreach ($ch in ($native | Sort-Object)) { $nb = $strictEnc.GetBytes($ch); "{0}`t{1:X4}" -f $ch, ((([int]$nb[0]) -shl 8) -bor [int]$nb[1]) }
[System.IO.File]::WriteAllLines("$OutDir\native_reuse.txt", @($natLines))
# uniform glyph render: custom + native-reuse + retained JP codes, one font/size
$retLines = foreach ($c in $retained) { "{0:X4}" -f $c }
[System.IO.File]::WriteAllLines("$OutDir\retained_codes.txt", @($retLines))
& $PythonCmd "$Tools\render_font_uniform.py" --bmp (Join-Path "$work\normal_pristine" "00006.bmp") --table (Join-Path "$work\normal_pristine" "00005.dat") --slots "$OutDir\injected_slots.txt" --native "$OutDir\native_reuse.txt" --retained "$OutDir\retained_codes.txt" --font $FontPath --px $FontPx --preview "$OutDir\font_preview.png"
if ($LASTEXITCODE -ne 0) { throw "uniform font render failed" }
# encoding map file: char TAB code
$encLines = foreach ($k in ($encMap.Keys | Sort-Object)) { "{0}`t{1:X4}" -f $k, $encMap[$k] }
[System.IO.File]::WriteAllLines("$OutDir\encoding_map.txt", $encLines)
Write-Output ("  encoded {0} chars" -f $encMap.Count)
# ELF music-mode song titles -> Chinese (same-size in-place patch)
if (Test-Path "$BaseDir\SLPS_257.09.bin") {
    & $PythonCmd "$Tools\patch_elf_songs.py" --elf "$BaseDir\SLPS_257.09.bin" --tsv $elfSongsFile --build-dir $OutDir
    if ($LASTEXITCODE -ne 0) { throw "ELF song title patch failed" }
}

# 6. text injection
Write-Output "[6/8] injecting text..."
$only = if ($Smoke) { @("00005") } else { $null }
$stats = Invoke-TextInject -SceneDir "$work\scene_pristine" -TransDir $TransDir -EncMap $encMap -SysMap $sysMap -OnlyScenes $only
Write-Output ("  files: {0}, lines: {1}, speakers: {2}, sysHits: {3}" -f $stats.Files, $stats.Lines, $stats.Speakers, $stats.SysHits)
if ($battleMap -and $battleMap.Count -gt 0) {
    $bstats = Invoke-BattleInject -NormalDir "$work\normal_pristine" -BattleMap $battleMap -EncMap $encMap
    Write-Output ("  battle: {0} strings replaced ({1} keys not found)" -f $bstats.Replaced, $bstats.Skipped.Count)
    if ($bstats.Skipped.Count -gt 0) { Write-Output ("  battle keys not found: " + ($bstats.Skipped -join ' | ')) }
}

# 7. repack archives
Write-Output "[7/8] repacking archives..."
$patchedN = @{}
$patchedN[5] = [System.IO.File]::ReadAllBytes((Join-Path "$work\normal_pristine" "00005.dat"))
$patchedN[6] = [System.IO.File]::ReadAllBytes((Join-Path "$work\normal_pristine" "00006.bmp"))
if ($battleMap -and $battleMap.Count -gt 0 -and (Test-Path (Join-Path "$work\normal_pristine" "00068.bin"))) {
    $patchedN[68] = [System.IO.File]::ReadAllBytes((Join-Path "$work\normal_pristine" "00068.bin"))
    $patchedN[70] = [System.IO.File]::ReadAllBytes((Join-Path "$work\normal_pristine" "00070.bin"))
}
# Chinese-rendered UI label textures (replace_labels.ps1 output)
$labelDir = "$AssetsDir\menu_images"
if (Test-Path $labelDir) {
    $texFiles = Get-ChildItem "$labelDir\*.tm2"
    foreach ($tf in $texFiles) { $patchedN[[int]$tf.BaseName] = [System.IO.File]::ReadAllBytes($tf.FullName) }
    Write-Output ("  ui textures: {0} entries" -f $texFiles.Count)
}
$n1 = Rebuild-Archive "$BaseDir\NORMAL.HD.orig" "$BaseDir\NORMAL.BIN.orig" $patchedN "$OutDir\NORMAL.HD" "$OutDir\NORMAL.BIN"
$patchedS = @{}
if ($Smoke) {
    $patchedS[5] = [System.IO.File]::ReadAllBytes((Join-Path "$work\scene_pristine" "00005.nut"))
} else {
    foreach ($tf in $tsvFiles) {
        $sid = [int]$tf.BaseName
        $p = Join-Path "$work\scene_pristine" ($tf.BaseName + ".nut")
        if (Test-Path $p) { $patchedS[$sid] = [System.IO.File]::ReadAllBytes($p) }
    }
    # Always include infrastructure scripts 00000-00004 (system_map.tsv may have modified lookup tables)
    foreach ($sid in 0..4) {
        $p = Join-Path "$work\scene_pristine" ("{0:d5}.nut" -f $sid)
        if (Test-Path $p) { $patchedS[$sid] = [System.IO.File]::ReadAllBytes($p) }
    }
}
$n2 = Rebuild-Archive "$BaseDir\SCENE_ID.HD.orig" "$BaseDir\SCENE_ID.BIN.orig" $patchedS "$OutDir\SCENE_ID.HD" "$OutDir\SCENE_ID.BIN"
Write-Output ("  NORMAL patched entries: {0}, SCENE_ID patched entries: {1}" -f $n1, $n2)

# 8. ISO
if (-not $SkipIso) {
    Write-Output "[8/8] rebuilding ISO..."
    & $Tools\rebuild_iso.ps1 -SrcIso "$RomIso" -OutIso "$OutDir\01_patched.iso" -BuildDir $OutDir
    Write-Output "verifying..."
    & $Tools\verify_iso.ps1 -Iso "$OutDir\01_patched.iso" -OrigIso "$RomIso" -BuildDir $OutDir
} else {
    Write-Output "[8/8] ISO skipped"
}
Write-Output "DONE -> $OutDir"
