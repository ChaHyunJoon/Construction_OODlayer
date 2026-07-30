#!/usr/bin/env bash
# ============================================================================================
# 행렬 녹화(tractor__<case>__<policy>) 에서 **기존 이름**(tractor__<case>) 을 복구한다.
#
# 왜 필요한가
# -----------
# render_demo.jl 은 언제나 고정 이름 tractor__<case>.jsonl 로 쓴다. 행렬 스크립트는 그 파일을
# (케이스, 정책) 이름으로 **옮겨서**(mv) 보관했는데, 그 바람에 기존 이름이 사라졌다.
# 대시보드의 `실행 정책` 드롭다운 기본값이 `auto`(= 기존 이름)라서, 화면을 열면 매트릭스가 지나간
# 케이스가 전부 404 로 보였다(아직 안 돌린 케이스 하나만 멀쩡해 보이는 증상).
#
# 그래서 정책 녹화 하나를 기존 이름으로 되돌려 놓는다. 기본은 canonical(규칙 = 종전 데모의 동작과
# 가장 가까움). DEFAULT_POLICY 로 바꿀 수 있다.
#
# 사용법:  bash tools/monitor/restore_legacy_streams.sh [DEFAULT_POLICY=canonical]
# ============================================================================================
set -u
cd "$(dirname "$0")/../.."
STREAMS=tools/monitor/streams
ANIM=tools/monitor/anim
DEF="${1:-${DEFAULT_POLICY:-canonical}}"
CASES="none battery fault zone fault_battery fault_zone battery_zone battery_mild"

# ---- 렌더가 도는 중에는 건드리지 않는다 ------------------------------------------------------
# render_demo.jl 은 고정 이름 tractor__<case>.jsonl 에 프레임을 이어붙인다. 그 파일을 같은 순간에
# cp 로 덮어쓰면 두 프레임이 한 줄에 섞여 파일이 깨진다(실제로 fault_zone__dspy 를 그렇게 깨뜨렸다).
# 대시보드는 깨진 줄을 조용히 건너뛰므로 알아채기도 어렵다. 최근에 쓰인 파일이 있으면 멈춘다.
#
# 판정 방법을 두 번 바꿨다(둘 다 그럴듯한데 둘 다 틀렸다):
#   ① mtime 이 최근인가       -> 렌더는 프레임을 띄엄띄엄 쓰므로 그 사이에 그냥 통과한다(실패 경험).
#   ② julia 프로세스가 있는가 -> 대시보드 서버(server.jl)도 julia 라 늘 걸린다(쓸모없음).
# 그래서 **파일이 실제로 자라는지**를 본다: 크기 합계를 두 번 재서 변하면 writer 가 있다.
if [ "${1:-}" != "--force" ]; then
  _sz() { find "$STREAMS" -name 'tractor__*.jsonl' -printf '%s ' 2>/dev/null | md5sum; }
  before=$(_sz); sleep 8; after=$(_sz)
  if [ "$before" != "$after" ]; then
    echo "!! 스트림이 지금 커지고 있습니다(렌더 실행 중) — 건드리면 프레임이 섞여 깨집니다."
    echo "   렌더가 끝난 뒤 다시 실행하세요. (강행: --force)"
    exit 2
  fi
fi

echo "기존 이름 복구 (기본 정책 = $DEF)"
for c in $CASES; do
  src=""
  for p in "$DEF" canonical dspy surrogate; do
    [ -s "$STREAMS/tractor__${c}__${p}.jsonl" ] && { src="$p"; break; }
  done
  if [ -z "$src" ]; then
    if [ -s "$STREAMS/tractor__${c}.jsonl" ]; then
      echo "  $c: 정책 녹화 없음, 기존 파일 그대로 유지"
    else
      echo "  $c: 아직 녹화 없음 (건너뜀)"
    fi
    continue
  fi
  cp -f "$STREAMS/tractor__${c}__${src}.jsonl" "$STREAMS/tractor__${c}.jsonl"
  [ -f "$ANIM/tractor__${c}__${src}.html" ] && cp -f "$ANIM/tractor__${c}__${src}.html" "$ANIM/tractor__${c}.html"
  echo "  $c: <- $src"
done
