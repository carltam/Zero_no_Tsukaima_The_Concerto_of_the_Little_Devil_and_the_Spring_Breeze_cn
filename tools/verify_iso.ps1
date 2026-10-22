# Functional self-verification of patched ISO:
# re-parse directory records of the OUTPUT ISO, read the four target files at
# their (possibly new) LBAs, compare MD5 against build\ originals.
param(
    [string]$Iso = (Join-Path (Split-Path $PSScriptRoot -Parent) "output\build\01_patched.iso"),
    [string]$OrigIso = (Join-Path (Split-Path $PSScriptRoot -Parent) "rom\01.iso"),
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

$checks = @{
    "NORMAL.HD"    = "$BuildDir\NORMAL.HD"
    "NORMAL.BIN"   = "$BuildDir\NORMAL.BIN"
    "SCENE_ID.HD"  = "$BuildDir\SCENE_ID.HD"
    "SCENE_ID.BIN" = "$BuildDir\SCENE_ID.BIN"
}

$entries = Get-IsoEntries $Iso
"re-parsed entries: $($entries.Count)"

$fs = [System.IO.File]::OpenRead($Iso)
try {
    foreach ($name in ($checks.Keys | Sort-Object)) {
        $e = $entries | Where-Object { $_.Name.ToUpper() -eq $name }
        if (-not $e) { "MISSING $name"; continue }
        $data = New-Object byte[] $e.Size
        $fs.Seek($e.Lba * $SECTOR, 'Begin') | Out-Null
        [void]$fs.Read($data, 0, $e.Size)
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $h1 = [BitConverter]::ToString($md5.ComputeHash($data)) -replace "-", ""
        $h2 = (Get-FileHash $checks[$name] -Algorithm MD5).Hash
        $ok = if ($h1 -eq $h2) { "OK " } else { "FAIL" }
        "{0} {1,-12} lba={2,-8} size={3,-9} isoMD5={4} fileMD5={5}" -f $ok, $name, $e.Lba, $e.Size, $h1.Substring(0,8), $h2.Substring(0,8)
    }
    # PVD volume space size vs actual file size
    $vd = New-Object byte[] $SECTOR
    $fs.Seek(16 * $SECTOR, 'Begin') | Out-Null
    [void]$fs.Read($vd, 0, $SECTOR)
    $vsLe = [BitConverter]::ToUInt32($vd, 80)
    $vsBeBytes = $vd[84..87]
    [Array]::Reverse($vsBeBytes)
    $vsBe2 = [BitConverter]::ToUInt32($vsBeBytes, 0)
    $actual = (Get-Item $Iso).Length / $SECTOR
    "PVD volume space: LE={0} BE={1} actual={2} {3}" -f $vsLe, $vsBe2, $actual, $(if ($vsLe -eq $actual -and $vsBe2 -eq $actual) { "OK" } else { "FAIL" })

    # every NON-patched file must be byte-identical to the original ISO
    $orig = Get-IsoEntries $OrigIso
    $fo = [System.IO.File]::OpenRead($OrigIso)
    $bad = 0; $checked = 0
    try {
        foreach ($oe in ($orig | Where-Object { -not $_.IsDir -and -not $checks.ContainsKey($_.Name.ToUpper()) })) {
            $ne = $entries | Where-Object { $_.Name -eq $oe.Name }
            if (-not $ne) { "MISSING in patched: $($oe.Name)"; $bad++; continue }
            $n = [int][Math]::Min($oe.Size, $ne.Size)
            if ($oe.Size -ne $ne.Size -or $oe.Lba -ne $ne.Lba) {
                if ($checks.ContainsKey($oe.Name.ToUpper())) { continue }
                "CHANGED unexpectedly: $($oe.Name) lba $($oe.Lba)->$($ne.Lba) size $($oe.Size)->$($ne.Size)"
                $bad++; continue
            }
            $a = New-Object byte[] $n
            $b = New-Object byte[] $n
            $fs.Seek($ne.Lba * $SECTOR, 'Begin') | Out-Null
            [void]$fs.Read($a, 0, $n)
            $fo.Seek($oe.Lba * $SECTOR, 'Begin') | Out-Null
            [void]$fo.Read($b, 0, $n)
            $same = $true
            for ($i = 0; $i -lt $n; $i++) { if ($a[$i] -ne $b[$i]) { $same = $false; break } }
            if (-not $same) { "DATA DIFF: $($oe.Name) at byte $i"; $bad++ }
            $checked++
        }
    } finally { $fo.Close() }
    "untouched files checked: $checked, bad: $bad $(if ($bad -eq 0) { 'OK' } else { 'FAIL' })"
} finally { $fs.Close() }
