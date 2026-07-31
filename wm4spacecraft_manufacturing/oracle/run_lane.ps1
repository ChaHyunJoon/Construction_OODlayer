# =============================================================================
# run_lane.ps1 -- one LANE: drains a queue of oracle units sequentially.
# Launched detached by run_oracle_overnight.ps1, so it survives the launcher
# window (and VS Code) being closed.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File run_lane.ps1 `
#       -Units "1:control,1:2,2:0" -LaneName A
# =============================================================================
param(
    [Parameter(Mandatory=$true)][string]$Units,     # "seed:unit,seed:unit,..."
    [Parameter(Mandatory=$true)][string]$LaneName
)

$ErrorActionPreference = "Continue"
# 경로는 스크립트 위치에서 유도(절대경로 하드코딩은 다른 머신에서 깨진다).
# $PSScriptRoot = <repo>\wm4spacecraft_manufacturing\oracle
$wm     = Split-Path -Parent $PSScriptRoot
$repo   = Split-Path -Parent $wm
$script = Join-Path $wm "oracle\gen_oracle_fullsim.jl"
$outdir = Join-Path $wm "oracle\out"
$laneLog = Join-Path $outdir "lane_$LaneName.log"

function Log($msg) {
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $LaneName, $msg
    $line | Tee-Object -FilePath $laneLog -Append | Out-Host
}

function AvailGB {
    try { (Get-Counter '\Memory\Available MBytes' -EA Stop).CounterSamples[0].CookedValue / 1024 }
    catch { 99 }   # if the counter fails, don't block
}

Log "lane start: $Units"

foreach ($u in ($Units -split ",")) {
    $parts = $u.Trim() -split ":"
    $seed = $parts[0]; $unit = $parts[1]
    $tag  = "s${seed}_${unit}"
    $log  = Join-Path $outdir "run_$tag.log"
    $err  = Join-Path $outdir "run_$tag.err"

    # --- RAM guard: don't start a ~2 GB julia process into a thrashing machine -----
    $waited = 0
    while ((AvailGB) -lt 2.5 -and $waited -lt 60) {
        Log ("waiting for RAM (avail {0:N1} GB < 2.5) ..." -f (AvailGB))
        Start-Sleep -Seconds 60; $waited++
    }

    $env:NSPARE      = "3"
    $env:RVO         = "1"
    $env:ORACLE_SEED = $seed
    $env:ORACLE_ONLY = $unit

    $t0 = Get-Date
    Log ("START $tag   (avail {0:N1} GB)" -f (AvailGB))
    try {
        # Start-Process => OS-level redirection, no PowerShell stderr ErrorRecord wrapping.
        Start-Process -FilePath "julia" `
            -ArgumentList @("+lts", "--project=$repo", $script) `
            -WorkingDirectory $repo `
            -RedirectStandardOutput $log -RedirectStandardError $err `
            -NoNewWindow -Wait
        $code = "ok"
    } catch {
        $code = "LAUNCH-FAIL: $_"
    }
    $mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)

    $json = Join-Path $outdir ("oracle_fullsim_fault" + $(if ($seed -eq "1") { "" } else { "_s$seed" }) + "_$unit.json")
    $got  = if (Test-Path $json) { "JSON ok" } else { "NO JSON (check $tag.log/.err)" }
    Log "DONE  $tag  ($mins min)  $code  $got"
}

Log "lane finished."
