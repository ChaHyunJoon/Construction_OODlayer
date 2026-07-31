# =============================================================================
# run_oracle_overnight.ps1 -- unattended oracle eval-set generation (RVO=1).
#
# Launches 3 DETACHED lane processes and EXITS. Because the lanes are independent
# processes (not Start-Job children), they survive this launcher window closing —
# and VS Code closing. RAM (not cores) is the binding constraint (~15.7 GB total,
# each julia+PyCall(RVO2) process ~1.5-2.5 GB), so 3 lanes, each draining a queue.
#
# Round 1 (decisive): seed1 control / 0:NOOP / 1:Replace
#   -> reproduces the documented result (no-adapt INCOMPLETE 245/313,
#      Replace COMPLETE 292/313) and yields the FIRST valid oracle instance.
# Round 2 (ranking) : seed1 2:Deprioritize / 4:ReformTeam + seed2 control
# Round 3 (2nd inst): seed2 0 / 1
#
# Each unit writes its own JSON + log to out/. ~1-2 h per unit, ~4-5 h total.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File run_oracle_overnight.ps1
# =============================================================================

$ErrorActionPreference = "Continue"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$lane   = Join-Path $here "run_lane.ps1"
$outdir = Join-Path $here "out"
if (-not (Test-Path $outdir)) { New-Item -ItemType Directory -Force $outdir | Out-Null }

# --- keep the machine awake: a sleeping laptop wastes the whole window ------------
Write-Host "[setup] disabling sleep/hibernate on AC ..." -ForegroundColor Cyan
powercfg /change standby-timeout-ac 0   2>$null
powercfg /change hibernate-timeout-ac 0 2>$null
Write-Host "[setup] *** PLUG IN THE LAPTOP *** (sleep is only disabled on AC power)" -ForegroundColor Yellow

$avail = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue / 1024
Write-Host ("[setup] Available RAM = {0:N1} GB" -f $avail) -ForegroundColor Cyan
if ($avail -lt 6) {
    Write-Host "[warn] < 6 GB available. Close VS Code / Chrome / Docker, or lanes will thrash." -ForegroundColor Red
}

# --- 3 lanes; each drains its queue sequentially ---------------------------------
$lanes = @{
    "A" = "1:control,1:2,2:0"
    "B" = "1:1,1:4,2:1"
    "C" = "1:0,2:control"
}

foreach ($name in $lanes.Keys | Sort-Object) {
    $p = Start-Process -FilePath "powershell" `
        -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$lane,
                        "-Units",$lanes[$name],"-LaneName",$name) `
        -WindowStyle Minimized -PassThru
    Write-Host ("[run] lane {0} -> PID {1}   units: {2}" -f $name, $p.Id, $lanes[$name]) -ForegroundColor Green
}

Write-Host ""
Write-Host "[run] 3 detached lanes launched. You may now close this window AND VS Code." -ForegroundColor Green
Write-Host "[run] monitor:  Get-Content '$outdir\lane_A.log' -Wait" -ForegroundColor Cyan
Write-Host "[run] results:  $outdir\oracle_fullsim_fault*.json" -ForegroundColor Cyan
Write-Host "[run] stop all: Get-Process julia,powershell | Stop-Process -Force   (nuclear)" -ForegroundColor DarkGray
