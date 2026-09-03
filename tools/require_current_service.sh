# 살아 있는 DSPy 서비스가 **이 트리를** 서빙 중인지 판정한다. source 해서 쓴다.
#
# 🔴 왜 (2026-09-03 실측). 08-30/08-31 기동 uvicorn 다섯이 사흘째 `/health` 200 을 냈고, 그
#    다섯 중 어느 것도 `synthesize_multi`(09-02 16:45 도입)를 갖고 있지 않았다. 둘은 cwd 가
#    삭제된 worktree 였다. 그 위에서 잰 "합성이 안 터진다" 는 모델이 아니라 **런처에 대한
#    사실**이었다. 그때까지 이 레포의 사전조건은 `curl .../health >/dev/null` 넷이었는데,
#    그 검사는 **200 이면 통과**라 다섯 전부를 통과시켰을 것이다(그리고 넷 중 셋은 실패해도
#    경고만 찍고 런을 계속했다).
#
# 🔴 판정식을 여기 적지 않는다 — 정본은 `src/respec/llm_service/generation.py` 의
#    `check_health` 하나다. 셸이 자기 판정을 들면 두 벌이 되고, 이 레포는 그 실패 모양을
#    이미 여러 번 밟았다.
#
# 사용:
#   source "$(dirname "$0")/../require_current_service.sh"     # 경로는 호출자 기준
#   require_current_service "$DSPY_URL" || exit 3
#   REQUIRE_SYNTH_MULTI_AGENT=1 ... 이면 합성 레인이 켜져 있는지도 함께 요구한다.

require_current_service() {
  local url="${1:?require_current_service: URL 이 필요하다}"; shift || true
  local repo py d
  # 🔴 루트를 **마커로** 찾는다. 예전엔 `dirname "${BASH_SOURCE[0]}"` 였는데, 이 변수는
  #    zsh 에서 비어 있다(실측 2026-09-03: zsh 에서 source 하면 루트가 `$HOME` 으로 잡혀
  #    "generation.py 가 없다" 는 **거짓 사유**로 실패했다 — 닫히는 쪽으로 틀린 것이 다행이었을
  #    뿐이다). 마커는 이 게이트가 실제로 부르는 파일 그 자체다: 그것이 없으면 게이트도 없다.
  d="${REPO_ROOT:-$PWD}"
  repo=""
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/src/respec/llm_service/generation.py" ]; then repo="$d"; break; fi
    d="$(dirname "$d")"
  done
  if [ -z "$repo" ]; then
    echo "[generation] FAIL no_repo — \$PWD($PWD) 위쪽에서 src/respec/llm_service/generation.py 를 못 찾았다." \
         "레포 안에서 부르거나 REPO_ROOT 를 주고 부를 것."
    return 2
  fi
  py="$repo/.venv/bin/python"
  # 🔴 폴백을 조용히 두지 않는다: venv 가 없으면 그 사실을 찍고 시스템 python 으로 간다.
  #    (게이트가 "환경이 반쯤 깨졌을 때" 침묵하면 게이트가 아니다.)
  if [ ! -x "$py" ]; then
    echo "-- require_current_service: $py 가 없다 — python3 로 진행한다"
    py=python3
  fi
  local extra=()
  [ -n "${REQUIRE_SYNTH_MULTI_AGENT:-}" ] && extra+=(--require-multi-agent)
  [ -n "${REQUIRE_TOOL_SYNTHESIS:-}" ] && extra+=(--require-tool-synthesis)
  "$py" "$repo/src/respec/llm_service/generation.py" --url "$url" "${extra[@]}" "$@"
}
