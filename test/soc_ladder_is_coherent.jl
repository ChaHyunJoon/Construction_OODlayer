# =============================================================================
# **SoC 임계 넷이 하나의 사다리인가.** (2026-08-31, S1/T3)
#
# 왜 이 파일이 필요한가 — 2026-08-31 실측
# ----------------------------------------
# 임계 셋이 갈라져 (0.1, 0.2] 구간이 조용히 죽어 있었다: 그 구간은 `routing_kind` 가
# `unknown:battery_mild`(LLM 레인)를 내면서 `battery_arms` 는 개입 팔 셋을 다 준다 —
# 즉 그 구간에서 합성 레인은 구조적으로 절대 발화하지 않는다.
# 🔴 그리고 두 임계를 **함께 보는 게이트가 레포에 0개였다**: `test_lane_select.jl` 은
# REPLACE_SOC_THRESHOLD/battery_arms 를 0회 언급하고, 그 시절의 `test/mild_menu_is_noop_only.jl`
# 은 ROUTING_SEVERE_SOC/routing_kind 를 0회 언급했다(이 파일이 생기던 당시 실측 — 그 파일은
# 2026-08-31 뒤이은 정리로 지워졌고, 그 파일이 지키던 명제 (4) 는 `battery_menu_lanes_agree.jl`
# 로 옮겨갔다). 이 파일이 그 사이를 잇는다.
#
# 재는 명제 여섯
#   (1) 라우팅 경계와 메뉴 경계가 **같다** — 사다리 전 구간에서 두 판정이 일치한다
#   (2) 정지 임계가 deep 경계보다 **엄격히 낮다**
#       (같으면 deep 안에 감속 구간이 없어져 battery_ladder_is_deep_only 단언 2 가
#        만족 불가능해진다 — D-6 이 그래서 폐기됐다)
#   (3) severe 데모 프리셋이 **정지 임계 아래로 확실히 떨어진다**
#       soc_after <= 1 - DEMO_BSOC 이므로 (1 - DEMO_BSOC) <= stall 이면 충분하다
#   (4) 두 엔진(run_demo · render_demo)의 DEMO_BSOC·DEMO_STALL_SOC 기본값이 같다
#   (5) 라벨 레인의 DS_STALL 이 실행 레인의 정지 임계와 같다
#   (6) `isdefined(...) ? REPLACE_SOC_THRESHOLD[] : X` / `try...catch; X end` 류 폴백 리터럴이
#       src/·tools/·test/·wm4spacecraft_manufacturing/ 전체에 **하나도 없다**(파일 목록을
#       하드코딩하지 않는다 — 2026-08-31 fix round 1, I-2). 🔴 2026-08-31 (fallback-removal
#       task): 여덟 곳 전부를 없애 이제 명제가 뒤집혔다 — "폴백이 있으면 DEEP 과 같다"(있는
#       것을 전제)가 아니라 **"폴백이 아예 없다"**(더 강한 명제, 재도입 즉시 빨개진다)를 잰다.
#       비어 있는 스캔이 "실패할 수 없는 게이트"가 되는 것은 (6b)의 심은-자리 자기증명이
#       독립적으로 막는다 — 스캐너 자체가 죽었는지는 (6b)가, 실제 트리가 깨끗한지는 (6)이 잰다.
#
# 변이시험 — 2026-08-31, 아래 다섯을 전부 실제로 돌려서 각각의 실패를 직접 봤다
# (task-3-report.md 에 각 mutation 의 실측 출력이 그대로 있다). 넷은 이 파일이 처음부터
# "일으키면 빨개진다"고 적었던 것이고, 다섯째(폴백)는 (3)의 정정과 같이 새로 더한 것이다.
#   · ROUTING_SEVERE_SOC 만 0.2 로 되돌리면 (1)이 빨개진다 — 실측: 8 passed, 3 failed.
#   · STALL_SOC_DEFAULT 를 REPLACE_SOC_THRESHOLD 와 같게 두면 (2)가 빨개진다 — 실측: 1 passed, 1 failed.
#   · 두 엔진 모두 DEMO_BSOC 기본값을 0.9 로 되돌리면 (3)이 빨개진다(1-0.9=0.09999… > STALL=0.05)
#     — 실측: 2 passed, 2 failed.
#   · 두 엔진 중 하나만 DEMO_BSOC 를 고치면(예: run_demo.jl 만 0.97) (4)가 빨개진다 —
#     실측: 2 passed, 1 failed.
#   · 발견된 폴백 자리 중 하나(battery.jl)만 리터럴 0.2 로 되돌리면 (6)이 빨개진다 —
#     실측(fix round 0, 파일 목록을 하드코딩하던 시절): 11 passed, 1 failed. 그 뒤 게이트
#     구조가 두 번 더 바뀌었다(fix round 1: 발견형 스캔, fix round 3: 두 정규식 대안을 따로
#     검사) -- 각 라운드의 실제 mutation 출력은 task-3-report.md 의 해당 라운드 절에 있다
#     (🔴 이 문장이 가리키던 옛 버전은 "fix round 2 절 참고"였는데 그 절엔 이 특정
#     mutation 이 없었다 -- 존재하지 않는 곳을 가리키는 죽은 참조였다. 2026-08-31 fix round 3
#     (리뷰 nit)에서 고쳤다).
#   · 🔴 2026-09-01 (S1 final wave / F-1). 이 리뷰가 실측으로 뚫었던 다섯 자리를 오늘 실제로
#     다시 돌려서 확인했다(전부 (6c)/(6) 대상):
#       - `wm4spacecraft_manufacturing/oracle/ood_mdp_shim.jl::valid_actions` 의
#         `thr = Float64(CB.REPLACE_SOC_THRESHOLD[])` 를
#         `thr = max(0.2, Float64(CB.REPLACE_SOC_THRESHOLD[]))` 로 심으면(라벨 레인이 옛
#         0.2 경계로 조용히 돌아가는 그 자리) -- 이전엔 전체 Julia 스위트가 2192/0/1 로
#         byte-identical 이었는데, 지금은 (6c) 가 즉시 잡는다: 실측 `2 passed, 1 failed`
#         (`wm4spacecraft_manufacturing/oracle/ood_mdp_shim.jl=0.2` 로 진단 출력에 찍힌다).
#         복구 확인: 원본 복사본을 되돌리면 다시 2/2 전부 초록. 🔴 2026-09-01 (correction
#         pass, C-4) 정정: 바로 이 문장이 예전엔 "3/3" 이라고 적었는데 틀렸다 -- 베이스라인
#         (6c) 는 히트 1곳(정의 자리 `ood_truth.jl=0.1`)뿐이라 `@test length(prox_hits) > 0`
#         하나 + 루프 단언 하나 = **2** 개다. "3" 은 심은 상태(히트 2곳 -> 1 + 2 = 3)의 개수를
#         복구 뒤에도 그대로 인용한 것이었다(final-fix-wave-rereview.md "New breakage" 항목 2).
#       - `+0.2`/`2e-1`/`1//5`/`.2` 네 철자를 임시 디렉터리에 심어 `TERNARY_RE`/
#         `scan_proximity_literals` 로 직접 스캔 -- 넷 다 이제 잡히고, `_parse_soc_literal` 이
#         넷 다 `0.2` 로 정확히 읽는다(재현: 아래 함수들을 대화형으로 부른 실측, 이 파일
#         커밋과 함께 기록됨).
#     이 다섯은 이제 (6c) 진단에서 빨간다 -- 아래 (a)/(b) 절이 그 수정이다.
#
# 🔴 **2026-08-31 실측 정정 — 계획 초안의 Step 2 음성대조 주장은 과장이었다.** 계획 초안은
#    "오늘의 HEAD 에 STALL=0.15 를 박으면 (1)(2)(3) 전부 빨갛다" 고 적었으나, 실제로 돌려
#    보면 **(1) 만 빨갛다(7 passed, 4 failed)**. (2)·(3)·(4)·(5)는 초록으로 남는다(당시
#    실측: 2/2, 4/4, 3/3, 3/3 전부 통과) — `0.15 < 0.2`(deep, 당시 HEAD 값)가 이미 참이고
#    `1.0 - 0.9 = 0.10 <= 0.15`(당시 STALL 스텁)도 이미 참이었기 때문이다. 이 파일이 HEAD 에서
#    실제로 잡던 결함은 (1)의 4 fail 뿐이었다 — 나머지는 위 변이시험처럼 T3 완료 뒤 값을
#    바꿔서 개별적으로 다시 확인해야 "잡는다"고 말할 수 있고, 위 다섯 줄이 그 실측이다.
#
# 실행: julia +lts --project=. test/soc_ladder_is_coherent.jl
# =============================================================================
module SocLadderIsCoherent

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
isdefined(@__MODULE__, :ActionRegistry) ||
    include(joinpath(REPO, "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))
include(joinpath(REPO, "tools", "monitor", "lane_select.jl"))
const AR = ActionRegistry

const DEEP  = Float64(CB.REPLACE_SOC_THRESHOLD[])
const STALL = Float64(CB.STALL_SOC_DEFAULT[])

"소스에서 리터럴 기본값을 읽는다 — 숫자를 여기 박으면 두 번째 진실원이 된다."
function envdefault(path, name)
    src = read(joinpath(REPO, path), String)
    m = match(Regex("get\\(ENV,\\s*\"$(name)\",\\s*\"([^\"]*)\"\\)"), src)
    m === nothing && error("$(path) 에서 $(name) 기본값을 못 찾았다 — 정규식을 고칠 것")
    return m.captures[1]
end

"`envdefault` 와 같은 이유(두 번째 진실원 방지) -- `get(ENV, ...)` 가 아니라 `Base.@kwdef`
구조체 필드의 리터럴 기본값(`name::Float64 = 값`)을 소스에서 읽는다. `hazard.jl` 의
`cell_mild_lo/hi` 처럼 ENV 손잡이가 아닌 상수를 지키는 자리에 쓴다."
function fielddefault(path, name)
    src = read(joinpath(REPO, path), String)
    m = match(Regex("$(name)::Float64\\s*=\\s*([0-9]*\\.?[0-9]+)"), src)
    m === nothing && error("$(path) 에서 $(name) 필드 기본값을 못 찾았다 — 정규식을 고칠 것")
    return m.captures[1]
end

@testset "(1) 라우팅 경계와 메뉴 경계가 같다" begin
    for s in (0.0, 0.02, 0.05, DEEP - 1e-9, DEEP, nextfloat(DEEP), 0.15, 0.2, 0.3, 0.45, 0.9)
        local severe_by_routing = routing_kind("BatteryTruth", s) == "battery"
        local severe_by_menu    = length(AR.battery_arms(s, DEEP, true)) > 1
        @test severe_by_routing == severe_by_menu
    end
end

@testset "(2) 정지 임계가 deep 보다 엄격히 낮다" begin
    @test STALL < DEEP
    # 그래야 deep 안에 "정지하는 칸"과 "감속만 하는 칸"이 둘 다 존재할 수 있다.
    @test AR.battery_arms(STALL, DEEP, true) == AR.battery_arms(DEEP, DEEP, true)
end

@testset "(3) severe 프리셋이 정지 임계 아래로 확실히 떨어진다" begin
    for f in ("tools/monitor/run_demo.jl", "tools/monitor/render_demo.jl")
        local drop = parse(Float64, envdefault(f, "DEMO_BSOC"))
        # soc_after = max(floor_soc=0.0, soc_at_fire - drop) <= 1.0 - drop
        @test (1.0 - drop) <= STALL
        @test (1.0 - drop) <= DEEP        # 라우팅도 severe 로 간다
    end
end

@testset "(4) 두 엔진의 배터리 기본값이 같다" begin
    for name in ("DEMO_BSOC", "DEMO_STALL_SOC")
        @test envdefault("tools/monitor/run_demo.jl", name) ==
              envdefault("tools/monitor/render_demo.jl", name)
    end
    @test parse(Float64, envdefault("tools/monitor/run_demo.jl", "DEMO_STALL_SOC")) === STALL
end

@testset "(5) 라벨 레인의 정지 임계가 실행 레인과 같다" begin
    local gen = "wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl"
    @test parse(Float64, envdefault(gen, "DS_STALL")) === STALL
    # 학습 사다리의 모든 칸이 새 경계에서도 비교 가능해야 한다(battery_ladder_is_deep_only
    # 단언 1 과 같은 명제를 새 경계에서 다시 확인한다 — 그 파일과 겹치는 것이 의도다).
    for s in [parse(Float64, x) for x in split(envdefault(gen, "DS_BSOC"), ",")]
        @test length(AR.battery_arms(s, DEEP, true)) > 1
    end
end

# 2026-08-31 parked-constants 태스크 -- T3 가 부지된 두 자리를 여기서 마저 잇는다.
# (7)은 (5)와 같은 명제(deep 안에서 대조가 있다)를 에피소드 모드의 severity 자리에 다시
# 묻고, (8)은 정반대 방향(mild 로 남아야 하는 자리가 실제로 mild 인가)을 묻는다 -- 사다리
# 전체가 "훈련 축은 deep 안, 배경 소음 축은 deep 밖" 이라는 하나의 불변식으로 맞물려야 한다.
@testset "(7) 에피소드 모드 DS_EP_BSOC 는 deep 안에서 대조가 있다" begin
    # DS_EP_BSOC 는 (5)의 DS_BSOC 와 달리 사건 뒤 SoC(절대값) 하나뿐인 스칼라다(comma 사다리
    # 아님) -- gen_oracle_dataset.jl EP_SEV[:battery] 참고. `DS_BSOC_MODE=abs` 규약과 같으므로
    # (5)와 같은 함수(`AR.battery_arms(soc, DEEP, true)`)로 바로 잰다.
    local gen = "wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl"
    local s = parse(Float64, envdefault(gen, "DS_EP_BSOC"))
    @test length(AR.battery_arms(s, DEEP, true)) > 1
end

@testset "(8) cell_mild_lo/hi 는 mild(대조 없음)로 남는다 -- (7)과 반대 방향 가드" begin
    # hazard.jl 의 cell_mild_lo/hi 는 DS_BSOC/DS_EP_BSOC 같은 훈련 사다리가 아니라
    # `_hz_fire_cell!` 이 배경에서 확률적으로 굴리는 열화 모형의 "가벼운" 갈래다
    # (`cell_severe_frac`=0.5 가 나머지 절반을 깊은 방전으로 이미 가른다). 여기선 대조가
    # **있으면** 오히려 틀린다 -- `policy.jl:804` `canonical_macro(env, truth)` 가
    # `valid_macros` 에 SwapBattery 가 없을 때 그 답을 NOOP 으로 투영하는 것이 설계이므로
    # (`baselines.jl:176-179`), 이 값이 deep 으로 새면 "mild" 라는 이름과 그 설계가 어긋난다.
    local hz = "src/smdp/hazard.jl"
    local lo = parse(Float64, fielddefault(hz, "cell_mild_lo"))
    local hi = parse(Float64, fielddefault(hz, "cell_mild_hi"))
    # 만충(soc_before=1.0) 기준 최소/최대 결과 SoC 둘 다 mild 안에 머물러야 한다 -- 최소
    # 결과 SoC 는 최대 낙폭(hi)에서, 최대 결과 SoC 는 최소 낙폭(lo)에서 나온다.
    @test length(AR.battery_arms(1.0 - hi, DEEP, true)) == 1
    @test length(AR.battery_arms(1.0 - lo, DEEP, true)) == 1
end

# 폴백 정규식 -- REPLACE_SOC_THRESHOLD 를 못 읽을 때 쓰는 리터럴을 두 형태로 잡는다.
# 🔴 2026-08-31 fix round 3 (R3-2): 예전에는 이 둘을 하나의 `FALLBACK_RE` 로만 두고
# `length(hits) > 0` 하나로 지켰다 -- 그런데 그 어서션은 **완전 실명**만 잡는다. 두 대안 중
# 하나만 매치를 멈추면(예: 누군가 정규식을 고치다 한쪽을 깨면) 8곳이 조용히 5곳(또는 3곳)으로
# 줄어들고도 `length(hits) > 0` 은 여전히 참이라 초록으로 남는다 -- "모든 폴백이 일치한다"는
# 보장이 "살아남은 한쪽 대안이 본 폴백만 일치한다"로 조용히 줄어드는 것이다. 개수를 손으로
# 박는 대신(그러면 다시 I-2 식 하드코딩이 된다), **대안 두 개를 따로 컴파일해 각각 최소
# 1건은 찾아야 한다**고 요구한다 -- 오늘 실제로 두 형태 다 살아 있는 자리가 있으므로
# (ternary 셋, try/catch 다섯) 이 요구는 손 안 대도 계속 참이고, 어느 한쪽이 실명하면
# 그 즉시 그 갈래의 `@test length(...) > 0` 이 빨개진다. 발견 총량은 여전히 목록에 안 기대고
# 스캔한다(파일 목록 하드코딩 금지, I-2 는 그대로 지킨다).
# 🔴 2026-09-01 (S1 final wave / F-1, 리뷰 실측 task-3-rereview4 항목 1): 숫자 리터럴
# 패턴을 소수(`[0-9]*\.?[0-9]+`)에서 부호·지수·유리수까지 받게 넓힌다 — 옛 패턴은
# `+0.2` / `2e-1` / `1//5` 세 철자를 전부 놓쳤다(실측, 8곳이 조용히 12곳처럼 GREEN).
# (6)/(6b) 는 이 캡처를 **개수 존재 여부**로만 쓰고 Float64 로 파싱하지 않으므로("REPLACE_SOC_THRESHOLD
# 폴백 리터럴이 하나도 없다" 는 파싱이 필요 없는 명제다), 이 확장에 파싱 위험이 없다.
const NUM_RE = "[+-]?(?:[0-9]*\\.[0-9]+(?:[eE][+-]?[0-9]+)?|[0-9]+[eE][+-]?[0-9]+|[0-9]+//[0-9]+)"

# 🔴 2026-09-01 (correction pass, C-1): 위 문단이 세던 세 철자(부호·지수·유리수) 확장은
# **정수 리터럴**(`: 0`, `catch; 0 end`)을 조용히 깼다 -- 옛 정규식(`[0-9]*\.?[0-9]+`)은 정수를
# 잡았는데 `NUM_RE` 는 소수점·지수·`//` 중 하나를 요구해서 안 잡는다(음성대조 실측: `test/`
# 안에 `? SYM[] : 0` / `catch; 0 end` / `? SYM[] : 1/5` / `? SYM[] : 2/10` 넷을 심고 이 파일을
# 돌리면, `NUM_RE` 그대로는 (6) 이 초록으로 남고 -- 아래 `FALLBACK_NUM_RE` 로 바꾸면 4/4 전부
# 잡혀 (6) 이 `4 == 0` 로 빨개진다. 심은 파일은 확인 뒤 지웠다 -- final-fix-wave-rereview.md
# F-1(b) 항목 3, "New breakage" 항목 1).
#
# **`NUM_RE` 자체는 고치지 않는다.** (6c)/`scan_proximity_literals` 도 이 상수를 공유해서 쓰는데,
# 거기에 정수·단일 `/` 대안을 더하면 살아있는 트리에서 `REPLACE_SOC_THRESHOLD` 근처 40자 안의
# **무관한** 정수(`PROXIMITY_N=40`, testset 번호 `6`/`4`, 배열 인덱스 `0` 등)까지 리터럴로 잡혀
# (6c) 가 거짓양성으로 빨개진다(실측: 12곳 중 8곳이 `64`/`6`/`4`/`0` 같은 무관 정수 -- 아래
# `PROXIMITY_N` 노트가 경고하던 바로 그 함정이다). 그래서 **정수·단일 `/` 확장은 (6)/(6b) 의
# ternary·catch 정규식(`TERNARY_RE`/`CATCH_RE`)에만** 준다 -- 그 둘은 `REPLACE_SOC_THRESHOLD[] :`
# 또는 `catch;` 바로 뒤 한 자리만 보므로 근접성 스캔과 달리 무관한 정수를 주울 여지가 없다.
const FALLBACK_NUM_RE = "[+-]?(?:[0-9]*\\.[0-9]+(?:[eE][+-]?[0-9]+)?|[0-9]+[eE][+-]?[0-9]+|[0-9]+//[0-9]+|[0-9]+/[0-9]+|[0-9]+)"

"`FALLBACK_NUM_RE`/`NUM_RE` 가 캡처할 수 있는 형태(정수·소수·부호·지수·`a//b` 유리수·단일 `/`
나눗셈) 전부를 `Float64` 로 읽는다 -- `parse(Float64, ...)` 는 `1//5`·`1/5` 같은 나눗셈 표기를
모른다(던진다), 그래서 `//` 또는 `/` 가 있으면 분자/분모로 쪼개 직접 나눈다(`//` 를 먼저
검사한다 -- `1//5` 에도 `/` 가 들어 있어 순서를 바꾸면 `//` 표기가 `/` 갈래로 잘못 쪼개진다)."
function _parse_soc_literal(lit::AbstractString)
    if occursin("//", lit)
        local parts = split(lit, "//")
        return parse(Float64, parts[1]) / parse(Float64, parts[2])
    elseif occursin("/", lit)
        local parts = split(lit, "/")
        return parse(Float64, parts[1]) / parse(Float64, parts[2])
    else
        return parse(Float64, lit)
    end
end
const TERNARY_RE = Regex("REPLACE_SOC_THRESHOLD" * "\\[\\]\\s*:\\s*(" * FALLBACK_NUM_RE * ")")
const CATCH_RE   = Regex("REPLACE_SOC_THRESHOLD" * "\\[\\]\\)\\s*catch;\\s*(" * FALLBACK_NUM_RE * ")\\s*end")
const FALLBACK_RE = Regex(TERNARY_RE.pattern * "|" * CATCH_RE.pattern)

"`dirs` 각각을 재귀적으로 훑어 `.jl` 파일에서 `re` 에 맞는 모든 자리를 찾는다. 각 `d` 는
REPO 상대경로(예: \"src\")이거나 절대경로(예: mktempdir() 결과)일 수 있다 — 후자는 (6b) 가
심는 파일을 REPO 밖의 임시 디렉터리에 두고도 같은 함수로 스캔하기 위해서다(2026-08-31 fix
round 2, N-3: 예전 버전은 test/ 안에 심어서, 프로세스가 write 와 finally 사이에서 죽으면
0.2 리터럴을 담은 파일이 test/ 에 그대로 남아 **다음 실행이 원인 모를 이유로 빨개지는**
위험이 있었다). 반환: (표시용 경로, 캡처된 리터럴 문자열) 쌍의 벡터 — REPO 안쪽 파일은
상대경로로, 밖은 절대경로로 보여 준다. 하드코딩한 파일 목록에 기대지 않는다 — 그래야 새로
생긴 폴백 자리도 잡는다(2026-08-31 fix round 1, I-2)."
function scan_fallback_sites(dirs, re)
    local hits = Tuple{String,String}[]
    for d in dirs
        local root = isabspath(d) ? d : joinpath(REPO, d)
        isdir(root) || continue
        for (dirpath, _, files) in walkdir(root)
            for fn in files
                endswith(fn, ".jl") || continue
                local fpath = joinpath(dirpath, fn)
                local text = read(fpath, String)
                for m in eachmatch(re, text)
                    # 캡처 그룹이 없는 정규식으로 부를 수도 있다((6b)의 "아무것도 안 잡아야
                    # 하는" 마커가 그렇다) — 그때는 매치 전체 문자열을 리터럴로 쓴다.
                    local lit = isempty(m.captures) ? m.match :
                                (m.captures[1] === nothing ? m.captures[2] : m.captures[1])
                    # REPO 안쪽이면 상대경로로 짧게, 밖(임시 디렉터리 등)이면 절대경로 그대로.
                    local shown = startswith(fpath, REPO) ? relpath(fpath, REPO) : fpath
                    push!(hits, (shown, lit))
                end
            end
        end
    end
    return hits
end

# 🔴 2026-08-31 fix round 4 (R4-1): 위 (6)/(6b)/branch-split 은 전부 **정해진 철자**
# (`isdefined(...) ? ...[] : X` 또는 `try...catch; X end`)에 기댄다 -- 리뷰어가 실제로
# 증명했다: 같은 결함을 담은 다른 철자 다섯 개(`catch e; 0.2 end`, 줄바꿈 낀 `catch`,
# `catch; 0.2; end`, `try` **앞**에 리터럴을 두는 형태, `coalesce(...)` 형태)를 심으면
# 이 정규식 두 개가 하나도 못 잡는데도 (6)이 12/12 그린이었다. 그리고 대안 하나를 **완전히
# 안 죽이고 좁히기만**해도(여전히 >=1건은 잡으므로 branch-split 가드는 만족) 진짜 자리를
# 놓칠 수 있다 -- hazard.jl 에서 8곳이 6곳이 됐는데도 그린이었다.
#
# 그래서 "철자의 카탈로그"가 아니라 "기호와의 근접성"으로 다시 잡는다: 주석과 세 겹따옴표
# docstring 을 지운 소스에서 `REPLACE_SOC_THRESHOLD` 라는 글자가 나오는 모든 자리 주변 N 자
# 안의 모든 소수 리터럴을 찾고, (a) 산술 연산자(+-*/^)로 **그 기호 occurrence 자체와** 직접
# 결합된 것(예: `REPLACE_SOC_THRESHOLD[] + 0.22` -- `test/enact_uses_llm_agent.jl` 의
# CTRL_SOC, 문턱보다 0.22 위인 SoC 를 일부러 유도하는 정당한 코드), (b) `max(`/`min(`/`clamp(`
# 의 첫 인자인데 **그 호출 안에 기호가 없는** 것(예: `max(0.0, soc - drop)` -- 바닥값이지
# 폴백이 아니다)만 빼고 나머지는 전부 DEEP 과 같아야 한다고 요구한다.
#
# 🔴 2026-09-01 (S1 final wave / F-1, review task-3-rereview4 항목 2·3): (a)(b) 는 처음에
# **더 헐거웠다** -- "리터럴 바로 앞이 아무 연산자"면 (a)로, "리터럴 바로 앞이 `max(`/`min(`/
# `clamp(` 문자열"이면 (b)로 뺐다. 리뷰어가 실측으로 뚫었다:
#   · **부호 하나로 (a) 를 속인다**: `: +0.2` -- 리터럴 앞의 `+` 가 기호와 아무 관계 없어도
#     "리터럴 앞에 연산자가 있다"는 조건만 보므로 빠졌다(12곳, GREEN). 지금은 기호
#     occurrence 의 끝(또는 시작)과 연산자 사이에 `[]`/공백/필드접근 문자만 있어야 "결합"으로
#     인정한다(`_arith_bound_to_symbol`) -- 무관한 부호는 이제 안 빠진다.
#   · **`max(0.2, REPLACE_SOC_THRESHOLD[])` 가 (b) 로 빠진다**: 옛 (b) 는 "literal 바로 앞이
#     max(/min(/clamp(" 만 봤지 그 호출 **안에 기호가 있는지는 안 봤다** -- 위장 폴백이
#     진짜 바닥값과 같은 모양이었다(14곳, GREEN, 이 finding 의 F-1 자체가 이 심은 자리다).
#     지금은 그 호출의 여는 `(` 부터 닫는 `)` 까지의 범위 안에 기호 occurrence 가 겹치는지
#     확인한다(`_call_floor_exclusion`) -- 겹치면 위장이라 더는 안 뺀다.
#
# N = 40 을 골랐다 -- 실측으로 정했지 추측이 아니다. 처음엔 80으로 시작했는데(위 (a)(b) 제외
# 규칙과 docstring 제거를 더하기 전) 실제 살아있는 트리에 대고 돌려서 세 가지 오탐을 직접
# 봤다: `ood_stream.jl` docstring 안의 "default 1.0"(-> docstring 제거로 고침),
# `hazard.jl` 의 `max(0.0, soc - drop)`(-> max/min/clamp 제외로 고침), 그리고
# `ood_truth.jl` 의 `STALL_SOC_DEFAULT = Ref(0.05)` -- REPLACE_SOC_THRESHOLD 바로 아래 정의된
# **별개의, 의도적으로 다른** 상수인데 주석 제거 후에도 기호 끝에서 약 64자 거리라 80 안에
# 들어왔다. 위 (a)(b) 로는 이 세 번째를 못 걸러서(산술도 아니고 clamp 도 아니다) N 을 64보다
# 작게 줄이는 수밖에 없었다 -- 40 으로 낮추니 사라졌다. 여덟 개 진짜 폴백 자리는 전부 기호
# 끝에서 15~20자 안에 있어(실측) 40 은 그보다 두 배 여유가 있다. 아래에서 실제 트리에 대고
# 돌려 새 오탐이 없음을 확인했다.
#
# 🔴 이게 완전성의 증명은 아니다. N=40 이 잡는 것과 못 잡는 것을 전부 아래에 적는다 --
# 목록이 완결적이라는 인상을 주지 않기 위해 계속 늘려 쓴다(2026-09-01 S1 final wave / F-1(b)):
#
# **아직 남은 사각지대 (전부 실측/재현 완료, 넓히지 않고 그대로 보고한다):**
#   1. **거리 > 40자.** 기호에서 40자보다 먼 곳에 리터럴을 두는 폴백(예: 아주 장황한
#      `coalesce` 나 여러 줄에 걸친 무언가, 또는 `catch; @warn "..."; 0.2 end` 처럼 문자열
#      경고를 끼워 거리를 늘린 형태 -- 실측: 12곳 GREEN)은 안 걸린다.
#   2. **딕셔너리/설정 간접참조.** `const LEGACY_CFG = Dict("deep_soc" => 0.2)` 를 몇 줄 아래
#      함수에서 else-branch 로 쓰는 형태 -- 실측: 12곳 GREEN. 산술도 max/min/clamp 도 아닌
#      "다른 방식으로 리터럴을 기호와 묶는" 코드 전부가 이 범주다.
#   3. **`#`-in-string 이 컴파일되는 코드를 지운다.** 줄 단위 주석 제거(`replace(l, r"#.*$" =>
#      " ")`)는 문자열 리터럴 안의 `#` 를 못 가른다 -- `tag = "battery#deep"; thr = ... : 0.2`
#      처럼 문자열 안에 `#` 을 심으면 스트리퍼가 그 줄의 나머지(진짜 컴파일되는 `0.2`)까지
#      전부 지운다 -- 실측: 12곳 GREEN. 🔴 이 파일의 예전 판은 "주석 안의 폴백은 컴파일 안
#      되니 무해하다"고 적었는데, **이건 주석 안이 아니라 스트리퍼의 오탐으로 실제 컴파일되는
#      코드가 사라지는 것**이라 그 논증이 안 통한다 -- 정정한다.
#      🔴 2026-09-01 (correction pass, C-4) 정정 — 위 1·2·3의 "12곳 GREEN" 세 인용은 **낡은
#      트리에 대고 잰 값이다.** fix round 4 시절(폴백 8곳이 실제로 살아 있던 트리)의 측정을
#      오늘 날짜 절에 그대로 남긴 것 -- 오늘 트리는 실제 폴백이 0곳이라 (6c)의 근접성 히트
#      자체가 1곳(정의 자리 `ood_truth.jl=0.1`)뿐이다. 이 세 사각지대는 여전히 실재하고
#      기제(거리·간접참조·주석-속-문자열)는 오늘도 그대로 성립하지만, "12곳" 이라는 숫자를
#      오늘 트리의 증거로 인용하면 안 된다(final-fix-wave-rereview.md "New breakage" 항목 3).
#   4. **세 겹따옴표가 `#`-주석 한 줄 안에 있으면 docstring 스트리퍼가 오작동한다.**
#      `no_doc = replace(raw, r"\"\"\".*?\"\"\""s => " ")` 는 **주석 여부를 안 보고** 전체
#      텍스트에서 `"""..."""` 쌍을 찾는다 -- `# 예: """ 여기부터"""` 같은 한 줄 주석 안에
#      따옴표 세 개짜리 텍스트가 있으면, 그 주석 뒤에 나오는 **진짜** docstring 의 여는
#      `"""` 와 잘못 짝지어져 그 사이의 진짜 코드가 통째로 지워질 수 있다(재현 안 함 --
#      이 레포의 현재 트리에는 그런 조합이 없다고 grep 으로 확인했으나, 심으면 재현될
#      구조적 결함이다).
#   5. **(6)/(6b) 의 카탈로그(ternary/catch)에 없는 다섯 철자**(`catch e; 0.2 end` 등, 위
#      R4-1 문단 참고)는 (6)/(6b) 수준에서는 여전히 안 잡힌다 -- 이 절 (6c) 가 그 철자들의
#      **일부**(순수 소수 리터럴이 기호 40자 안에 오는 경우)는 잡지만 전부는 아니다(위 1·2·3
#      과 겹치는 경우는 여전히 샌다).
#   6. **🔴 2026-09-01 (correction pass, C-4, 리뷰 실측) 산술 결합이 값을 바꾸는데 잡힌
#      리터럴은 안 바뀐다.** `thr = Float64(REPLACE_SOC_THRESHOLD[]) + 0.1` 처럼 DEEP(오늘
#      0.1)에 산술을 더해 실제 값을 폐기된 경계 0.2 로 되돌려도, (6c)가 뽑아내는 텍스트는
#      더한 결과가 아니라 **소스에 적힌 리터럴 `"0.1"`** 이고 그 리터럴 자체는 DEEP 과 우연히
#      같다 -- 그래서 `_parse_soc_literal(lit) == DEEP` 이 참으로 통과한다. `_arith_bound_to_symbol`
#      이 이 자리를 "정당한 산술"(예: `enact_uses_llm_agent.jl` 의 CTRL_SOC)로 **일부러**
#      봐주는 규칙(R4-1 (a))이기 때문에 걸러지지 않는다 -- 제외 규칙이 스캐너의 눈을 가리는
#      바로 그 자리다. 실측(이 파일 커밋과 함께 기록): `test/` 안에 그 한 줄을 심으면 (6)도
#      (6c)도 전부 그대로 초록(2/2 → 3/3, 새 히트가 `lit=0.1` 로 DEEP 과 일치해서 통과), 심은
#      파일을 지우면 다시 2/2. **정수·단일 `/` 나눗셈 철자(`: 0`·`catch; 0 end`·`1/5`·`2/10`)
#      자체는 C-1 이 (6)/(6b) 의 ternary·catch 정규식에서 복구했다** -- 위 두 형태(`? SYM[] : X`
#      / `catch; X end`)로 쓰인 폴백은 이제 정수·단일 `/` 여도 잡힌다(실측: 4/4 RED). 남는
#      것은 그 두 카탈로그 **밖의** 철자(예: `max(2/10, SYM[])` 처럼 호출 인자로 쓰는 형태) —
#      실측: `test/` 에 `max(2/10, REPLACE_SOC_THRESHOLD[])` 를 심으면 (6)은 애초에 ternary도
#      catch도 아니라서 못 보고, (6c)의 `dec_re` 는 일부러 정수·단일 `/` 를 안 받게 남겨뒀으므로
#      (근접성 스캔까지 넓히면 살아있는 트리에서 `PROXIMITY_N`·testset 번호 같은 무관한 정수가
#      쏟아져 거짓양성이 난다, 위 C-1 노트 참고) 역시 못 본다 -- 완전히 초록. 항목 5 의 "카탈로그
#      밖 철자는 안 잡힌다"의 한 사례다.
const PROXIMITY_N = 40

"리터럴이 `sym` 의 이 occurrence 와 산술 연산자(+-*/^)로 **직접** 묶여 있는가. 두 방향만
인정한다: `SYM ... op LIT`(기호 뒤에 `[]`/공백/필드접근 문자만 끼고 연산자, 그 뒤에 공백만
끼고 리터럴) 또는 그 대칭 `LIT op ... SYM`. 창 안의 다른 위치에 있는 무관한 연산자는 안
걸린다 -- 그래서 부호 하나(`+0.2`)만으로는 더 이상 안 빠진다(F-1, task-3-rereview4 항목 2)."
function _arith_bound_to_symbol(window::AbstractString, lstart::Int, lend::Int, sym_lo::Int, sym_hi::Int)
    if lstart > sym_hi
        local between = window[nextind(window, sym_hi):prevind(window, lstart)]
        match(r"^[\[\]\.\w\s]*([+\-*/^])\s*$", between) !== nothing && return true
    end
    if sym_lo > lend
        local between = window[nextind(window, lend):prevind(window, sym_lo)]
        match(r"^\s*([+\-*/^])[\[\]\.\w\s]*$", between) !== nothing && return true
    end
    return false
end

# 🔴 이 함수의 docstring 은 일부러 이 파일이 지키는 기호 이름 옆에 소수 리터럴 예시를 안 쓴다
# -- 그렇게 쓰면 이 파일 소스 자신이 (6c) 의 hit 이 된다((6b) 가 이미 밟은 자기지시 함정과
# 같다). 아래는 그래서 예시를 함수 인자 이름으로만 설명한다.
"`max(`/`min(`/`clamp(` 의 첫 인자로 쓰인 리터럴을, **그 호출 안에 `sym` occurrence 가
없을 때만** 무관한 바닥값으로 인정해 뺀다(예: `max(floor, other_var - x)`). 같은 호출 안에
`sym` 이 있으면(그 호출의 다른 인자 자리에 감시 대상 기호가 나타나면) 위장 폴백이므로 더는
봐주지 않는다(F-1, task-3-rereview4 항목 3). 호출의 닫는 괄호는 리터럴 뒤 첫 `)` 로 찾는다 --
이 레포의 실제 자리들은 중첩 괄호가 없으므로 충분하다(아래 실제 게이트 실행으로 확인됨)."
function _call_floor_exclusion(window::AbstractString, lstart::Int, sym_lo::Int, sym_hi::Int)
    local before = window[firstindex(window):prevind(window, lstart)]
    local cm = match(r"\b(?:max|min|clamp)\(\s*$", before)
    cm === nothing && return false
    local call_start = cm.offset
    local close_idx = findnext(')', window, lstart)
    local call_end = close_idx === nothing ? lastindex(window) : close_idx
    # 기호가 이 호출 범위 [call_start, call_end] **밖**에 있어야("겹치지 않아야") 무관한
    # 바닥값으로 인정해 뺀다. 겹치면(위장 폴백) false 를 돌려줘 hit 으로 남긴다.
    return sym_hi < call_start || sym_lo > call_end
end

"주석을 지운 뒤 `sym` 이 나오는 모든 자리에서 앞뒤 `n`자 이내의 소수(부호·지수·유리수
포함) 리터럴을 전부 찾는다. `_arith_bound_to_symbol`/`_call_floor_exclusion` 이 둘 다
'아니오'라고 답한 것만 hit 으로 남긴다. 주석 제거는 줄마다 첫 `#` 이후를 자르는 단순화다 --
문자열 리터럴 안의 `#` 은 못 가른다(사각지대로 위에 문서화, 넓히지 않는다). 반환: (표시 경로,
리터럴, 주변 문맥) 쌍의 벡터."
function scan_proximity_literals(dirs, sym::AbstractString, n::Int)
    local hits = Tuple{String,String,String}[]
    local dec_re = Regex(NUM_RE)
    for d in dirs
        local root = isabspath(d) ? d : joinpath(REPO, d)
        isdir(root) || continue
        for (dirpath, _, files) in walkdir(root)
            for fn in files
                endswith(fn, ".jl") || continue
                local fpath = joinpath(dirpath, fn)
                local raw = read(fpath, String)
                # 세 겹따옴표 docstring 도 지운다 -- 안 지우면 문서 문자열 안의
                # 숫자(예: ood_stream.jl 의 \"default 1.0\")도 코드처럼 걸린다.
                local no_doc = replace(raw, Regex("\"\"\".*?\"\"\"", "s") => " ")
                local stripped = join([replace(l, r"#.*$" => "") for l in split(no_doc, '\n')], '\n')
                local idx = firstindex(stripped)
                while true
                    local m = findnext(sym, stripped, idx)
                    m === nothing && break
                    local lo = max(firstindex(stripped), first(m) - n)
                    local hi = min(lastindex(stripped), last(m) + n)
                    lo = thisind(stripped, lo); hi = thisind(stripped, hi)
                    local window = stripped[lo:hi]
                    local sym_lo = first(m) - lo + 1
                    local sym_hi = last(m) - lo + 1
                    for dm in eachmatch(dec_re, window)
                        local lstart = dm.offset
                        local lend = dm.offset + ncodeunits(dm.match) - 1
                        _arith_bound_to_symbol(window, lstart, lend, sym_lo, sym_hi) && continue
                        _call_floor_exclusion(window, lstart, sym_lo, sym_hi) && continue
                        push!(hits, (relpath(fpath, REPO), dm.match, strip(window)))
                    end
                    idx = last(m) + 1
                end
            end
        end
    end
    return hits
end

@testset "(6) REPLACE_SOC_THRESHOLD 폴백 리터럴이 하나도 없다" begin
    # 🔴 2026-08-31 (fallback-removal task): 명제가 뒤집혔다. 예전엔 "폴백이 있다 —
    # 그것들이 전부 DEEP 과 같은가" 를 쟀다(발견형, hits > 0 을 전제). 이제 여덟 곳을 전부
    # 지웠으므로 "폴백이 **아예 없다**" 를 잰다 — 더 단순하고, 더 강하고, 누가 하나라도
    # 다시 심으면 즉시 빨개진다. (여전히 파일 목록은 하드코딩하지 않는다 — 2026-08-31
    # fix round 1, I-2 의 규약을 그대로 지킨다.)
    local hits = scan_fallback_sites(("src", "tools", "test", "wm4spacecraft_manufacturing"), FALLBACK_RE)
    local ternary_hits = scan_fallback_sites(("src", "tools", "test", "wm4spacecraft_manufacturing"), TERNARY_RE)
    local catch_hits   = scan_fallback_sites(("src", "tools", "test", "wm4spacecraft_manufacturing"), CATCH_RE)
    # 🔴 "스캐너가 하나도 못 찾는" 상태가 이제 통과 조건 자체다 — 그래서 이 스캔만으로는
    # "패턴이 죽어서 텅 비었다" 와 "정말로 깨끗해서 텅 비었다" 를 못 가른다(I-2 의 원래
    # 경고). 그 구분은 (6b)의 심은-자리 자기증명이 진다: 거기서 합성 폴백을 심고 이
    # 스캐너가 여전히 잡는지 독립적으로 확인한다. (6)은 "실제 트리가 비었다" 만 잰다.
    @test length(hits) == 0
    @test length(ternary_hits) == 0   # `isdefined(...) ? ...[] : X` 갈래
    @test length(catch_hits) == 0     # `try ... catch; X end` 갈래
    @test length(ternary_hits) + length(catch_hits) == length(hits)   # 두 갈래의 합 == 합친 스캔
    isempty(hits) || println("    [진단] 남은 REPLACE_SOC_THRESHOLD 폴백 자리 ", length(hits), "곳: ",
            join(["$(p)=$(l)" for (p, l) in hits], ", "))
end

@testset "(6b) 스캐너 자기증명 — 두 방향" begin
    # 방향 1: 패턴이 아무것도 안 잡으면 빨개져야 한다(실패할 수 없는 게이트 방지, I-2).
    # 존재하지 않을 패턴으로 스캔해서 직접 확인한다.
    # 마커도 쪼개 이어붙인다 — 통짜 리터럴로 쓰면 이 정규식의 "정의 자체"가 test/ 스캔 대상인
    # 이 파일 소스 안에서 자기 자신과 매치돼(위 (6) 수정 때 밟은 것과 같은 함정) "아무것도 안
    # 잡는 패턴"을 만들려던 의도가 깨진다.
    local nothing_marker = "THIS_PATTERN" * "_MATCHES_NOTHING_" * "2026_08_31_FIX_ROUND_1"
    local nothing_re = Regex(nothing_marker)
    local empty_hits = scan_fallback_sites(("src", "tools", "test", "wm4spacecraft_manufacturing"), nothing_re)
    @test isempty(empty_hits)
    # 방향 2: 새 자리를 실제로 심으면 스캐너가 잡아야 한다.
    # 🔴 2026-08-31 fix round 2 (N-3): 예전 버전은 이 파일을 test/ 안에 썼다. `Pkg.test()` 가
    #    write 와 finally 사이에서 죽으면(kill, OOM, 정전) 0.2 리터럴을 담은 `.jl` 파일이
    #    test/ 에 그대로 남고, 그 파일은 이 게이트 자신의 (6) 이 훑는 디렉터리 안이라 **다음
    #    실행이 원인 모를 이유로 빨개진다.** `mktempdir()` 로 REPO 밖에 심어서 이 위험을
    #    구조적으로 없앤다 — 정리가 안 돼도 (6) 이 안 훑는 곳에 남을 뿐이다.
    mktempdir() do tmpdir
        # 문자열을 쪼개 이어붙인다 — 통짜 리터럴로 쓰면 **이 게이트 파일 자신의 소스**에
        # 폴백 패턴과 그대로 맞아떨어지는 부분문자열이 나타나서, 위 (6) 이 이 파일 자신을
        # 아홉 번째 자리로 잘못 집는다(2026-08-31 fix round 1 중 실측: 자기지시로 (6) 이
        # 빨개졌었다 — 첫 시도는 코드만 쪼개고 이 설명 주석 자체에 그 부분문자열을 다시
        # 써 넣는 바람에 또 걸렸다. 그래서 이 주석도 그 문자열을 통짜로 인용하지 않는다).
        local sym = ":REPLACE_SOC_THRESHOLD"
        local ref = "REPLACE_SOC_THRESHOLD" * "[]"
        local planted = joinpath(tmpdir, "_tmp_i2_planted_fallback.jl")
        write(planted, "thr = isdefined(@__MODULE__, $(sym)) ? $(ref) : 0.2\n")
        local planted_hits = scan_fallback_sites((tmpdir,), FALLBACK_RE)
        @test any(p -> p == planted, first.(planted_hits))
        # 심은 값(0.2)은 DEEP(0.1)과 다르므로, 실제 (6) 어서션 로직을 그대로 이 hit 에 적용하면
        # 빨개져야 한다 — 그것이 이 전체 방향의 요점이다.
        local this_hit = only(filter(h -> h[1] == planted, planted_hits))
        @test parse(Float64, this_hit[2]) != DEEP   # 심은 자리는 DEEP 과 달라야 발견의 의미가 있다
        # mktempdir() do 블록이 끝나면(정상/예외 무관) 줄리아가 tmpdir 자체를 지운다 — 여기서
        # 따로 rm 할 필요가 없다. test/ 는 애초에 건드리지 않았다.
    end
end

@testset "(6c) 근접성 검사 -- 철자를 안 가리는 그물" begin
    # (6)/(6b)/branch-split 은 정해진 철자(`isdefined(...) ? ...[] : X` / `try...catch; X end`)에
    # 기댄다. 이건 안 가린다: 소스에서 REPLACE_SOC_THRESHOLD 라는 글자 자체가 나오는 모든 자리
    # 앞뒤 PROXIMITY_N 자 안의 소수 리터럴은(산술 결합 제외) 전부 DEEP 과 같아야 한다.
    #
    # 🔴 2026-08-31 (fallback-removal task) 유지 결정: 여덟 폴백이 전부 사라져 (6)이
    # "폴백 리터럴 0건" 을 직접 증명하는 지금도, 이 절은 트리비얼하게 통과하는 게 아니다 --
    # (6)은 **두 정해진 철자**만 스캔하고, 이 절은 철자와 무관하게 기호 근처 모든 소수
    # 리터럴을 잡는다(fix round 4 가 이 절을 만든 이유 자체가 "철자 카탈로그는 다섯 개
    # 재현 사례에서 실제로 뚫렸다"였다). 누가 아홉 번째 철자(`coalesce(...)` 등)로 폴백을
    # 되살리면 (6)은 못 잡고 이 절만 잡는다 -- 그래서 지운다. 반대로 이 절만 남기고 (6)을
    # 지우면 "정확히 어느 두 철자가 사라졌는가" 를 증명하는 별도의 근거(위 (6b)의 심은-자리
    # 자기증명)가 없어진다 -- 그래서 둘 다 남긴다. `const REPLACE_SOC_THRESHOLD = Ref(0.1)`
    # 정의 자체(ood_truth.jl)가 이 절의 상시 non-vacuous 증거다: 그 줄의 "0.1" 이 산술·
    # max/min/clamp 결합이 아닌 채로 항상 하나 잡히므로, 대상 디렉터리가 잘못돼 텅 비는
    # 사고(위 `length(prox_hits) > 0` 어서션의 원래 취지)는 폴백 유무와 무관하게 계속 걸린다.
    local prox_hits = scan_proximity_literals(
        ("src", "tools", "test", "wm4spacecraft_manufacturing"), "REPLACE_SOC_THRESHOLD", PROXIMITY_N)
    @test length(prox_hits) > 0   # 이 자체가 텅 비면 grep 대상 디렉터리가 잘못됐다는 신호다
    for (path, lit, ctx) in prox_hits
        @test _parse_soc_literal(lit) == DEEP
    end
    println("    [진단] 근접성 검사 자리 ", length(prox_hits), "곳: ",
            join(["$(p)=$(l)" for (p, l, c) in prox_hits], ", "))
end

end # module
