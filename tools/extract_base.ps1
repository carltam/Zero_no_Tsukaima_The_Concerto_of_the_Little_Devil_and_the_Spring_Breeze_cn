# extract_base.ps1 — 从 rom/01.iso 重新抽取 base/ 纯净文件（溯源/校验用）。
# 正常情况下无需运行：base/ 里的文件就是从原版 ISO 抽取并验证过的。
# 当你想确认 base/ 未被改动、或换了新 ISO 时，运行本脚本重新生成。
# 用法: & <项目根>\tools\extract_base.ps1
param(
    [string]$SrcIso = (Join-Path (Split-Path $PSScriptRoot -Parent) "rom\01.iso"),
    [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "base")
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
                    $name = raw.Split(";")[0].TrimEnd(".")
                    $full = if ($dir.Prefix) { $dir.Prefix + "/" + $name } else { $name }
                    $entries += [pscustomobject]@{
                        Name = $full; Lba = $lbaLe; Size = $sizeLe
                        IsDir = ($flags -band 2) -ne 0
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

# ISO 内文件名 -> base/ 目标文件名
$want = [ordered]@{
    "NORMAL.BIN"   = "NORMAL.BIN.orig"
    "NORMAL.HD"    = "NORMAL.HD.orig"
    "SCENE_ID.BIN" = "SCENE_ID.BIN.orig"
    "SCENE_ID.HD"  = "SCENE_ID.HD.orig"
    "SLPS_257.09"  = "SLPS_257.09.bin"
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$entries = Get-IsoEntries $SrcIso
$fs = [System.IO.File]::OpenRead($SrcIso)
try {
    foreach ($k in $want.Keys) {
        $e = $entries | Where-Object { $_.Name.ToUpper() -eq $k -and -not $_.IsDir } | Select-Object -First 1
        if (-not $e) { throw "target $k not found in ISO" }
        $data = New-Object byte[] $e.Size
        [void]$fs.Seek($e.Lba * $SECTOR, 'Begin')
        [void]$fs.Read($data, 0, $e.Size)
        $out = Join-Path $OutDir $want[$k]
        [System.IO.File]::WriteAllBytes($out, $data)
        $h = (Get-FileHash $out -Algorithm MD5).Hash
        Write-Output ("{0,-12} lba={1,-7} size={2,-9} -> {3}  md5={4}" -f $k, $e.Lba, $e.Size, $want[$k], $h)
    }
} finally { $fs.Close() }
Write-Output "done -> $OutDir"
