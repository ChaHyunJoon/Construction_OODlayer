# GT 100%-completion fix — findings (2026-07-15)

## Why graded_hs_all oracle completion was 80% (4/20 non-recoverable)
- fault_sp0 (s1,s2): 0 spares configured -> a broken robot has NO replacement -> PHYSICALLY
  unrecoverable by any macro. Fix = provision >=1 spare (realistic operating regime).
- zoneblk_sev0.9 (s1,s2): ForbidZone endgame WEDGE, NOT geometry (ov only 0.31; other zone
  instances at ov 0.49/0.6 completed). Root cause: these rows were REUSED from the OLD
  pre-recovery world (reform=400, no carrier-rescue) per STATUS.md; only fault/deep-battery
  were relabeled under hot-swap.

## Diagnostic proof (zone_s1_diag, reform=120 + CARRIER_RESCUE=1 + NOPROG=30000 + hotswap)
zoneblk_s1_sev0.9 now COMPLETES on ALL 5 macros:
  NOOP Y291 mk31.7 | Replace Y291 | Deprio Y291 | ForbidZone Y291 mk38.8 | Reform Y291
The endgame recovery (force-CLOSE stuck carriers at their deposit goals -> DepositCargo chain
released) is the SAME machinery that completes the fault case. The zone at ov=0.31 is recoverable.
Under strong recovery NOOP completes too (mk 31.7 < ForbidZone 38.8) -> mild zone = restraint (NOOP best).

## Plan
1. fault: regenerate at sp1 (scarce but nonzero spare) -> Replace completes. [running: fault_sp1]
2. zone: to keep a CONSEQUENTIAL ForbidZone instance, test centered zone (offset 0.0 = max overlap):
   if NOOP incomplete + ForbidZone complete -> ideal consequential+recoverable. [running: zone_off0]
   else use recoverable mild zone (all complete).
3. merge regenerated 4 with existing recoverable 16 -> verify GT completion = 100%.
4. retrain surrogate, recompute cost_eval, rebuild dashboard.
