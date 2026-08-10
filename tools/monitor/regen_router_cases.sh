#!/usr/bin/env bash
# tools/monitor/regen_router_cases.sh
# ============================================================================================
# 실패 case 3종(battery/fault/zone) 을 **라우터 ON**(DEMO_ROUTER=auto, DEMO_POLICY=router) 으로
# 각 1판씩 렌더한다. 사용자 요구의 하드 산출물: 대시보드(dashboard.html)가 이 세 판을
# "router" 정책으로 띄워 볼 수 있어야 한다.
#
# tools/monitor/{streams,anim}/ 는 2026-08-09 정리로 지워졌고 git-ignored 이므로, 이 스크립트로
# 다시 만드는 것이 정상 경로다(복원이 아니라 현재 행동 어휘로 새로 렌더한다).
#
# render_demo.jl 을 쓴다 — run_demo.jl 은 스트림만 만들고 애니메이션(MeshCat html)을 안 만든다.
#
# 왜 DEMO_POLICY=router 인가(policy.jl 에 없는 이름이라는 점이 핵심):
#   route() 가 라우터를 실제로 구동하면 target 을 "surrogate"/"dspy" 중 하나로 **덮어쓴다**
#   (policy.jl:349). base policy 이름을 policy.jl 이 모르는 "router" 로 두면, 라우터가 fail-open
#   으로 꺼졌을 때 target 이 그대로 "router" 로 남아 **구동 여부를 사후에 구분할 수 있다**
#   (NOVELTY_CALIB 이 없으면 policy.jl:67-68 이 경고만 찍고 라우터를 꺼버리는 조용한 실패가 있다 —
#   이 스크립트는 그걸 사전에 걸러 죽인다. render_demo.jl:668 의 "[router] ... → <target>" 로그는
#   라우터가 실제로 그 사건을 몰았을 때만 찍힌다).
#
# 산출물 이름(대시보드가 이 이름으로 찾는다. regen_case_policy_matrix.sh:66-91 과 같은 규칙):
#   streams/tractor__<case>__router.jsonl
#   anim/tractor__<case>__router.html
# render_demo.jl 은 이름을 고정(tractor__<case>.*)으로 쓰므로, 실행 후 위 이름으로 옮긴다.
#
# 미완주 처리: publish_anim! 은 빌드가 안 끝난 판의 애니메이션 발행을 거부한다
# (render_demo.jl:1037-1038, error 로 죽음 → julia 종료코드 != 0). 이 스크립트는 그 case 를
# **실패로 기록하고 나머지 case 는 계속 진행**한다 — 절대 조용히 건너뛰지 않는다.
#
# 사전조건
#   · NOVELTY_CALIB 파일이 반드시 있어야 한다(없으면 이 스크립트가 즉시 에러로 죽는다 — 라우터가
#     fail-open 으로 꺼진 채 "라우터 ON" 이라는 이름의 판이 만들어지는 조용한 실패를 막기 위해).
#   · DSPy 서비스가 떠 있을 것(주소는 DSPY_URL). 없으면 dspy/surrogate 결정이 canonical 로
#     폴백되고 그 사실이 verdict 에 남는다 — 다만 라우터의 **판정 자체**(target=surrogate/dspy)는
#     서비스 가용성과 무관하게 계산되므로 "라우터 구동" 판정에는 영향이 없다.
#   · 순차 실행(★ Global Constraint). 렌더가 MeshCat(8700)을 쓰고, julia 시뮬레이션은 이 머신에서
#     언제나 한 프로세스만 떠 있어야 한다(병렬이면 HiGHS 가 다른 스케줄을 내 비교가 무효가 되고,
#     판당 ~2.5GB 라 OOM 도 난다).
#
# 사용법
#   bash tools/monitor/regen_router_cases.sh            # battery/fault/zone 3판 실행
#   bash tools/monitor/regen_router_cases.sh --dry-run   # 아무것도 실행하지 않고 명령/경로만 출력
# ============================================================================================
set -u
cd "$(dirname "$0")/../.."                      # ConstructionBots.jl 레포 루트로 이동
REPO_ROOT="$(pwd)"

