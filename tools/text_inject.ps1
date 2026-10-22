# text_inject.ps1 — inject Chinese translations into SCENE_ID .nut scripts.
# Usage: . inject_lib.ps1 first, then Invoke-TextInject -SceneDir -TransDir -EncMap
function Get-SpeakerMap([string]$path) {
    $m = @{}
    if (-not (Test-Path $path)) { return $m }
    foreach ($ln in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        if ($ln -eq "") { continue }
        $p = $ln -split "`t", 2
        if ($p.Count -eq 2 -and $p[0] -ne "") { $m[$p[0]] = $p[1] }
    }
    return $m
}

function Get-SceneTrans([string]$tsvPath) {
    # returns @{ idx(string) = zh }
    $t = @{}
    foreach ($ln in [System.IO.File]::ReadAllLines($tsvPath, [System.Text.Encoding]::UTF8)) {
        if ($ln -eq "" -or $ln.StartsWith("#")) { continue }
        $p = $ln -split "`t", 3
        if ($p.Count -lt 3) { continue }
        $t[$p[0]] = $p[2]
    }
    return $t
}

function ConvertTo-Escaped([string]$s) {
    # input: translation text where \n is a REAL newline (caller converted literal \n first)
    $sb = New-Object 'System.Text.StringBuilder'
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq '\') { [void]$sb.Append('\\') }
        elseif ($c -eq '"') { [void]$sb.Append('\"') }
        elseif ($c -eq "`n") { [void]$sb.Append('\n') }
        else { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}

function Get-SystemMap([string]$path) {
    # system_map.tsv / part4.txt: japanese<TAB>chinese (only rows with chinese)
    $m = @{}
    if (-not (Test-Path $path)) { return $m }
    foreach ($ln in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        if ($ln -eq "" -or $ln.StartsWith("#")) { continue }
        $p = $ln -split "`t", 2
        if ($p.Count -eq 2 -and $p[1] -ne "") { $m[$p[0]] = $p[1] }
    }
    return $m
}

function Invoke-TextInject {
    param(
        [string]$SceneDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "_build_work\scene_pristine"),
        [string]$TransDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "text"),
        [string]$SpeakersPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "text\speakers.tsv"),
        [hashtable]$EncMap,
        [hashtable]$SysMap = $null,
        [string[]]$OnlyScenes = $null
    )
    $speakers = Get-SpeakerMap $SpeakersPath
    $talkPat = [regex]'talk\(\s*("(?:[^"\\]|\\.)*"|null)\s*,\s*("[^"]*"|null)\s*,\s*("(?:[^"\\]|\\.)*")\s*,\s*([^)]*)\)'
    # system replacement pairs: "jp" -> "zh", longest first; escape only double-quote in zh
    $sysPairs = @()
    if ($SysMap -and $SysMap.Count -gt 0) {
        $sysPairs = $SysMap.Keys | Sort-Object { -$_.Length } | ForEach-Object {
            ,@(('"' + $_ + '"'), ('"' + ($SysMap[$_].Replace('"', '\"')) + '"'))
        }
    }
    # speaker names as global quoted replacements (covers talk() variants the main loop cannot match)
    foreach ($k in $speakers.Keys) {
        $sysPairs += ,@(('"' + $k + '"'), ('"' + ($speakers[$k].Replace('"', '\"')) + '"'))
    }
    $stats = @{ Files = 0; Lines = 0; Speakers = 0; Missing = 0; SysHits = 0; Modified = New-Object 'System.Collections.Generic.List[string]' }
    $files = [System.IO.Directory]::GetFiles($SceneDir, "*.nut")
    if ($OnlyScenes) {
        $files = $files | Where-Object {
            $sid = [System.IO.Path]::GetFileNameWithoutExtension($_)
            $OnlyScenes -contains $sid
        }
    }
    foreach ($f in $files) {
        $sid = [System.IO.Path]::GetFileNameWithoutExtension($f)
        $text = $script:SJIS.GetString([System.IO.File]::ReadAllBytes($f))
        $changed = $false
        $trans = $null
        $tsv = Join-Path $TransDir ($sid + ".tsv")
        if (Test-Path $tsv) { $trans = Get-SceneTrans $tsv }
        $matches2 = $talkPat.Matches($text)
        for ($i = $matches2.Count - 1; $i -ge 0; $i--) {
            $m = $matches2[$i]
            $callChanged = $false
            $newCall = $m.Value
            # dialogue text (arg3) — only when a translation exists
            $idxStr = [string]$i
            if ($trans -and $trans.ContainsKey($idxStr)) {
                # literal \n -> real newline, then escape back to \n (keeps escapes consistent)
                $zh = $trans[$idxStr].Replace('\n', "`n")
                $newLine = '"' + (ConvertTo-Escaped $zh) + '"'
                $newCall = $newCall.Substring(0, $m.Groups[3].Index - $m.Index) + $newLine + $newCall.Substring($m.Groups[3].Index - $m.Index + $m.Groups[3].Length)
                $stats.Lines++
                $callChanged = $true
            }
            # speaker nameplate (arg1) — applies to every talk() call
            $spk = $m.Groups[1].Value
            if ($spk -and $spk -ne "null" -and $spk.Length -ge 2) {
                $name = $spk.Substring(1, $spk.Length - 2)
                if ($speakers.ContainsKey($name)) {
                    $newSpk = '"' + (ConvertTo-Escaped $speakers[$name]) + '"'
                    $newCall = $newCall.Substring(0, $m.Groups[1].Index - $m.Index) + $newSpk + $newCall.Substring($m.Groups[1].Index - $m.Index + $m.Groups[1].Length)
                    $stats.Speakers++
                    $callChanged = $true
                }
            }
            if ($callChanged) {
                $text = $text.Substring(0, $m.Index) + $newCall + $text.Substring($m.Index + $m.Length)
                $changed = $true
            }
        }
        if ($sysPairs.Count -gt 0) {
            $sysChanged = $false
            foreach ($sp in $sysPairs) {
                if ($text.Contains($sp[0])) {
                    $text = $text.Replace($sp[0], $sp[1])
                    $stats.SysHits++
                    $sysChanged = $true
                }
            }
            if ($sysChanged) { $changed = $true }
        }
        if ($changed) {
            $bytes = ConvertTo-GameBytes $text $EncMap
            [System.IO.File]::WriteAllBytes($f, $bytes)
            $stats.Files++
            [void]$stats.Modified.Add($sid)
        }
    }
    return $stats
}

