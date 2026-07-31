# =============================================================================
# run_parallel.ps1 -- parallel oracle data generation with a bounded worker pool.
#
# WHY A POOL AND NOT `-Lanes = cores`:
#   The binding constraint is RAM, not CPU. Each unit is one julia process holding
#   env + geometry + HiGHS + PyCall(RVO2) ~= 1.5-2.5 GB; this machine has 15.7 GB.
#   4 concurrent units is the safe ceiling (12 physical cores are NOT the limit).
#   gen_oracle_dataset.jl also leaks across instances, so ONE PROCESS PER UNIT is
#   mandatory (see run_graded.sh header) -- the pool just runs several of them.
#
# RESUMABLE: a unit whose .jsonl already has 5 rows is skipped, so you can Ctrl-C
#   and re-run. Merge at the end with the printed command.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File oracle\run_parallel.ps1 `
#       -Seeds 1,2,3,4,5,6,7,8,9,10 -Lanes 4 -Out oracle\out\n100
# =============================================================================
param(
    [string]$Seeds = "1-10",     # "1-10" or "1,2,5" (a string, so it survives bash/cmd quoting)
    [int]$Lanes   = 4,
    [string]$Out  = "oracle\out\n100",
    [double]$MinFreeGB = 3.0,
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$wm   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$repo = Split-Path -Parent $wm   # wm4 는 repo 내부이므로 그 부모가 곧 repo
$gen  = Join-Path $wm "oracle\gen_oracle_dataset.jl"
$OutDir = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $wm $Out }
New-Item -ItemType Directory -Force $OutDir | Out-Null

# --- parse -Seeds ("1-10" range or "1,2,5" list) --------------------------------
$SeedList = @()
foreach ($part in ($Seeds -split ",")) {
    $p = $part.Trim()
    if ($p -match '^(\d+)\s*-\s*(\d+)$') { $SeedList += [int]$matches[1]..[int]$matches[2] }
    elseif ($p -match '^\d+$')           { $SeedList += [int]$p }
}
if ($SeedList.Count -eq 0) { throw "could not parse -Seeds '$Seeds'" }

# --- the per-seed unit mix -----------------------------------------------------
# 10 units/seed x 10 seeds = 100 instances.  Rebalanced vs run_graded.sh: zone gets
# 4 units instead of 2 (ForbidZone is the starved class, n=2 in the current set) and
# the battery grid is dense around the measured flip (0.12 -> Replace, 0.20 -> NOOP).
$Units = @(
    @{ tag="battery0.05"; env=@{ DS_KINDS="battery";   DS_BSOC="0.05"; DS_SPARES="3" } },
    @{ tag="battery0.12"; env=@{ DS_KINDS="battery";   DS_BSOC="0.12"; DS_SPARES="3" } },
    @{ tag="battery0.20"; env=@{ DS_KINDS="battery";   DS_BSOC="0.2";  DS_SPARES="3" } },
    @{ tag="battery0.35"; env=@{ DS_KINDS="battery";   DS_BSOC="0.35"; DS_SPARES="3" } },
    @{ tag="fault_sp3";   env=@{ DS_KINDS="fault";     DS_SPARES="3" } },
    @{ tag="faultidle";   env=@{ DS_KINDS="faultidle"; DS_SPARES="3" } },
    @{ tag="zoneblk0.7";  env=@{ DS_KINDS="zoneblk";   DS_ZFRACS="0.7"; DS_SPARES="3" } },
    @{ tag="zoneblk0.9";  env=@{ DS_KINDS="zoneblk";   DS_ZFRACS="0.9"; DS_SPARES="3" } },
    @{ tag="zoneblk1.1";  env=@{ DS_KINDS="zoneblk";   DS_ZFRACS="1.1"; DS_SPARES="3" } },
    @{ tag="zoneharm";    env=@{ DS_KINDS="zoneharm";  DS_SPARES="3" } }
)

# --- shared settings (must match the completing world the demo runs) -----------
$Common = @{
    DS_NOPROG      = "30000"   # a CORRECT arm must be able to finish; 3000 mislabels Replace
    DS_NOCTRL      = "1"       # cost-aware labels need no admissibility control -> saves 1/6 compute
    DS_REFORM      = "120"     # background recovery cadence of the completing demo
    CARRIER_RESCUE = "1"
    DS_HOTSWAP     = "1"       # identity-preserving Replace: the world where Replace COMPLETES
    JULIA_NUM_THREADS = "1"    # no thread oversubscription across lanes
    OMP_NUM_THREADS   = "1"
    OPENBLAS_NUM_THREADS = "1"
}