# 플래그를 **소비**한다. 예전에는 $1 만 보고 shift 하지 않아서, 뒤에 case 를 붙여 부르면
# `--dry-run` 자체가 case 이름으로 흘러들어갔다(실측: `== [--dry-run] ==`). 모르는 플래그는
# 조용히 무시하지 않고 죽인다 — 이 스크립트는 julia 렌더를 띄우므로 오타가 곧 사고다.
DRY_RUN=0
POS_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -*)        echo "[error] 알 수 없는 인자: $1"; echo "사용법: bash regen_router_cases.sh [--dry-run] [case ...]"; exit 1 ;;
    *)         POS_ARGS+=("$1"); shift ;;
  esac
done
set -- ${POS_ARGS[@]+"${POS_ARGS[@]}"}

LOGD=tools/monitor/regen_router_logs
STREAMS=tools/monitor/streams
ANIM=tools/monitor/anim
mkdir -p "$LOGD"                                 # streams/anim 은 render_demo.jl 이 자동 mkpath 한다

# ---- 오늘 밤의 고정 규약(모두 override 가능하되 기본값은 이 값들) ---------------------------
DSPY_URL="${DSPY_URL:-http://127.0.0.1:8090}"
NOVELTY_CALIB="${NOVELTY_CALIB:-$REPO_ROOT/wm4spacecraft_manufacturing/novelty_calibration_no_zoneblk.json}"
export DSPY_URL NOVELTY_CALIB
export DEMO_ROUTER=auto
export DEMO_POLICY=router
export DEMO_ANIM=1
export DEMO_MODEL=tractor.mpd

