# tools/monitor/zone_gate.jl
# =============================================================================
# **zone 사건을 이 판에서 심을 것인가** — 두 엔진(run_demo.jl · render_demo.jl)의 단일 진실원.
#
# 왜 별도 파일인가 (2026-08-25)
# -----------------------------
# 2026-08-24 (spec §5.1) 가 zone 을 행동 어휘와 `case_kinds` 에서 뺐다. 그 결과 두 엔진의 zone
# 주입 블록이 전부 `if :zone in kinds` 뒤에 갇혔는데, `case_kinds` 는 zone 계열 인자를 **error 로
# 거부**하므로 그 조건은 영원히 false 다 — 주입기 넷이 통째로 도달 불가가 됐다. 어휘에서 뺀 것과
# **사건을 심지 않는 것**은 다른 결정인데 한 손잡이에 묶여 있었다. 이 파일이 그 둘을 가른다.
#
# 리터럴을 두 엔진에 복붙하지 않는 이유: 2026-08-16 에 `case_kinds` 의 `all` 분기가 한쪽에만
# 있어서 72판이 조용히 다른 세계로 렌더된 전례가 있다. 손잡이의 진실원은 하나여야 한다.
#
# ⚠️ **이 술어는 `kinds` 를 인자로 받지 않는다.** 그것이 이 파일의 존재 이유이고,
#    `test_zone_gate.jl` 이 시그니처 자체를 계약으로 못박는다.
#
# ENV
#   DEMO_ZONE     1 이면 이 판에 zone 을 심는다. 기본 0 = 2026-08-24 이후 동작 그대로.
#   DEMO_ZONE_AT  "cx,cy,r" 이 있으면 **그 자체가 켜는 신호**다(좌표를 선언해 놓고 판이 조용히
#                 zone 없이 도는 것은 이 레포에서 가장 비싼 실패 모양이다).
# =============================================================================

"""
    zone_requested(demo_zone, zone_at) -> Bool

`DEMO_ZONE` / `DEMO_ZONE_AT` 두 문자열만 보고 판정하는 순수 함수. ENV 를 직접 읽지 않으므로
테스트가 프로세스 환경을 건드리지 않고 전수 검사할 수 있다(`lane_select.jl` 과 같은 규약).
"""
zone_requested(demo_zone::AbstractString, zone_at::AbstractString) =
    strip(demo_zone) == "1" || !isempty(strip(zone_at))

"ENV 판독점. 두 엔진은 이것만 부른다 — 손잡이 이름이 여기 한 곳에만 적히게."
zone_requested() = zone_requested(get(ENV, "DEMO_ZONE", "0"), get(ENV, "DEMO_ZONE_AT", ""))
