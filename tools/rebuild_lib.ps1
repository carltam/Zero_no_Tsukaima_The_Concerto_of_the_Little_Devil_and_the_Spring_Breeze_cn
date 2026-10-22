# Archive utilities for Zero no Tsukaima PS2 (.HD/.BIN pairs).
# Loads codec, parses entries, extracts clean files, rebuilds archives from originals + patched files.
# Dot-source this file:  . <项目根>\tools\rebuild_lib.ps1
if (-not ([System.Management.Automation.PSTypeName]'ZCodec').Type) {
    Add-Type -TypeDefinition ([System.IO.File]::ReadAllText("$PSScriptRoot\codec.cs"))
}

function Get-ArchiveEntries([string]$hdPath) {
    $hd = [System.IO.File]::ReadAllBytes($hdPath)
    $n = [int]($hd.Length / 4)
    $list = New-Object 'System.Collections.Generic.List[object]'
    $pos = 0
    for ($i = 0; $i -lt $n; $i++) {
        $size = [BitConverter]::ToInt32($hd, $i * 4)
        $list.Add([pscustomobject]@{ Index = $i; Off = $pos; Size = $size })
        if ($size -ne 0) {
            $pos += $size
            $pos = [int][Math]::Ceiling($pos / 0x800) * 0x800
        }
    }
    return ,$list
}

function Get-EntryStep([byte[]]$raw) {
    # original compressed entries carry [raw_size][step]; validate plausibility
    if ($raw.Length -lt 8) { return 0 }
    $rawSize = [BitConverter]::ToInt32($raw, 0)
    $step = [BitConverter]::ToInt32($raw, 4)
    if ($rawSize -gt 0 -and $step -ge 1 -and $step -le 64) { return $step }
    return 0
}

function Extract-Archive([string]$hdPath, [string]$binPath, [string]$outDir, [string]$ext) {
    # extract every entry decompressed; name = index 5-digit + ext
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $bin = [System.IO.File]::ReadAllBytes($binPath)
    $entries = Get-ArchiveEntries $hdPath
    $count = 0
    foreach ($e in $entries) {
        if ($e.Size -eq 0) { continue }
        $raw = New-Object byte[] $e.Size
        [Array]::Copy($bin, $e.Off, $raw, 0, $e.Size)
        $step = Get-EntryStep $raw
        if ($step -gt 0) { $data = [ZCodec]::Decompress($raw) } else { $data = $raw }
        [System.IO.File]::WriteAllBytes((Join-Path $outDir (("{0:d5}" -f $e.Index) + $ext)), $data)
        $count++
    }
    return $count
}

function Rebuild-Archive([string]$origHd, [string]$origBin, [hashtable]$patched, [string]$outHd, [string]$outBin) {
    # patched: @{ index(int) = byte[] new content (uncompressed) }
    $bin = [System.IO.File]::ReadAllBytes($origBin)
    $entries = Get-ArchiveEntries $origHd
    $newHd = New-Object 'System.Collections.Generic.List[byte]'
    $newBin = New-Object 'System.IO.MemoryStream'
    $replaced = 0
    foreach ($e in $entries) {
        $newBytes = $null
        if ($patched.ContainsKey($e.Index)) { $newBytes = $patched[$e.Index] }
        if ($e.Size -eq 0 -and $null -eq $newBytes) {
            $newHd.AddRange([BitConverter]::GetBytes([int]0))
            continue
        }
        $raw = New-Object byte[] $e.Size
        [Array]::Copy($bin, $e.Off, $raw, 0, $e.Size)
        $step = Get-EntryStep $raw
        if ($null -ne $newBytes) {
            if ($step -le 0) { $step = 1 }   # was stored plain; compress patched to be safe? keep plain semantics:
            $out = [ZCodec]::Compress($newBytes, $step)
            $newHd.AddRange([BitConverter]::GetBytes([int]$out.Length))
            $newBin.Write($out, 0, $out.Length)
            # pad to 0x800
            $pad = (([int][Math]::Ceiling($newBin.Length / [double]0x800) * 0x800) - $newBin.Length)
            if ($pad -gt 0) { $zeros = New-Object byte[] $pad; $newBin.Write($zeros, 0, $pad) }
            $replaced++
        } else {
            $newHd.AddRange([BitConverter]::GetBytes([int]$e.Size))
            $newBin.Write($raw, 0, $e.Size)
            $pad = (([int][Math]::Ceiling($newBin.Length / [double]0x800) * 0x800) - $newBin.Length)
            if ($pad -gt 0) { $zeros = New-Object byte[] $pad; $newBin.Write($zeros, 0, $pad) }
        }
    }
    [System.IO.File]::WriteAllBytes($outHd, $newHd.ToArray())
    [System.IO.File]::WriteAllBytes($outBin, $newBin.ToArray())
    return $replaced
}