# 인자로 case 를 주면 그것만, 없으면 기본 3종. 대시보드 버튼의 key 를 그대로 쓴다
# (dashboard.html:795-806): none battery fault zone fault_battery fault_zone battery_zone battery_mild.
# zone 이 들어간 셋(zone·fault_zone·battery_zone)은 운영자가 평면도에 구역을 그려야 시작하므로
# 미리 렌더해 두는 대상이 아니다 — 자동 injector 녹화만 "Load previous recording" 로 본다.
CASES=("$@")
[ ${#CASES[@]} -eq 0 ] && CASES=(battery fault zone)

echo "=== regen_router_cases.sh $([ "$DRY_RUN" -eq 1 ] && echo "(DRY RUN)") ==="
echo "DEMO_MODEL=$DEMO_MODEL DEMO_ROUTER=$DEMO_ROUTER DEMO_POLICY=$DEMO_POLICY DEMO_ANIM=$DEMO_ANIM"
echo "DSPY_URL=$DSPY_URL"
echo "NOVELTY_CALIB=$NOVELTY_CALIB"

# 라우터가 fail-open 으로 꺼진 채 "라우터 ON" 이라는 이름의 판을 만드는 조용한 실패를 막는다.
# (policy.jl:67-68 — 교정파일이 없으면 경고만 찍고 라우터를 끈다. 여기서 미리 걸러 죽인다.)
if [ ! -f "$NOVELTY_CALIB" ]; then
  echo "!! NOVELTY_CALIB 파일이 없다: $NOVELTY_CALIB"
  echo "!! 이대로 진행하면 policy.jl 이 라우터를 fail-open 으로 꺼버려, '라우터 ON' 이라는 이름의"
  echo "!! 렌더가 실제로는 라우터 없이 만들어진다 — 진행하지 않는다."
  echo "STATUS render fail cases=0/${#CASES[@]} failed=all:novelty-calib-missing"
  exit 1
fi

if [ "$DRY_RUN" -eq 0 ]; then
  curl -s --max-time 5 "$DSPY_URL/health" >/dev/null \
    || echo "!! DSPy service not reachable at $DSPY_URL — surrogate/dspy 결정이 canonical 로 폴백됩니다" \
           "(라우터 target 판정 자체는 영향받지 않는다)"
fi

ok_cases=()
fail_cases=()

for case in "${CASES[@]}"; do
  # ⑦ battery_mild 는 **실행 케이스와 표시 이름이 다르다**: 애매한 SoC(0.45)로 battery 를 돌린 것이다.
  # render_demo.jl:111 의 DEMO_CASE_TAG 가 산출물 이름을 정하므로, 옛 regen_all_cases.sh 처럼
  # plain battery 로 낸 뒤 mv 로 바꿔치기할 필요가 없다(그 방식은 battery 산출물을 소비해 버려서
  # 끝에 battery 를 한 번 더 렌더해 복원해야 했다).
  run_ood="$case"; extra_env=();
  if [ "$case" = "battery_mild" ]; then
    run_ood="battery"
    extra_env=(DEMO_BSOC=0.45 DEMO_CASE_TAG=battery_mild)
  fi
  # Nominal 은 정의상 OOD 사건이 없다 → 라우터가 부를 결정 자체가 없다. 아래 (3) 검사에서 면제한다.
  expect_router=1; [ "$case" = "none" ] && expect_router=0

  src_stream="$STREAMS/tractor__${case}.jsonl"
  src_anim="$ANIM/tractor__${case}.html"
  dst_stream="$STREAMS/tractor__${case}__router.jsonl"
  dst_anim="$ANIM/tractor__${case}__router.html"
  log="$LOGD/${case}__router.log"

  echo "== [$case] $(date +%H:%M:%S) =="

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] rm -f \"$src_stream\" \"$src_anim\""
    echo "[dry-run] env DEMO_MODEL=$DEMO_MODEL DEMO_OOD=$run_ood ${extra_env[@]+${extra_env[@]}} DEMO_POLICY=$DEMO_POLICY" \
                 "DEMO_ROUTER=$DEMO_ROUTER DEMO_ANIM=$DEMO_ANIM NOVELTY_CALIB=$NOVELTY_CALIB" \
                 "DSPY_URL=$DSPY_URL julia +lts --project=. tools/monitor/render_demo.jl > $log 2>&1"
    echo "[dry-run] on success -> mv \"$src_stream\" \"$dst_stream\"; mv \"$src_anim\" \"$dst_anim\""
    continue
  fi

  # 실행 전에 고정 이름 자리를 비운다. 안 비우면: 이번 런이 애니메이션 발행을 거부해도(빌드
  # 미완주) 그 자리에 **이전 런의 낡은 파일**이 남아 있어 아래 mv 가 그걸 이번 case 이름으로
  # 붙여 버린다(regen_case_policy_matrix.sh 에서 실제로 겪은 사고와 같은 함정).
  rm -f "$src_stream" "$src_anim"

  env DEMO_OOD="$run_ood" "${extra_env[@]}" \
    julia +lts --project=. tools/monitor/render_demo.jl \
    > "$log" 2>&1
  rc=$?

  case_ok=1
  reason=""

  # ---- (1) 스트림: non-empty + 첫 줄이 JSON 이고 sim_t/n_closed/ood 키를 갖는가 ----------------
  if [ ! -s "$src_stream" ]; then
    case_ok=0; reason="empty/missing stream (exit=$rc)"
  else
    mv -f "$src_stream" "$dst_stream"
    firstline=$(head -n1 "$dst_stream")
    # 합격 조건 그대로: 첫 줄이 실제로 json.loads 되고 sim_t/n_closed/ood 키를 갖는가.
    # (grep 부분일치가 아니라 진짜 파싱 — python 은 이 머신에 있다)
    if ! printf '%s\n' "$firstline" | PYTHONIOENCODING=utf-8 python -c '
import json, sys
try:
    d = json.loads(sys.stdin.readline())
except Exception:
    sys.exit(1)
sys.exit(0 if all(k in d for k in ("sim_t", "n_closed", "ood")) else 1)
' >/dev/null 2>&1; then
      case_ok=0
      reason="${reason:+$reason; }stream first line failed json.loads or missing sim_t/n_closed/ood"
    fi
  fi

  # ---- (2) 애니메이션: publish_anim! 이 발행했는가(미완주면 거부 -> 파일 없음) -------------------
  if [ -s "$src_anim" ]; then
    mv -f "$src_anim" "$dst_anim"
    # 대시보드의 **기본 선택**은 `<option value="">auto (legacy / router run)</option>` 이고,
    # value 가 빈 문자열이라 dashboard.html:1443 의 `if(curEnacted){...}` 가지가 통째로 건너뛰어진다.
    # 그러면 /artifact 요청에 policy 필드가 빠지고 서버는 접미사 없는 `tractor__<case>.html` 을 푼다
    # (server.jl:216). 스트림 쪽만 접미사를 떼는 폴백이 있고(dashboard.html:883) 애니에는 없어서,
    # __router 이름만 두면 좌측 패널은 다 살아 있는데 3D 만 "not generated yet" 으로 뜬다(실측).
    # → 라우터 런은 **접미사 없는 이름으로도** 낸다. 그 옵션의 이름이 곧 "router run" 인 이유다
    #   (라우터 런은 사건마다 enacted 가 달라 단일 정책 접미사가 성립하지 않는다).
    #   ENACTED POLICY 를 명시적으로 `router` 로 고르면 __router 이름이 그대로 쓰인다 — 둘 다 둔다.
    cp -f "$dst_stream" "$src_stream"          # src_* 가 곧 접미사 없는 legacy 이름이다(92-93행)
    cp -f "$dst_anim"   "$src_anim"
    touch "$src_anim"                          # 신선도 검사(server.jl:225): 애니 >= 스트림 이어야 보인다
  else
    rm -f "$dst_anim"      # 옛 실행이 남긴 파일이 있으면 함께 치운다(같은 이유로 비워두는 것)
    case_ok=0
    reason="${reason:+$reason; }no anim (build incomplete -- publish_anim! refused, see $log)"
  fi

  # ---- (3) 라우터가 실제로 구동됐는가 ------------------------------------------------------------
  # render_demo.jl:668 은 rt["enabled"]==true 일 때만(=라우터가 이 사건의 실행 정책을 정했을 때만)
  # "[router] ... → <target>" 을 찍는다(target 은 항상 surrogate/dspy). 한 줄도 없으면 라우터가
  # fail-open 으로 꺼졌거나(교정 불일치 등) OOD 사건 자체가 없었다는 뜻 -- 둘 다 이번 렌더가
  # "라우터 ON" 산출물이 아니라는 신호다.
  n_routed=$(tr '\r' '\n' < "$log" | grep -ac '^\[router\]')
  if [ "$n_routed" -gt 0 ]; then
    router_state="ENGAGED ($n_routed decisions routed)"
    # Nominal 인데 라우팅이 일어났다면 "사건 없음" 전제가 깨진 것이다 — 조용히 넘기지 않는다.
    if [ "$expect_router" -eq 0 ]; then
      case_ok=0
      reason="${reason:+$reason; }case=none 인데 라우터가 $n_routed 건 라우팅했다(OOD 가 샜다)"
    fi
  elif [ "$expect_router" -eq 0 ]; then
    router_state="n/a (Nominal — OOD 사건이 없으므로 라우팅할 결정 자체가 없다)"
  else
    router_state="NOT ENGAGED (no '[router] ... -> target' line in log)"
    case_ok=0
    reason="${reason:+$reason; }router did not engage"
  fi

  if [ "$case_ok" -eq 1 ]; then
    ok_cases+=("$case")
    echo "   OK   exit=$rc  router=$router_state  -> $(basename "$dst_stream") + $(basename "$dst_anim")"
  else
    fail_cases+=("${case}:${reason}")
    echo "   FAIL exit=$rc  router=$router_state  reason=$reason"
  fi
  tr '\r' '\n' < "$log" | grep -aE '\[router\]|\[policy\]|PROJECT (COMPLETE|INCOMPLETE)' | tail -5 | sed 's/^/   /'
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== dry-run done -- nothing executed ==="
  echo "STATUS render dryrun cases=0/${#CASES[@]} failed=(dry-run only)"
  exit 0
fi

echo "=== done $(date +%H:%M:%S) — ${#ok_cases[@]}/${#CASES[@]} ok ==="

if [ "${#fail_cases[@]}" -eq 0 ]; then
  echo "STATUS render ok cases=${#ok_cases[@]}/${#CASES[@]} failed=none"
  exit 0
else
  failed_join=$(IFS=,; echo "${fail_cases[*]}")
  echo "STATUS render fail cases=${#ok_cases[@]}/${#CASES[@]} failed=${failed_join}"
  exit 1
fi
