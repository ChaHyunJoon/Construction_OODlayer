#!/usr/bin/env bash
# ============================================================================================
# tractor 8 케이스 × 3 정책 = 24 녹화. 대시보드에서 (케이스, 실행정책) 두 축으로 골라 볼 수 있게.
#
# 왜 24 번인가
# ------------
# 한 번의 실행은 이미 **세 정책의 판단을 모두** 기록한다(policy.jl decide_all). 그래서 "세 정책이
# 무엇을 골랐을까"만 보려면 케이스당 1 번이면 된다(regen_all_cases.sh 가 그것).
# 이 스크립트는 다른 것을 본다: **각 정책을 실제로 실행했을 때 시뮬레이션 결과가 어떻게 갈리는가**
# (완주/미완주, makespan, 로봇 궤적). 그건 정책마다 세계가 달라지므로 따로 돌려야 한다.
#
#   DEMO_ROUTER=0  라우터가 실행을 정하지 못하게 끈다 -> DEMO_POLICY 가 런 전체에 고정된다.
#                  단, 라우터의 **판정 자체는 참고용으로 계속 기록**된다(policy.jl route 의 advisory).
#                  그래서 화면에서 "라우터였다면 여기로 보냈을 것 / 이번 녹화는 canonical 고정" 을
#                  나란히 볼 수 있다.
#
# 출력
#   streams/tractor__<case>__<policy>.jsonl
#   anim/tractor__<case>__<policy>.html
#   (render_demo.jl 은 이름을 고정으로 쓰므로 실행 후 이름을 바꾼다)
#
# 사전조건
#   · DSPy 서비스가 떠 있을 것. 주소는 DSPY_URL 로 준다(기본 :8077).
#     서비스가 없으면 surrogate/dspy 결정이 canonical 로 폴백되고 그 사실이 verdict 에 남는다.
#   · 순차 실행이어야 한다 — 렌더가 MeshCat(8700)을 쓰므로 병렬로 돌리면 충돌한다.
#
# 사용법
#   bash tools/monitor/regen_case_policy_matrix.sh                 # 24 개 전부
#   bash tools/monitor/regen_case_policy_matrix.sh fault zone      # 이 케이스들만 (× 3 정책)
#   DEMO_POLICIES="canonical dspy" bash ... /regen_case_policy_matrix.sh   # 정책 일부만
# ============================================================================================
set -u
cd "$(dirname "$0")/../.."                      # ConstructionBots.jl
LOGD=tools/monitor/regen_case_logs; mkdir -p "$LOGD"
STREAMS=tools/monitor/streams
ANIM=tools/monitor/anim; mkdir -p "$ANIM"

DSPY_URL="${DSPY_URL:-http://127.0.0.1:8077}"
export DSPY_URL
export DEMO_ROUTER=0                            # 실행 정책을 고정한다(판정은 계속 기록됨)
# OOD 추첨 seed. 로봇 OOD(fault/battery)의 발화 스텝·종류가 이 값으로 정해진다(zone 은 pre-sim 고정).
# 한 매트릭스 안에서는 **같은 seed** 여야 24 개 녹화가 같은 교란을 두고 정책만 다른 비교가 된다.
export DEMO_SEED="${DEMO_SEED:-1}"

curl -s --max-time 5 "$DSPY_URL/health" >/dev/null \
  || echo "!! DSPy service not reachable at $DSPY_URL — surrogate/dspy 결정이 canonical 로 폴백됩니다"