function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }

# --- build the queue, skipping finished units ---------------------------------
$queue = New-Object System.Collections.Queue
$skipped = 0
foreach ($s in $SeedList) {
    foreach ($u in $Units) {
        $f = Join-Path $OutDir ("{0}_s{1}.jsonl" -f $u.tag, $s)
        if ((Test-Path $f) -and ((Get-Content $f | Measure-Object -Line).Lines -ge 5)) { $skipped++; continue }
        $queue.Enqueue(@{ tag=$u.tag; seed=$s; env=$u.env; file=$f })
    }
}
$total = $queue.Count
Write-Host ("[plan] {0} units queued, {1} already complete, {2} lanes, out={3}" -f $total, $skipped, $Lanes, $OutDir) -ForegroundColor Cyan
Write-Host ("[plan] est. wall-clock ~ {0:N1} h  (16.5 min sim + ~3 min julia startup per unit / {1} lanes)" -f (($total * 19.5) / 60 / $Lanes), $Lanes) -ForegroundColor Cyan
if ($DryRun) { $queue | ForEach-Object { "  $($_.tag)_s$($_.seed)" }; exit 0 }

# --- bounded worker pool -------------------------------------------------------
$running = @()
$done = 0
$t0 = Get-Date
while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    # reap finished
    $still = @()
    foreach ($r in $running) {
        if ($r.proc.HasExited) {
            $rows = if (Test-Path $r.file) { (Get-Content $r.file | Measure-Object -Line).Lines } else { 0 }
            $done++
            Write-Host ("[done] {0}_s{1}  {2:N1} min  {3} rows  ({4}/{5})" -f `
                $r.tag, $r.seed, ((Get-Date) - $r.t0).TotalMinutes, $rows, $done, $total) -ForegroundColor Green
        } else { $still += $r }
    }
    $running = $still

    # launch while there is room AND RAM
    while ($running.Count -lt $Lanes -and $queue.Count -gt 0) {
        if ((FreeGB) -lt $MinFreeGB) {
            Write-Host ("[wait] free RAM {0:N1} GB < {1} GB -- holding launch" -f (FreeGB), $MinFreeGB) -ForegroundColor Yellow
            break
        }
        $u = $queue.Dequeue()
        foreach ($k in $Common.Keys)  { Set-Item -Path ("env:" + $k) -Value $Common[$k] }
        foreach ($k in $u.env.Keys)   { Set-Item -Path ("env:" + $k) -Value $u.env[$k] }
        $env:DS_SEEDS = "$($u.seed)"
        $env:DS_OUT   = $u.file
        $log = [System.IO.Path]::ChangeExtension($u.file, ".log")
        $p = Start-Process -FilePath "julia" `
            -ArgumentList @("+lts", "--project=$repo", $gen) `
            -WorkingDirectory $wm -RedirectStandardOutput $log `
            -RedirectStandardError ([System.IO.Path]::ChangeExtension($u.file, ".err")) `
            -NoNewWindow -PassThru
        $running += @{ proc=$p; tag=$u.tag; seed=$u.seed; file=$u.file; t0=(Get-Date) }
        Write-Host ("[run ] {0}_s{1}  pid {2}  (free {3:N1} GB, {4} active)" -f `
            $u.tag, $u.seed, $p.Id, (FreeGB), $running.Count)
        Start-Sleep -Seconds 20   # stagger: julia startup is the RAM spike
    }
    Start-Sleep -Seconds 15
}

Write-Host ("`n[all ] {0} units in {1:N1} h" -f $total, ((Get-Date) - $t0).TotalHours) -ForegroundColor Green
Write-Host ("[next] merge:   Get-Content '{0}\*.jsonl' | Set-Content '{1}\oracle\out\n100.jsonl'" -f $OutDir, $wm) -ForegroundColor Cyan
Write-Host ("[next] verify:  python -c `"import json;rows=[json.loads(l) for l in open('oracle/out/n100.jsonl')];import collections;c=collections.Counter(r['instance'] for r in rows);print(len(c),'instances');print('bad:',[k for k,v in c.items() if v!=5])`"") -ForegroundColor Cyan
