#!/usr/bin/env bash
# Fill in whatever seed-3/4/5 instances are still missing, ONE INSTANCE PER PROCESS.
#
# Why one-per-process: the batched jobs (5 battery instances in a single Julia process) grow the heap
# to ~1.5 GB by the last instance, and 5 such processes exhausted a 16 GB box -> OutOfMemoryError with
# 8/25 rows written. Shrinking the stack (2GB -> 512MB) fixed the *stack* half of the problem but not
# the heap half. A process that does exactly one instance (1 control + 5 macros) exits before its heap
# grows, so memory is bounded no matter how long the whole grid takes.
# (배치 job은 인스턴스를 이어 돌수록 힙이 커져 OOM. 한 프로세스가 한 인스턴스만 하고 죽으면 메모리가 유계.)
#
# Idempotent: instances that already have 5 rows anywhere in the corpus are skipped, so this can be
# re-run after any failure and it only does the remaining work.
#
# Usage: bash oracle/fill_missing.sh [max_parallel]   (default 3)
set -u
# 경로는 스크립트 위치에서 유도한다(하드코딩된 절대경로는 다른 머신에서 그대로 깨진다).
# 이 스크립트: <repo>/wm4spacecraft_manufacturing/oracle/  -> WM 은 한 단계 위, CB(repo)는 두 단계 위.
WM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CB="$(cd "$WM/.." && pwd)"
OUTDIR="$WM/oracle/out/graded_hs_s345"
LOGDIR="$WM/sweep_lab/regen_logs"
MAXP="${1:-3}"
STACK="${DS_STACK:-536870912}"
mkdir -p "$OUTDIR" "$LOGDIR"

# 이미 5행이 다 있는 instance 목록을 뽑는다(어느 파일에 있든 상관없이).
# 주의: export는 반드시 heredoc보다 먼저 — 뒤에 두면 python이 OUTDIR을 못 읽어 목록이 비고,
# 그러면 완료된 인스턴스까지 전부 재생성한다(실제로 그렇게 낭비한 적 있음).
export OUTDIR
have_ids=$(python - <<'PY'
import glob, json, collections, os
c = collections.Counter()
for p in glob.glob(os.path.join(os.environ["OUTDIR"], "*.jsonl")):
    for l in open(p, encoding="utf-8"):
        if l.strip():
            c[json.loads(l)["instance"]] += 1
print(" ".join(i for i, n in c.items() if n >= 5))
PY
)
echo "[fill] already complete: $(echo $have_ids | wc -w) instances"

launch() {                                   # $1=iid  $2=파일태그  나머지=DS_*
  local iid="$1" tag="$2"; shift 2
  case " $have_ids " in *" $iid "*) echo "[fill][skip] $iid"; return;; esac
  while [ "$(jobs -r | wc -l)" -ge "$MAXP" ]; do sleep 10; done
  echo "[fill][launch] $iid ($(date +%H:%M:%S))"
  ( cd "$CB" && env "$@" DS_HOTSWAP=1 DS_STACK="$STACK" DS_OUT="$OUTDIR/fill_${tag}.jsonl" \
      julia +lts --project=. "$WM/oracle/gen_oracle_dataset.jl" > "$LOGDIR/fill_${tag}.log" 2>&1
    echo "[fill][done] $iid exit=$? rows=$(wc -l < "$OUTDIR/fill_${tag}.jsonl" 2>/dev/null) ($(date +%H:%M:%S))" ) &
  sleep 15
}

for seed in 3 4 5; do
  for sev in 0.05 0.12 0.2 0.35 0.6; do
    launch "battery_s${seed}_sev${sev}_sp3" "battery_s${seed}_${sev}" \
      DS_KINDS=battery DS_SEEDS=$seed DS_BSOC=$sev
  done
  for sp in 0 3; do
    launch "fault_s${seed}_sev1.0_sp${sp}" "fault_s${seed}_sp${sp}" \
      DS_KINDS=fault DS_SEEDS=$seed DS_SPARES=$sp
  done
  launch "faultidle_s${seed}_sev0.0_sp3" "faultidle_s${seed}" \
    DS_KINDS=faultidle DS_SEEDS=$seed DS_SPARES=3
done
wait
echo "[fill] ALL DONE"
