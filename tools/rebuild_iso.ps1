# PowerShell port of rebuild_iso.py + iso9660.py (no Python available).
# Rebuilds the game ISO with patched NORMAL / SCENE_ID archives:
#   - fits original sector allocation -> overwrite in place
#   - grew larger -> append at end of image, patch directory records
#     (new LBA + new size, both LE and BE, in primary and supplementary trees)
#   - update PVD volume space size, truncate image
param(
    [string]$SrcIso = (Join-Path (Split-Path $PSScriptRoot -Parent) "rom\01.iso"),
    [string]$OutIso = (Join-Path (Split-Path $PSScriptRoot -Parent) "output\build\01_patched.iso"),
    [string]$BuildDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "output\build")
)

$ErrorActionPreference = "Stop"
$SECTOR = 2048

function Get-IsoEntries([string]$iso) {
    $fs = [System.IO.File]::OpenRead($iso)
    try {
        $descs = @()
        for ($s = 16; $s -lt 40; $s++) {
            $vd = New-Object byte[] $SECTOR
            [void]$fs.Seek($s * $SECTOR, 'Begin')
            [void]$fs.Read($vd, 0, $SECTOR)
            $t = [int]$vd[0]
            $ident = [System.Text.Encoding]::ASCII.GetString($vd, 1, 5)
            $descs += , @($t, $ident, $s)
            if ($t -eq 255) { break }
        }
        $entries = @()
        foreach ($d in $descs) {
            $t = $d[0]; $ident = $d[1]; $dsec = $d[2]
            if ($t -eq 255) { break }
            if ($t -ne 1 -and $t -ne 2) { continue }
            if ($ident -ne "CD001") { continue }
            $vd = New-Object byte[] $SECTOR
            [void]$fs.Seek($dsec * $SECTOR, 'Begin')
            [void]$fs.Read($vd, 0, $SECTOR)
            if ($t -eq 2) {
                $esc = [System.Text.Encoding]::ASCII.GetString($vd, 88, 32)
                if ($esc -notmatch "%/@|%/C|%/E") { continue }
            }
            $rootRec = New-Object byte[] 34
            [Array]::Copy($vd, 156, $rootRec, 0, 34)
            $rootLba = [BitConverter]::ToUInt32($rootRec, 2)
            $rootSize = [BitConverter]::ToUInt32($rootRec, 10)
            # walk tree
            $stack = New-Object 'System.Collections.Generic.Stack[object]'
            $stack.Push(@{ Lba = $rootLba; Size = $rootSize; Prefix = "" })
            while ($stack.Count -gt 0) {
                $dir = $stack.Pop()
                $nsec = [Math]::Floor(($dir.Size + $SECTOR - 1) / $SECTOR)
                $data = New-Object byte[] ($nsec * $SECTOR)
                [void]$fs.Seek($dir.Lba * $SECTOR, 'Begin')
                [void]$fs.Read($data, 0, $data.Length)
                $limit = [Math]::Min($dir.Size, $data.Length)
                $pos = 0
                while ($pos -lt $limit) {
                    $len = [int]$data[$pos]
                    if ($len -eq 0) { $pos = ($pos / $SECTOR + 1) * $SECTOR; continue }
                    if ($pos + $len -gt $data.Length) { break }
                    $lbaLe = [BitConverter]::ToUInt32($data, $pos + 2)
                    $sizeLe = [BitConverter]::ToUInt32($data, $pos + 10)
                    $flags = [int]$data[$pos + 25]
                    $nameLen = [int]$data[$pos + 32]
                    if ($nameLen -eq 1 -and ($data[$pos + 33] -eq 0 -or $data[$pos + 33] -eq 1)) {
                        $pos += $len; continue
                    }
                    $raw = [System.Text.Encoding]::ASCII.GetString($data, $pos + 33, $nameLen)
                    $name = $raw.Split(";")[0].TrimEnd(".")
                    $full = if ($dir.Prefix) { $dir.Prefix + "/" + $name } else { $name }
                    $entries += [pscustomobject]@{
                        Name = $full; Lba = $lbaLe; Size = $sizeLe
                        IsDir = ($flags -band 2) -ne 0
                        RecOff = $dir.Lba * $SECTOR + $pos
                    }
                    if (($flags -band 2) -ne 0) {
                        $stack.Push(@{ Lba = $lbaLe; Size = $sizeLe; Prefix = $full })
                    }
                    $pos += $len
                }
            }
        }
        return , $entries
    } finally { $fs.Close() }
}

$patches = [ordered]@{
    "NORMAL.HD"    = Join-Path $BuildDir "NORMAL.HD"
    "NORMAL.BIN"   = Join-Path $BuildDir "NORMAL.BIN"
    "SCENE_ID.HD"  = Join-Path $BuildDir "SCENE_ID.HD"
    "SCENE_ID.BIN" = Join-Path $BuildDir "SCENE_ID.BIN"
}
# ELF with Chinese music-mode song titles (same size -> in-place overwrite)
$elfPatch = Join-Path $BuildDir "SLPS_257.09.bin"
if (Test-Path $elfPatch) { $patches["SLPS_257.09"] = $elfPatch }

