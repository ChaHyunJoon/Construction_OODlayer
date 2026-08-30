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
#   라우터가 레인을 고르면 `decide_all` 이 `rt["target"]` 에 고른 레인("surrogate"/"dspy")을
#   적고, 안 고르면 `select_lane` 이 안 불려 `target` 이 base policy 이름 그대로 남는다.
#   base 를 policy.jl 이 모르는 "router" 로 두면 그 둘을 **사후에 구분할 수 있다.**
#   🔴 2026-08-29 (§B-1): 이 문단의 옛 기전 서술 — *"route() 가 target 을 덮어쓴다
#   (policy.jl:349)"* 와 *"NOVELTY_CALIB 이 없으면 policy.jl:67-68 이 라우터를 fail-open 으로
#   꺼버린다"* — 은 **둘 다 죽었다.** novelty 축이 삭제돼 `install_novelty!()` 도 그 fail-open
#   경로도 없고, `target` 을 쓰는 곳은 `decide_all` 의 `rt["target"] = sel.lane` 하나다.
#   구분 자체는 그대로 산다(위 문단) — 라우터를 끄는 것은 이제 DEMO_ROUTER=0 / DEMO_POLICY=noop 뿐.
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
# 🔴 2026-08-29 (§B-1): NOVELTY_CALIB 은 **이 렌더에 아무 영향이 없다.** 줄리아 생산 코드에서
# 이 변수를 읽는 곳이 0곳이다(novelty 축 삭제 — 남은 독자는 손으로 돌리는 라이브러리 게이트
# tools/test_router.jl 뿐). 기본값과 export 는 옛 호출 습관과의 호환으로만 남긴다.
NOVELTY_CALIB="${NOVELTY_CALIB:-$REPO_ROOT/wm4spacecraft_manufacturing/novelty/novelty_calibration_no_zoneblk.json}"
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
echo "NOVELTY_CALIB=$NOVELTY_CALIB (inert since 2026-08-29 §B-1 -- no Julia reader)"

# 🔴 2026-08-29 (§B-1, fix round 1 / Ruling R7): 여기 있던 **하드 종료를 지웠다.**
# 옛 문구: *"이대로 진행하면 policy.jl 이 라우터를 fail-open 으로 꺼버려 '라우터 ON' 이라는 이름의
# 렌더가 실제로는 라우터 없이 만들어진다"* (policy.jl:67-68 인용). **그 기전이 없다** — novelty
# 축이 삭제돼 `install_novelty!()` 도 그 fail-open 경로도 존재하지 않고, 교정 파일 유무는 이
# 렌더의 라우팅에 아무 영향이 없다. 그 장벽을 남겨 두면 정반대의 조용한 실패가 된다: 운영자가
# 교정 파일을 넘기고 "라우터가 켜졌다" 고 믿는데 그 파일은 아무 데도 안 읽힌다.
# 🔴 라우터가 실제로 구동됐는지는 **사후에** 잰다 — 아래 (3)절의 `[router]` 로그 세기다.
if [ ! -f "$NOVELTY_CALIB" ]; then
  echo "-- NOVELTY_CALIB 파일이 없다: $NOVELTY_CALIB (무해 — 이 변수를 읽는 줄리아 코드가 없다)"
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

  # ---- (3) 이 판에 OOD **결정**이 있었는가 ------------------------------------------------------
  # 🔴 **이름을 믿지 말 것. 이 검사는 "라우터가 구동됐는가" 를 재지 못한다** (2026-08-29,
  #    fix round 2 실측). 세는 것은 `render_demo.jl` 의 `[router] …` 줄이고, 그 줄의 조건은
  #    **`haskey(rt, "lane_reason")` 하나**다(render_demo.jl 의 `record_decision!` 바로 뒤).
  #    그런데 `policy.jl` 의 `decide_all` 은 `rt["lane_reason"] = sel.reason` 을 **삼항식 뒤에서
  #    무조건** 쓴다 — 라우터가 꺼져 있을 때도 `sel` 이
  #        (lane = POLICY, axis = "fixed", reason = "router off — DEMO_POLICY=… is fixed …")
  #    로 채워지므로 그 키가 **언제나 있다.** ⟹ `n_routed` 는 **OOD 결정이 하나라도 있었으면
  #    ≥1** 이고, DEMO_ROUTER=0 으로 돌려도 똑같이 ≥1 이다. router-on 과 router-off 를
  #    **구분하지 못한다.**
  #
  #    🔴 이 공허는 §B-1 이 만든 것이 **아니다** — 위 두 사실(발화 조건 · 무조건 쓰기)은 전부
  #    `46470d5a~1` 에 이미 있었다(실측). §B-1 이 한 것은 **옛 주석의 거짓 근거를 드러낸 것**뿐이고,
  #    진짜 신호를 고르는 것은 별개의 판단이라 이 커밋의 범위 밖이다(주석만 고친다).
  #    ⚠️ 아래 `router_state` 문자열("ENGAGED"/"NOT ENGAGED")과 `expect_router` 판정도 같은
  #    한계를 진다 — **"ENGAGED" 를 "라우터가 레인을 골랐다" 의 증거로 인용하지 말 것.**
  #    오늘 그것이 실제로 뜻하는 것은 "이 렌더에 OOD 결정이 ≥1 건 있었다" 다.
  #    (참고: 로그의 그 줄은 `axis=<router_axis>` 를 같이 찍고, 라우터가 꺼진 판은 그 값이
  #     `fixed` 다 — 진짜 신호를 만들려면 거기가 출발점이다. 이 커밋은 고르지 않는다.)
  #    [역사] 옛 주석은 *"render_demo.jl:668 은 rt["enabled"]==true 일 때만 찍는다"* 였다 —
  #    줄번호도, 조건도, 키도 틀렸다(`enabled` 는 §B-1 에서 삭제됐다).
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
