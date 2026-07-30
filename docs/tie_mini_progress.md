# TIE Fighter Mini OOD demo progress

Target model: `8028-1 - TIE Fighter - Mini.mpd`

## Acceptance matrix

| Scenario | Assembly complete | OOD handled | Zone residual | Status |
|---|---:|---:|---:|---|
| Nominal | 4/4 | n/a | n/a | pass (step 1228) |
| Battery | 4/4 | 1/1 | n/a | pass (step 1625) |
| Breakdown | 4/4 | 1/1 | n/a | pass (step 1649) |
| Forbid Zone | 4/4 | 1/1 | 0 | pass (step 1564) |
| Breakdown + Battery | 4/4 | 2/2 | n/a | pass (step 1625) |
| Breakdown + Zone | 4/4 | 2/2 | 0 | pass (step 1334) |
| Battery + Zone | 4/4 | 2/2 | 0 | pass (step 1351) |

## Design decisions

- Model scale and robot count come exclusively from `get_project_params`.
- A forbid zone remains active after re-staging so routing and the post-RVO
  physical clearance gate continue to enforce it.
- Zone recovery first relocates every blocked subassembly. If root or fixed
  future goals remain covered, the geometry solver computes a minimum
  whole-build translation.
- A zone scenario fails explicitly when any future physical goal remains in
  the active zone; it must not silently emit an incomplete replay.

## Work log

- Connected `run_demo.jl` to the shared multi-assembly and minimum-translation
  geometry recovery path.
- Removed the demo-only behavior that deleted the active zone immediately
  after re-staging.
- Added physical-disc verification after subassembly re-staging. The first TIE
  zone run correctly rejected a nominal `restaged_all` result because eight
  unfinished work discs still overlapped the zone.
- Recompute the physical work set after each minimum translation. Mid-build
  active work can change that set, so zone recovery now converges with bounded
  incremental corrections instead of assuming one translation is sufficient.
- Generated demo zones now cross the boundary of a pending staging workspace
  and minimize overlap with active/fixed physical goals. A live operator zone
  that covers an already fixed structure remains a verified safe-stop case,
  not a falsely recoverable one.
- The default recoverable demo uses a local zone (20% of staging radius).
  Large-zone behaviour is a separate stress case because it can legitimately
  disconnect an already active factory layout.
- Re-staging eligibility now distinguishes a pristine assembly from one with
  active or completed build steps. `AssemblyComplete` alone was too weak and
  caused capture-frame divergence in late composite-zone events.
- Composite zone demos inject the spatial constraint first, then apply the
  robot fault/battery event. Both constraints remain active and are verified.
- Spatial recovery is performed before the first build step opens. Robot OOD
  slots are counted independently, so adding a pre-build zone cannot silently
  move a fault/battery event to a point with no eligible target.
- Parent-build cache reads tolerate newly created transport and robot IDs
  during the first post-restage refresh.
- `summarize_streams.ps1` rejects a replay when either assembly completion or
  the expected OOD/respec count is missing.
- Tractor zone regression passed with 8/8 assemblies at step 812 and zero
  residual work overlap.

## Static rendering acceptance

The dashboard artifact path (`render_demo.jl`) is now tested independently from
the stream-only path. All six OOD demos publish a complete MeshCat HTML:

| Scenario | Assemblies | OOD | Handoffs | HTML | Status |
|---|---:|---:|---:|---:|---|
| Battery | 4/4 | 1 | 1 | 7.25 MB | pass |
| Breakdown | 4/4 | 1 | 1 | 7.25 MB | pass |
| Forbid Zone | 4/4 | 1 | 0 | 7.28 MB | pass |
| Breakdown + Battery | 4/4 | 2 | 2 | 7.25 MB | pass |
| Breakdown + Zone | 4/4 | 2 | 1 | 7.24 MB | pass |
| Battery + Zone | 4/4 | 2 | 1 | 7.28 MB | pass |

- Zone recovery is queued before motion. In zone composites, Breakdown is
  injected at 20% schedule progress and Battery at 32%; this avoids both the
  initial closed-prefix batch and a late frontier with no safe fault target.
- Gantt handoff timestamps are captured every simulation step. The failed
  physical asset stops at the handoff, the depot spare's old standby lane is
  truncated there, and replacement work starts at that boundary.
- Battery event SoC is preserved on the retired fleet row (about 0.10), while
  the healthy replacement has its own post-handoff SoC.
- `validate_demo_artifacts.ps1` checks assembly completion, expected OOD and
  respec counts, MeshCat artifact size, Gantt handoff invariants, valid SoC
  ranges, depleted state preservation, and replacement fleet rows.
- `render_demo.jl` refuses to publish an incomplete animation. The dashboard
  waits for the control server's `complete` state instead of treating the first
  streamed frame as completion.
