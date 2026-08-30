#!/usr/bin/env bash
# ============================================================================================
# 로봇 OOD 케이스(battery / fault)를 **seed 만 바꿔 가며** 여러 판 생성한다.
#
# 왜 이 두 케이스뿐인가
# --------------------
# DEMO_SEED 는 **로봇 OOD(배터리 방전·급작 고장)의 발화 시점과 종류를 뽑는 난수**다(render_demo.jl
# 의 DEMO_SEED 주석). 구역(zone)은 seed 와 무관하다 — 공간 restage 는 build step 이 열리기 전에만
# transform-safe 해서 언제나 sim 시작 전 1 회 고정이고, 게다가 이 데모에서 구역은 **사람이 정의하는
# 사건**이다(대시보드 라이브 세션). 그래서 seed 스윕의 대상은 ①Battery 와 ②Breakdown 뿐이다.
#
# 출력 (render_demo.jl 이 DEMO_SEED 로 이름을 붙이므로 이름을 바꿀 필요가 없다)
#   streams/tractor__<case>.jsonl        (seed 1 = 접미사 없음)
#   streams/tractor__<case>_s<N>.jsonl   (seed >= 2)
#   anim/   같은 규칙. **미완주 런은 애니를 발행하지 않는다**(의도된 안전장치).
#   tools/monitor/regen_case_logs/seedsweep__<case>_s<N>.log
#   tools/monitor/seed_sweep_summary.csv   case,seed,exit,frames,complete,anim,seconds
#
# 사용법
#   bash tools/monitor/run_seed_sweep.sh                 # battery+fault × seed 1..30 = 60 런
#   SEEDS="1 2 3" bash tools/monitor/run_seed_sweep.sh   # seed 일부만
#   CASES="battery" bash tools/monitor/run_seed_sweep.sh # 케이스 일부만
#
# ★ 순차 실행이어야 한다. 병렬로 돌리면 (1) HiGHS 가 런마다 다른 스케줄을 내 비교가 무효가 되고
#   (2) 프로세스당 ~2.5GB 라 OOM 이 나며 (3) 렌더가 MeshCat 포트(8700)를 공유해 충돌한다.
# ============================================================================================
set -u
cd "$(dirname "$0")/../.."                      # ConstructionBots.jl
LOGD=tools/monitor/regen_case_logs; mkdir -p "$LOGD"
STREAMS=tools/monitor/streams
ANIM=tools/monitor/anim; mkdir -p "$ANIM"
SUMMARY=tools/monitor/seed_sweep_summary.csv

MODEL="${DEMO_MODEL:-tractor.mpd}"
CASES=(${CASES:-battery fault})
SEEDS=(${SEEDS:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30})
# 라우터를 끄고 기본 정책(canonical)으로 고정한다: 외부 LLM 서비스가 떠 있는지에 스윕 결과가
# 좌우되면 "seed 가 만든 차이"와 "서비스가 만든 차이"를 구분할 수 없다.
# 🔴 2026-08-29 (§B-1): 여기 있던 *"라우터 판정 자체는 참고용으로 계속 기록된다(policy.jl 의
# advisory 경로)"* 는 **거짓이 됐다** — 그 advisory 경로는 novelty 축이었고 §B-1 이 지웠다.
# 이 스윕이 남기는 라우터 기록은 서술자 6개와 `drives_lane=false` 뿐이다.
export DEMO_ROUTER="${DEMO_ROUTER:-0}"

# printf 를 쓴다 — `echo` 는 개행을 붙이고 `tr -c` 는 그 개행까지 `_` 로 바꾼다. 그러면 base 가
# "tractor_" 가 되어 이 스크립트가 보는 파일 이름(tractor___battery.jsonl)이 render_demo.jl 이
# 실제로 쓰는 이름(tractor__battery.jsonl)과 어긋난다 = 삭제·프레임수·완주판정이 전부 헛돈다.
base=$(basename "$MODEL"); base="${base%.*}"; base=$(printf %s "$base" | tr -c 'A-Za-z0-9' '_')
total=$(( ${#CASES[@]} * ${#SEEDS[@]} ))
i=0
[ -s "$SUMMARY" ] || echo "case,seed,exit,frames,complete,anim,seconds" > "$SUMMARY"
echo "=== seed sweep: $total runs (${CASES[*]} × seed ${SEEDS[0]}..${SEEDS[${#SEEDS[@]}-1]}) start $(date +%F' '%H:%M:%S) ==="

for case in "${CASES[@]}"; do
  for seed in "${SEEDS[@]}"; do
    i=$((i+1))
    sfx=""; [ "$seed" = "1" ] || sfx="_s${seed}"
    stream="$STREAMS/${base}__${case}${sfx}.jsonl"
    anim="$ANIM/${base}__${case}${sfx}.html"
    log="$LOGD/seedsweep__${case}${sfx}.log"
    echo "== [$i/$total] $case seed=$seed ($(date +%H:%M:%S)) =="

    # 이번 런이 만든 산출물만 남기기 위해 자리를 비운다. 안 비우면 미완주로 애니 발행이 거부돼도
    # 옛 파일이 그대로 남아 이번 런의 것인 척한다(regen_case_policy_matrix.sh 와 같은 이유).
    rm -f "$stream" "$anim"

    t0=$SECONDS
    env DEMO_MODEL="$MODEL" DEMO_OOD="$case" DEMO_SEED="$seed" \
      julia +lts --project=. tools/monitor/render_demo.jl > "$log" 2>&1
    rc=$?
    dt=$(( SECONDS - t0 ))

    frames=0; [ -s "$stream" ] && frames=$(wc -l < "$stream" | tr -d ' ')
    complete=no; grep -aq "PROJECT COMPLETE" "$log" 2>/dev/null && complete=yes
    hasanim=no;  [ -s "$anim" ] && hasanim=yes
    echo "$case,$seed,$rc,$frames,$complete,$hasanim,$dt" >> "$SUMMARY"
    echo "   exit=$rc  frames=$frames  complete=$complete  anim=$hasanim  ${dt}s"
    tr '\r' '\n' < "$log" | grep -aE "drawn at step|\[RESPEC\]|PROJECT (COMPLETE|INCOMPLETE)" | tail -3 | sed 's/^/   /'
  done
done

echo "=== done $(date +%F' '%H:%M:%S) ==="
echo "summary → $SUMMARY"
awk -F, 'NR>1{n++; if($5=="yes") c++} END{printf "completed %d/%d runs\n", c+0, n+0}' "$SUMMARY"
