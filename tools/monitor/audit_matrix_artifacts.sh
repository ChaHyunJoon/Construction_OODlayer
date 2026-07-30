#!/usr/bin/env bash
# ============================================================================================
# 행렬 녹화 산출물 감사: **그 런이 실제로 만든 것만** 그 이름을 달고 있는지 확인한다.
#
# 왜 필요한가 (실제로 난 사고)
# ---------------------------
# render_demo.jl 은 고정 이름 anim/tractor__<case>.html 로 쓰고, 행렬 스크립트는 그걸 정책 이름으로
# 옮긴다(mv). 그런데 **그 런이 애니메이션을 만들지 못한 경우**(빌드 미완주 -> 렌더가 "refusing to
# publish incomplete animation" 으로 발행 거부) 그 자리에는 **이전 런이 남긴 낡은 파일**이 그대로
# 있다. 스크립트는 그걸 옮겨서, 실제로는 다른 런의 애니메이션에 현재 정책 이름을 붙여 버린다.
#
# 화면에서는 "fault_zone / dspy 의 애니메이션"으로 보이지만 내용은 몇 시간 전 canonical 런의
# 것이다. 이런 산출물은 **없느니만 못하다** — 그래서 지우고, 화면에는 "생성되지 않음"이 뜨게 한다.
#
# 판정 기준: 로그에 "refusing to publish" 가 있으면 그 조합의 anim 은 존재해선 안 된다.
#
# 사용법:  bash tools/monitor/audit_matrix_artifacts.sh          # 검사만
#          bash tools/monitor/audit_matrix_artifacts.sh --fix    # 잘못된 파일 삭제
# ============================================================================================
set -u
cd "$(dirname "$0")/../.."
STREAMS=tools/monitor/streams
ANIM=tools/monitor/anim
LOGD=tools/monitor/regen_case_logs
FIX=0; [ "${1:-}" = "--fix" ] && FIX=1

CASES="none battery fault zone fault_battery fault_zone battery_zone battery_mild"
POLS="canonical surrogate dspy"
bad=0

for c in $CASES; do
  for p in $POLS; do
    log="$LOGD/${c}__${p}.log"
    anim="$ANIM/tractor__${c}__${p}.html"
    strm="$STREAMS/tractor__${c}__${p}.jsonl"
    [ -f "$log" ] || continue

    if grep -aq "refusing to publish" "$log"; then
      if [ -f "$anim" ]; then
        bad=$((bad+1))
        echo "  [잘못됨] $c/$p : 렌더가 발행을 거부했는데 anim 파일이 있음 (다른 런의 낡은 파일)"
        [ $FIX -eq 1 ] && { rm -f "$anim"; echo "            -> 삭제함"; }
      else
        echo "  [정상]   $c/$p : 미완주 -> anim 없음 (의도된 동작)"
      fi
    fi

    if [ -f "$strm" ] && [ ! -s "$strm" ]; then
      bad=$((bad+1))
      echo "  [잘못됨] $c/$p : 스트림이 0바이트"
      [ $FIX -eq 1 ] && { rm -f "$strm"; echo "            -> 삭제함"; }
    fi
  done
done

echo
if [ $bad -eq 0 ]; then echo "이상 없음"; else
  echo "문제 $bad 건" ; [ $FIX -eq 0 ] && echo "--fix 를 붙이면 삭제합니다"
fi