function Invoke-BattleInject {
    # patch NORMAL battle data entries (skills/items/descriptions/names/bios)
    # byte-exact in-place replacement: zh bytes <= jp bytes, NUL-padded; bios pre-padded
    param(
        [string]$NormalDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "_build_work\normal_pristine"),
        [hashtable]$BattleMap,
        [hashtable]$EncMap
    )
    $stats = @{ Replaced = 0; Found = New-Object 'System.Collections.Generic.HashSet[string]' }
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    foreach ($name in @('00068.bin', '00070.bin')) {
        $path = Join-Path $NormalDir $name
        if (-not (Test-Path $path)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $s = $latin1.GetString($bytes)
        foreach ($k in ($BattleMap.Keys | Sort-Object { -$_.Length })) {
            $jpPat = $latin1.GetString($script:SJIS.GetBytes($k))
            if (-not $s.Contains($jpPat)) { continue }
            $zhBytes = ConvertTo-GameBytes $BattleMap[$k] $EncMap
            if ($zhBytes.Length -gt $jpPat.Length) { throw ("battle overflow: $k -> $($BattleMap[$k])") }
            if ($zhBytes.Length -lt $jpPat.Length) {
                $padded = New-Object byte[] $jpPat.Length
                [Array]::Copy($zhBytes, $padded, $zhBytes.Length)
                $zhBytes = $padded
            }
            $s = $s.Replace($jpPat, $latin1.GetString($zhBytes))
            $stats.Replaced++
            [void]$stats.Found.Add($k)
        }
        [System.IO.File]::WriteAllBytes($path, $latin1.GetBytes($s))
    }
    $stats.Missing = @($BattleMap.Keys | Where-Object { -not $stats.Found.Contains($_) })
    return $stats
}