$entries = Get-IsoEntries $SrcIso
Write-Output ("parsed {0} entries from original ISO" -f $entries.Count)

$targets = @{}
foreach ($e in $entries) {
    $key = $e.Name.ToUpper()
    if ($patches.Contains($key)) {
        if (-not $targets.ContainsKey($key)) { $targets[$key] = @() }
        $targets[$key] += $e
    }
}
foreach ($k in $patches.Keys) {
    if (-not $targets.ContainsKey($k)) { throw "target $k not found in ISO" }
}

$isoSize = (Get-Item $SrcIso).Length
if ($isoSize % $SECTOR -ne 0) { throw "ISO size not sector-aligned" }
$endLba = $isoSize / $SECTOR

$outDir = Split-Path $OutIso -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
[System.IO.File]::Copy($SrcIso, $OutIso, $true)

$f = [System.IO.File]::Open($OutIso, 'Open', 'ReadWrite')
$bw = New-Object System.IO.BinaryWriter($f)
try {
    foreach ($k in ($patches.Keys | Sort-Object)) {
        $data = [System.IO.File]::ReadAllBytes($patches[$k])
        foreach ($e in $targets[$k]) {
            $allocSectors = [Math]::Floor(($e.Size + $SECTOR - 1) / $SECTOR)
            if ($data.Length -le $allocSectors * $SECTOR) {
                $f.Seek($e.Lba * $SECTOR, 'Begin') | Out-Null
                $bw.Write($data)
                $pad = $allocSectors * $SECTOR - $data.Length
                if ($pad -gt 0) {
                    $fill = New-Object byte[] $pad
                    for ($i = 0; $i -lt $pad; $i++) { $fill[$i] = 0xFF }
                    $bw.Write($fill)
                }
                Write-Output ("{0,-12} in-place  lba={1,-6} size {2} -> {3}" -f $k, $e.Lba, $e.Size, $data.Length)
            } else {
                $newLba = $endLba
                $f.Seek($newLba * $SECTOR, 'Begin') | Out-Null
                $bw.Write($data)
                $pad = ($SECTOR - ($data.Length % $SECTOR)) % $SECTOR
                if ($pad -gt 0) {
                    $fill = New-Object byte[] $pad
                    for ($i = 0; $i -lt $pad; $i++) { $fill[$i] = 0xFF }
                    $bw.Write($fill)
                }
                $endLba += ($data.Length + $pad) / $SECTOR
                # patch dir record: LBA LE@+2 BE@+6, size LE@+10 BE@+14
                $f.Seek($e.RecOff + 2, 'Begin') | Out-Null
                $bw.Write([BitConverter]::GetBytes([uint32]$newLba))
                $f.Seek($e.RecOff + 6, 'Begin') | Out-Null
                $beLba = New-Object byte[] 4
                $beLba[0] = ($newLba -shr 24) -band 0xFF; $beLba[1] = ($newLba -shr 16) -band 0xFF
                $beLba[2] = ($newLba -shr 8) -band 0xFF; $beLba[3] = $newLba -band 0xFF
                $bw.Write($beLba)
                $f.Seek($e.RecOff + 10, 'Begin') | Out-Null
                $bw.Write([BitConverter]::GetBytes([uint32]$data.Length))
                $f.Seek($e.RecOff + 14, 'Begin') | Out-Null
                $beSz = New-Object byte[] 4
                $beSz[0] = ($data.Length -shr 24) -band 0xFF; $beSz[1] = ($data.Length -shr 16) -band 0xFF
                $beSz[2] = ($data.Length -shr 8) -band 0xFF; $beSz[3] = $data.Length -band 0xFF
                $bw.Write($beSz)
                Write-Output ("{0,-12} RELOCATED lba {1} -> {2} size {3} -> {4}" -f $k, $e.Lba, $newLba, $e.Size, $data.Length)
            }
        }
    }
    # PVD volume space size: sector 16, offset 80 (LE) / 84 (BE)
    $f.Seek(16 * $SECTOR + 80, 'Begin') | Out-Null
    $bw.Write([BitConverter]::GetBytes([uint32]$endLba))
    $beEnd = New-Object byte[] 4
    $beEnd[0] = ($endLba -shr 24) -band 0xFF; $beEnd[1] = ($endLba -shr 16) -band 0xFF
    $beEnd[2] = ($endLba -shr 8) -band 0xFF; $beEnd[3] = $endLba -band 0xFF
    $bw.Write($beEnd)
    $finalSize = $endLba * $SECTOR
    $f.SetLength($finalSize)
} finally { $bw.Close(); $f.Close() }

Write-Output ("done: {0} ({1} sectors, {2:N2} GB)" -f $OutIso, $endLba, ($finalSize / 1e9))