CASES=("$@")
[ ${#CASES[@]} -eq 0 ] && CASES=(none battery fault zone fault_battery fault_zone battery_zone battery_mild)
POLICIES=(${DEMO_POLICIES:-canonical surrogate dspy})

total=$(( ${#CASES[@]} * ${#POLICIES[@]} ))
i=0
echo "=== $total runs (${#CASES[@]} cases × ${#POLICIES[@]} policies) start $(date +%H:%M:%S) ==="

for case in "${CASES[@]}"; do
  # ⑦ battery_mild 는 별도 케이스가 아니라 battery 를 애매한 SoC(0.45)로 돌린 것이다.
  ood="$case"; extra=()
  if [ "$case" = "battery_mild" ]; then ood="battery"; extra=(DEMO_BSOC=0.45); fi

  for pol in "${POLICIES[@]}"; do
    i=$((i+1))
    echo "== [$i/$total] $case / $pol ($(date +%H:%M:%S)) =="
    src_stream="$STREAMS/tractor__${ood}.jsonl"
    src_anim="$ANIM/tractor__${ood}.html"
    dst_stream="$STREAMS/tractor__${case}__${pol}.jsonl"
    dst_anim="$ANIM/tractor__${case}__${pol}.html"

    # ---- 실행 전에 고정 이름 자리를 **비운다** ------------------------------------------
    # 안 비우면 이런 사고가 난다(실제로 났다): 이번 런이 애니메이션 발행을 거부해도
    # (빌드 미완주 -> "refusing to publish incomplete animation") 그 자리에는 **이전 런의 낡은
    # 파일**이 남아 있고, 아래 mv 가 그걸 이번 정책 이름으로 붙여 버린다. 화면에는
    # "fault_zone / dspy 의 애니메이션"으로 보이지만 내용은 몇 시간 전 다른 런의 것이 된다.
    # 비워두면 "이번 런이 만든 것"만 옮겨진다.
    rm -f "$src_stream" "$src_anim"

    env DEMO_MODEL=tractor.mpd DEMO_OOD="$ood" DEMO_POLICY="$pol" "${extra[@]}" \
      julia +lts --project=. tools/monitor/render_demo.jl \
      > "$LOGD/${case}__${pol}.log" 2>&1
    rc=$?

    if [ -s "$src_stream" ]; then
      mv -f "$src_stream" "$dst_stream"
      lines=$(wc -l < "$dst_stream")
      if [ -s "$src_anim" ]; then
        mv -f "$src_anim" "$dst_anim"
        echo "   exit=$rc  -> $(basename "$dst_stream") ($lines frames) + anim"
      else
        rm -f "$dst_anim"      # 옛 실행이 남긴 잘못된 파일이 있으면 함께 치운다
        echo "   exit=$rc  -> $(basename "$dst_stream") ($lines frames), anim 없음(미완주면 정상)"
      fi
    else
      echo "   exit=$rc  !! 스트림이 비었습니다 — $LOGD/${case}__${pol}.log 확인"
    fi
    tr '\r' '\n' < "$LOGD/${case}__${pol}.log" \
      | grep -aE "\[router\]|\[policy\]|PROJECT (COMPLETE|INCOMPLETE)" | tail -3 | sed 's/^/   /'
  done
done

echo "=== done $(date +%H:%M:%S) ==="
ls -1 "$STREAMS"/tractor__*__*.jsonl 2>/dev/null | wc -l | xargs echo "matrix streams on disk:"

# ---- 마무리 두 단계 (빼먹으면 화면이 빈다) --------------------------------------------------
# 1) 기존 이름 복구: 위 mv 가 tractor__<case>.jsonl 을 가져갔으므로, 대시보드 드롭다운의 기본값
#    `auto` 가 가리키는 파일이 사라진다. 정책 녹화 하나를 그 이름으로 되돌려 놓는다.
# 2) 감사: 이번 런이 만들지 않은 산출물이 섞여 있지 않은지 확인한다.
# julia 가 완전히 빠져나갈 때까지 잠깐 기다린다. 마지막 렌더가 끝난 직후에는 프로세스가 잠시
# 남아 있어서, 복구 스크립트의 "렌더 실행 중" 가드에 **자기 자신이 걸린다**(실제로 걸렸다).
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ps -W 2>/dev/null | grep -qi 'julia' || break
  sleep 3
done
echo; bash tools/monitor/restore_legacy_streams.sh
echo; bash tools/monitor/audit_matrix_artifacts.sh
