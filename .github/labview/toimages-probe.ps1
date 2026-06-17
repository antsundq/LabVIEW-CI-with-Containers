<#
.SYNOPSIS
    Probe: generate the position-aware "frames" JSON for one or more VIs by
    driving the vendored toimages\Convert.vi through LabVIEW's ActiveX/COM server
    (the same VI Server API lvctl uses). Diagnostic only — used to confirm the
    approach works headless inside the NI LabVIEW Windows container before wiring
    it into the production snapshot pipeline.

.DESCRIPTION
    For each target VI: sets Convert.vi's "VI Path in", runs it, reads "JSON out"
    (a flat array of frames with Position + Children — see toimages\README.md),
    and writes it next to nothing in particular (an explicit -OutDir). Verbose
    step-by-step logging so a CI log pinpoints exactly where COM/headless fails.

.NOTES
    Scripting MUST be enabled before LabVIEW launches (Convert.vi traverses the
    block diagram), so this merges the scripting tokens into LabVIEW.ini first.
#>
param(
    [string]   $ConvertVI   = 'C:\repo\.github\labview\toimages\Convert.vi',
    [string[]] $TargetVI    = @(),
    [string]   $OutDir      = 'C:\repo\_probe-out',
    [string]   $LabVIEWPath = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function Resolve-LabVIEWPath([string]$Preferred) {
    if ($Preferred -and (Test-Path $Preferred)) { return $Preferred }
    $cands = @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
        Where-Object { Test-Path $_ })
    if ($cands.Count -gt 0) { return $cands[0] }
    throw "LabVIEW.exe not found under C:\Program Files\National Instruments\LabVIEW *"
}

function Enable-LVScripting([string]$LabVIEWExePath) {
    $iniPath = Join-Path (Split-Path -Parent $LabVIEWExePath) 'LabVIEW.ini'
    $tokens  = [ordered]@{
        'SuperSecretPrivateSpecialStuff'    = 'True'
        'unattended'                        = 'True'
        'NIERAutoSendAndSuppressAllDialogs' = 'True'
        'SuppressRTConnectionDialogs'       = 'True'
        'neverShowAddonLicensingStartup'    = 'True'
        'neverShowLicensingStartupDialog'   = 'True'
        'DWarnDialog'                        = 'False'
        'AutoSaveEnabled'                    = 'False'
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $existing = @()
    if (Test-Path -LiteralPath $iniPath) { $existing = @(Get-Content -LiteralPath $iniPath) }
    $secIdx = -1
    for ($i = 0; $i -lt $existing.Count; $i++) { if ("$($existing[$i])".Trim() -ieq '[LabVIEW]') { $secIdx = $i; break } }
    if ($secIdx -lt 0) {
        $block = @('[LabVIEW]') + ($tokens.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
        if ($existing.Count -gt 0 -and "$($existing[-1])".Trim() -ne '') { $existing += '' }
        $existing += $block
        [System.IO.File]::WriteAllLines($iniPath, [string[]]$existing, $utf8)
        Write-Host "  [ini] created [LabVIEW] section with scripting tokens"
        return
    }
    $end = $existing.Count
    for ($j = $secIdx + 1; $j -lt $existing.Count; $j++) { if ("$($existing[$j])" -match '^\s*\[.+\]\s*$') { $end = $j; break } }
    $pre  = @(); if ($secIdx -ge 0)          { $pre  = @($existing[0..$secIdx]) }
    $body = @(); if ($end -gt ($secIdx + 1)) { $body = @($existing[($secIdx + 1)..($end - 1)]) }
    $post = @(); if ($end -lt $existing.Count) { $post = @($existing[$end..($existing.Count - 1)]) }
    foreach ($k in $tokens.Keys) {
        $found = $false
        for ($m = 0; $m -lt $body.Count; $m++) {
            if ("$($body[$m])" -match "^\s*$([regex]::Escape($k))\s*=") { $body[$m] = "$k=$($tokens[$k])"; $found = $true; break }
        }
        if (-not $found) { $body += "$k=$($tokens[$k])" }
    }
    $merged = @(); $merged += $pre; $merged += $body; $merged += $post
    [System.IO.File]::WriteAllLines($iniPath, [string[]]$merged, $utf8)
    Write-Host "  [ini] ensured scripting tokens in $iniPath"
}

Write-Host "=== toimages COM probe ==="
$lvExe = Resolve-LabVIEWPath $LabVIEWPath
Write-Host "  LabVIEW.exe : $lvExe"
Write-Host "  Convert.vi  : $ConvertVI"
Write-Host "  Targets     : $($TargetVI -join '; ')"
Write-Host "  OutDir      : $OutDir"
if (-not (Test-Path $ConvertVI)) { throw "Convert.vi not found at $ConvertVI" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "--- enabling LabVIEW scripting (LabVIEW.ini) ---"
Enable-LVScripting $lvExe

Write-Host "--- launching LabVIEW via COM (New-Object -ComObject LabVIEW.Application) ---"
$lv = $null
try {
    $lv = New-Object -ComObject 'LabVIEW.Application'
    Write-Host "  COM OK. LabVIEW version: $($lv.Version)"
} catch {
    throw "COM launch FAILED: $($_.Exception.Message)"
}

$ok = 0; $fail = 0
foreach ($t in $TargetVI) {
    $name = Split-Path $t -Leaf
    Write-Host "--- [$name] ---"
    if (-not (Test-Path $t)) { Write-Warning "  target not found: $t"; $fail++; continue }
    try {
        Write-Host "  GetVIReference ..."
        $vi = $lv.GetVIReference($ConvertVI)
        Write-Host "  opened: $($vi.Name)"
        Write-Host "  SetControlValue('VI Path in', '$t')"
        $vi.SetControlValue('VI Path in', $t)
        Write-Host "  Run (wait until done) ..."
        $vi.Run($true)
        Write-Host "  GetControlValue('JSON out') ..."
        $json = [string]$vi.GetControlValue('JSON out')
        Write-Host "  JSON length: $($json.Length)"
        if ($json.Length -gt 0) {
            $safe = ($name -replace '[^A-Za-z0-9._-]', '_') + '.json'
            $out  = Join-Path $OutDir $safe
            [System.IO.File]::WriteAllText($out, $json, [System.Text.UTF8Encoding]::new($false))
            $head = $json.Substring(0, [Math]::Min(280, $json.Length))
            Write-Host "  wrote $out"
            Write-Host "  head: $head"
            $ok++
        } else {
            Write-Warning "  empty JSON for $name"
            $fail++
        }
        try { $vi.CloseFrontPanel() } catch {}
    } catch {
        Write-Warning "  FAILED for ${name}: $($_.Exception.Message)"
        $fail++
    }
}

Write-Host "--- closing LabVIEW ---"
try { $lv.Quit() } catch {}

Write-Host "=== probe done: $ok ok, $fail failed ==="
if ($ok -eq 0) { exit 1 }
exit 0
