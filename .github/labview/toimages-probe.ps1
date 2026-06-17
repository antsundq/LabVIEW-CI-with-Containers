<#
.SYNOPSIS
    Probe v3 (diagnostic): figure out how to run LabVIEW headless in the NI
    container so COM can drive toimages\Convert.vi.

.DESCRIPTION
    v2 proved `New-Object -ComObject LabVIEW.Application` creates the server but
    LabVIEW never finishes initializing (Version blank for 240s) - the container's
    "-Headless required" wall. The PROVEN path is `LabVIEWCLI -Headless`, so this
    probe:
      Phase A - runs a known-good `LabVIEWCLI ... -Headless` render in a background
        job and, while it runs, captures the exact LabVIEW.exe COMMAND LINE it used
        (Win32_Process.CommandLine). That reveals the headless launch mechanism.
        It ALSO tries to attach COM (GetActiveObject) to that headless instance
        while it is alive - if that works, COM + Convert.vi is viable.
      Phase B - independently tries launching LabVIEW.exe ourselves with a few
        candidate headless flags and reports which (if any) yields a COM-ready app.
    Pure diagnostic; prints everything to the CI log.
#>
param(
    [string]   $ConvertVI   = 'C:\repo\.github\labview\toimages\Convert.vi',
    [string]   $PtsOpDir    = 'C:\repo\.github\labview\PrintToSingleFileHtml',
    [string[]] $TargetVI    = @(),
    [string]   $OutDir      = 'C:\repo\_probe-out',
    [string]   $LabVIEWPath = ''
)
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function Resolve-LabVIEWPath([string]$Preferred) {
    if ($Preferred -and (Test-Path $Preferred)) { return $Preferred }
    $cands = @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } | Where-Object { Test-Path $_ })
    if ($cands.Count -gt 0) { return $cands[0] }
    throw "LabVIEW.exe not found"
}
function Get-LVProcs { @(Get-CimInstance Win32_Process -Filter "Name='LabVIEW.exe'" -ErrorAction SilentlyContinue) }
function Try-AttachCom {
    try {
        $app = [System.Runtime.InteropServices.Marshal]::GetActiveObject('LabVIEW.Application')
        $v = [string]$app.Version
        if ($v -ne '') { return @{ app = $app; ver = $v } }
    } catch { }
    return $null
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$lvExe = Resolve-LabVIEWPath $LabVIEWPath
$dir   = Split-Path -Parent $lvExe
$cli   = Join-Path $dir 'LabVIEWCLI.exe'
if (-not (Test-Path $cli)) { $c = Get-Command LabVIEWCLI.exe -ErrorAction SilentlyContinue; if ($c) { $cli = $c.Source } }
$oneVI = ($TargetVI | Where-Object { Test-Path $_ } | Select-Object -First 1)

Write-Host "=== probe v3 ==="
Write-Host "  LabVIEW.exe : $lvExe"
Write-Host "  LabVIEWCLI  : $cli"
Write-Host "  Convert.vi  : $ConvertVI  (exists: $(Test-Path $ConvertVI))"
Write-Host "  PrintHtmlOp : $PtsOpDir   (exists: $(Test-Path $PtsOpDir))"
Write-Host "  sample VI   : $oneVI"

# ── Phase A: capture LabVIEWCLI -Headless's LabVIEW.exe command line ─────────
Write-Host ""
Write-Host "=== Phase A: capture how 'LabVIEWCLI -Headless' launches LabVIEW.exe ==="
if (-not $oneVI -or -not (Test-Path $cli) -or -not (Test-Path $PtsOpDir)) {
    Write-Warning "  missing CLI / op dir / sample VI - skipping Phase A"
} else {
    $job = Start-Job -ScriptBlock {
        param($cli,$lv,$op,$vi)
        & $cli -OperationName PrintToSingleFileHtml -LabVIEWPath $lv -AdditionalOperationDirectory $op `
               -LogToConsole TRUE -VI $vi -OutputPath 'C:\probe_a.html' -o -c -Headless 2>&1
    } -ArgumentList $cli,$lvExe,$PtsOpDir,$oneVI

    $captured = $null; $attached = $null
    for ($i = 0; $i -lt 120; $i++) {
        $procs = Get-LVProcs
        if ($procs.Count -gt 0 -and -not $captured) {
            $captured = $procs[0].CommandLine
            Write-Host "  >>> LabVIEW.exe CommandLine: $captured"
        }
        if ($procs.Count -gt 0 -and -not $attached) {
            $a = Try-AttachCom
            if ($a) { $attached = $a; Write-Host "  >>> COM ATTACH to headless LabVIEW SUCCEEDED — version $($a.ver)" }
        }
        if ($captured -and $attached) { break }
        if ((Get-Job -Id $job.Id).State -ne 'Running') { break }
        Start-Sleep -Seconds 1
    }
    if (-not $captured) { Write-Host "  (never observed a LabVIEW.exe process during the CLI render)" }

    # If we attached, prove end-to-end: run Convert.vi on the sample VI.
    if ($attached) {
        try {
            Write-Host "  --- running Convert.vi via the attached COM app ---"
            $vi = $attached.app.GetVIReference($ConvertVI, "", $false, 0)
            $vi.SetControlValue('VI Path in', $oneVI)
            $vi.Run($false)
            $rd = (Get-Date).AddSeconds(150)
            while ($true) { $st=[int]$vi.ExecState; if ($st -eq 1) { break }; if ((Get-Date) -gt $rd) { $vi.Abort(); throw "run timeout" }; Start-Sleep -Milliseconds 100 }
            $json = [string]$vi.GetControlValue('JSON out')
            Write-Host "  >>> Convert.vi JSON length: $($json.Length)"
            if ($json.Length -gt 0) {
                [System.IO.File]::WriteAllText((Join-Path $OutDir 'attached-sample.json'), $json, [System.Text.UTF8Encoding]::new($false))
                Write-Host "  >>> head: $($json.Substring(0,[Math]::Min(300,$json.Length)))"
            }
        } catch { Write-Warning "  Convert.vi via attach failed: $($_.Exception.Message)" }
    }

    Wait-Job $job -Timeout 200 | Out-Null
    Receive-Job $job 2>&1 | Select-Object -First 25 | ForEach-Object { Write-Host "  [cli] $_" }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Get-LVProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ── Phase B: try launching LabVIEW.exe ourselves with candidate headless flags ─
Write-Host ""
Write-Host "=== Phase B: candidate self-launch flags for a COM-ready headless LabVIEW ==="
$variants = @(
    @('-Headless'),
    @('-Headless','/Automation'),
    @('/Automation','-Headless'),
    @('-Headless','-unattended')
)
foreach ($args in $variants) {
    Get-LVProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Write-Host "  --- launch: LabVIEW.exe $($args -join ' ') ---"
    try { Start-Process -FilePath $lvExe -ArgumentList $args | Out-Null } catch { Write-Warning "    start failed: $($_.Exception.Message)"; continue }
    $ok = $false
    for ($i = 0; $i -lt 40; $i++) {
        $procs = Get-LVProcs
        if ($procs.Count -eq 0) { Write-Host "    LabVIEW.exe exited (flag likely rejected)"; break }
        $a = Try-AttachCom
        if ($a) { Write-Host "    >>> COM-READY with '$($args -join ' ')' — version $($a.ver)"; $ok = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $ok) { Write-Host "    no COM-ready app for this variant" }
    else { break }
}
Get-LVProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "=== probe v3 done ==="
