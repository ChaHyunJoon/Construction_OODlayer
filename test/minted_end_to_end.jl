# =============================================================================
# 경계 e2e: 생성 코드가 서비스 응답에서 등록·집행부까지 간다. (2026-09-03, Task 9)
#
# 재는 명제: `policy_entry` 가 SYNTH_LANE_KEYS 로 실은 `impl_name`·`impl_code`·
# `surface`·`reversible` 가 `enact_minted_decision!` 안에서 `register_minted_primitive!`
# 로 등록되고, 그 직후 같은 프레임에서 `enact_minted!` 가 그 이름을 부를 수 있어야 한다
# (world age — `test/minted_registration.jl` (9) 의 F1 과 같은 모양). 그리고 `registered`·
# `impl_rejected_why`(R2/R7) 가 성공 · 등록 거절 · (등록은 됐는데 그 뒤가 던졌다) 를
# 가른다. 🔴 `registered === nothing`(판정 불가) 은 2026-09-03 최종 리뷰 F7 **직후엔
# 아직 있었다** — F7 은 `register_minted_primitive!` 자신의 `params` 키-타입 위반만
# 고쳤는데, 그 함수가 먼저 부르는 `check_impl_conventions` 안에 콜리(함수 시그니처
# 이름)가 `Symbol` 이 아닌 세 모양(한정 이름·보간·callable 객체)에서 던지는 **다른**
# 자리가 남아 있었다(F9 최종 리뷰가 잡았다 — 그중 한정 이름은 D6 이 재려는 사건과
# 겹쳐서 이 계획의 핵심 측정을 raw MethodError 로 날릴 뻔했다). F9 가 그것도 고친
# **지금은** 이 두 함수 안에서 실측한 모델-도달가능 모양 중 던지는 자리가 없다 —
# `tools/monitor/enact.jl` 의 `registered` docstring 이 그 재도출을 적는다(모든 AST
# 모양을 남김없이 센 증명은 아니라고 그 자리에 명시한다).
#
# 🔴 **픽스처 방법론 — 이 파일의 모든 `synth_lane` 은 JSON3 왕복을 거친다.**
#    손으로 지은 `Dict{String,Any}` 를 `enact_minted_decision!` 에 **직접** 넘기면 라이브
#    에서만 나는 실패를 못 잡는다. 🔴 2026-09-03 최종 리뷰가 잡은 것: 이 머리말이 이미
#    그렇게 적고 있었는데 **testset (3)·(4) 는 손으로 지은 `Dict{String,Any}` 를 그대로
#    넘기고 있었다** — 그리고 이 파일의 자기 서술이 참이 아니었던 그 자리가 정확히
#    `params` 타입 파열(C-F1)이 다섯 라운드를 살아남은 이유다. 지금은 넷 다 아래
#    `_resp(...)` 를 지나간다: 실제 서비스 응답과 같은 모양을 짓고 `JSON3.write` →
#    `JSON3.read` 로 왕복시킨 뒤 **`policy_entry` 를 실제로 태운다.**
#
# 🔴 2026-09-03 최종 리뷰 F5. 이전 판은 이 파일 전체가 `registered`·`impl_rejected_why`
#    에 단언을 **하나도** 안 걸었다 — `if why !== nothing … return` 갈래를 통째로 지워도
#    스위트가 전부 초록이었다(실측). testset (2)·(3) 이 그 구멍을 메운다.
#
# 🔴 2026-09-03 최종 리뷰 B3 — **(5) 가 이 파일의 새 무게중심이다.** 그 전까지 이 레포에는
#    *파이썬이 실제로 만든 기록을 줄리아에 먹이는 시험이 하나도 없었다*: 줄리아 픽스처는
#    전부 줄리아 저자가 손으로 지은 것이고, 파이썬 시험은 `params` 의 문자열 모양을
#    하드코딩하고 통과했으며, 교차언어 게이트(`test/synth_lane_keys_survive.jl`)는
#    **키 이름만** AST 로 견줬다 — 타입도 값도 안 봤다. 그래서 양쪽 스위트가 초록인 채로
#    치명적 계약 파열이 살아남았다. (5) 는 `synthesize_multi` 를 **가짜 프로그램으로**
#    돌려(유료 0건) 진짜 기록을 만들고, 그것을 JSON 으로 건너보내 **경계 키마다 타입을
#    못박은** 뒤 실제로 등록·집행한다. 그리고 음성 대조로 `params` 를 문자열로 되돌려
#    거절되는 것까지 본다 — 표가 공허하지 않다는 증거다.
#
# 🔴 2026-09-03 최종 리뷰 B6 — **(6) 은 행동을 안 바꾸고 잰다.** 무동작 생성 body 도
#    `world_maybe_dirty=true` ⇒ `handled=true` 라 기본 복구 사슬을 건너뛴다. 그것은
#    `_step_touched_world` 의 **의도된 계약**이고(더러워졌을 수 있는 세계 위에 폴백을 쌓는
#    것이 더 나쁘다) 문서에 그렇게 적혀 있다. 그런데 그 값을 **생성 경로에서 재는 단언이
#    레포 어디에도 없었다**: `tools/monitor/test_minted_wiring.jl` 은 일부러 `impl_code` 를
#    안 실어(등록 경로를 안 태운다) 여섯 개의 `handled === true` 가 전부 손으로 씨 뿌린
#    비-생성 행이고, 이 파일의 네 testset 은 전부 `handled === false` 였다(env 에 `cache`/
#    `sched` 가 없다). 생산이 읽는 유일한 값이 미측정이었다.
# =============================================================================
module MintedEndToEnd
using Test
using ConstructionBots
import JSON3
const CB = ConstructionBots
include(joinpath(@__DIR__, "..", "tools", "monitor", "policy.jl"))
include(joinpath(@__DIR__, "..", "tools", "monitor", "enact.jl"))

"""
    _resp(synth::Dict{String,Any}) -> JSON3.Object

서비스 응답 한 벌을 짓고 **JSON3 왕복**시킨다. 결정 행이 아니라 `policy_entry` 의 입력이
필요한 것이므로 최상위 필드도 실제 응답과 같은 이름으로 채운다(`policy_entry` 는 `b` 를
Symbol 키로 읽는다 — `Dict{String,Any}` 를 그대로 주면 전부 미스해 **실패 분기**가 조용히
탄다). 🔴 픽스처를 여기 한 벌만 두는 이유: 이 파일의 머리말이 "모든 픽스처가 왕복한다" 고
주장하는데, 왕복을 testset 마다 손으로 적으면 그 주장이 다시 갈릴 수 있다.
"""
_resp(synth::Dict{String,Any}) = JSON3.read(JSON3.write(Dict{String,Any}(
    "chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing, "rationale" => "r",
    "policy" => "dspy", "coerced" => false, "error" => nothing,
    "tool_minted" => true, "synthesis" => synth)))

_lane(synth::Dict{String,Any}) = policy_entry(_resp(synth), "dspy")
_dec(sl) = (macro_name = "NOOP", synth_lane = sl)

# `_issue_resume!`/`_resolve_if_needed!` 가 요구하는 필드가 **없는** env. 그래서 아래 (1)~(4)
# 는 전부 `handled === false` 다 — 그것이 결함이 아니라 이 env 의 성질이라는 것을 (6) 이
# 같은 body 모양에 **완전한** env 를 주어 반대편에서 보여 준다.
const BARE_ENV = (staging_circles = Dict{Symbol,Any}(),)

"""
    live_cache_env() -> NamedTuple

`reset_cache_resume!` 이 실제로 나갈 수 있는 최소 env. `tools/monitor/test_minted_wiring.jl`
의 `throw_env_with_live_cache()` 와 같은 관용구이고, 낡은 정점 하나를 심어 두어 **재개가
실제로 나갔는지가 `active_set` 으로 관측 가능**하게 만든다.

🔴 2026-09-04 (D18). `active_build_steps` 는 **이 시험을 위해 나중에 더한 필드다.** 그 전
판은 `(cache, sched)` 둘뿐이었고, 그래서 `_world_digest` 가 이 env 에서 통째로 `nothing`
을 냈다(실측: `type NamedTuple has no field active_build_steps` → 다이제스트의 `catch` 가
`nothing` 으로 삼킨다). 즉 **"쟀는데 0" 과 "못 쟀다" 를 가르는 testset (10)(11) 이 이 env
에서는 후자만 볼 수 있었다.** 필드 이름·타입의 진실원은 `PlannerEnv`(`src/route_planning.jl`
의 `active_build_steps::Set{AbstractID}`)이고 여기는 그 모양을 빈 채로 흉내낼 뿐이다.
⚠️ 다이제스트는 넷을 **전부** 읽어야 지문을 낸다 — 하나라도 없으면 `nothing` 이다. 그것이
설계다(반쯤 잰 지문의 차분은 무엇을 뜻하는지 아무도 못 적는다).
"""
function live_cache_env()
    sched = CB.OperatingSchedule()
    cache = CB.initialize_planning_cache(sched)
    push!(cache.active_set, 999)
    return (cache = cache, sched = sched,
            active_build_steps = Set{CB.AbstractID}())
end

const OK_SYNTH = Dict{String,Any}(
    "synthesis_event" => true, "ran" => true, "error" => nothing,
    "tool_name" => "T", "impl_name" => "e2e_touch!",
    "impl_code" => "function e2e_touch!(env; note = \"x\")\n    return (status = :e2e_ok, note = note)\nend\n",
    "surface" => "sched", "reversible" => true,
    "params" => Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
    "body_names" => ["e2e_touch!"], "wrote" => true,
    "calls" => [Dict{String,Any}("primitive" => "e2e_touch!",
                                 "args" => Dict{String,Any}("note" => "hi"))])

@testset "(1) 생성 코드가 응답에서 등록·집행부까지 간다" begin
    CB.reset_minted_table!()
    e = _lane(OK_SYNTH)
    for k in ("impl_name", "impl_code", "surface", "reversible")
        @test haskey(e, k)
    end
    r = enact_minted_decision!(BARE_ENV, nothing, _dec(e))
    @test r.verdict === :admit
    @test r.args_from === :calls && r.n_calls == 1
    @test length(r.steps) == 1 && r.steps[1].status === :e2e_ok
    # 🔴 F5. 행복 경로: 등록이 실제로 됐고, 거절 사유는 없다.
    @test r.registered === true
    @test r.impl_rejected_why === nothing
    # 🔴 F6(5)(2026-09-03 최종 리뷰). 이 fixture 의 `env` 는 `staging_circles` 하나뿐이라
    #    `_issue_resume!`/`_resolve_if_needed!` 가 요구하는 `cache`/`sched` 필드가 없다 —
    #    그래서 `resume=:failed`(재개 시도가 예외로 끝남)·`resolve=:threw` 가 나고
    #    `minted_handled` 의 네 연언지 중 둘이 깨져 `handled === false` 다(실측). 이것은
    #    이 시험의 **결함이 아니라 측정값**이다. 🔴 그리고 그 사실은 **이 env 의 성질이지
    #    생성 경로의 성질이 아니다** — 아래 (6) 이 완전한 env 로 같은 모양을 굴려
    #    `handled === true` 를 잰다(B6).
    @test r.handled === false
end

@testset "(2) 🔴 F5: 규약 위반 impl_code 는 registered=false·impl_rejected_why 를 남기고 집행을 시도하지 않는다" begin
    CB.reset_minted_table!()
    e2 = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "e2e_bad!",
        # 규약 위반: 위치인자가 `env` 하나가 아니다(`check_impl_conventions` 가 거절한다).
        "impl_code" => "function e2e_bad!(x; note = \"x\")\n    return :ok\nend\n",
        "surface" => "sched", "reversible" => true,
        "params" => Dict{String,Any}(),
        "body_names" => ["e2e_bad!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "e2e_bad!",
                                     "args" => Dict{String,Any}())]))
    r2 = enact_minted_decision!(BARE_ENV, nothing, _dec(e2))
    @test r2.verdict === :reject
    @test r2.registered === false
    @test r2.impl_rejected_why !== nothing &&
          occursin("reject:", r2.impl_rejected_why) &&
          occursin("positional", r2.impl_rejected_why)
    # 🔴 집행이 시도되지 않았다 — 등록 거절이 `CB.enact_minted!` 호출보다 먼저 돌아선다.
    @test isempty(r2.steps)
    @test r2.handled === false
    @test !isdefined(CB, :e2e_bad!)   # Core.eval 자체가 안 됐다는 것을 직접 잰다
end

@testset "(3) 🔴 F5/F2: 등록은 성공했는데 enact_minted! 가 던지면 registered=true 가 정직하게 남는다" begin
    # 🔴 2026-09-03 최종 리뷰 F7 재작성, F9 로 근거 갱신. 이전 판은 `registered === nothing`
    #    을 `register_minted_primitive!` 자신의 계약 위반(`params` 가 정수 키 dict 이면
    #    `String(::Int64)` 로 **던졌다** — R8 이 고쳤다, `src/respec/minted_registration.jl`
    #    참고)에 기대어 재고 있었다. F7 시점엔 "그 던지기가 유일한 생산자다" 라고 적었는데
    #    **틀렸다** — 그 함수가 먼저 부르는 `check_impl_conventions` 안에 **다른** 던지는
    #    자리(콜리가 `Symbol` 이 아닌 세 모양 — 한정 이름·보간·callable 객체)가 남아 있었고,
    #    F9 최종 리뷰가 그것을 잡았다. 두 결함을 다 고친 **지금**, 실측한 모델-도달가능
    #    모양 중 이 두 함수가 던지는 자리는 없다(`registered` docstring 이 재도출을 적는다).
    #    **나중에 `Bool` 로 되돌리거나 이 상태를 재려고 또 다른 버그에 기대는 시험을 짓지 말 것.**
    #
    #    F5 가 진짜로 재려던 것은 "등록 뒤에 다른 자리가 던지면 그 사실을 안 잃는가" 다 —
    #    R2 의 옛 리터럴 `false` 가 거짓말하던 자리가 정확히 이것이다. 깨끗한 예: 등록은
    #    정상 규약이고, `body_names` 가 `[1, 2]`(정수) 라서 `enact_minted!` 이
    #    `String.(body_names)` 에서 던진다 — 등록 자체는 아무 규약도 안 어겼다.
    CB.reset_minted_table!()
    e3 = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "alt_ok!",
        "impl_code" => "function alt_ok!(env; note = \"x\")\n    return :ok\nend\n",
        "surface" => "sched", "reversible" => false,
        "params" => Dict{String,Any}(),
        "body_names" => [1, 2], "wrote" => true, "calls" => nothing))
    r3 = enact_minted_decision!(BARE_ENV, nothing, _dec(e3))
    @test r3.verdict === :reject
    @test occursin("threw", r3.reason) && occursin("String", r3.reason)
    # 🔴 핵심 단언 — R2 시절 리터럴 `false` 가 거짓말했을 자리. 등록은 실제로 성공했다
    #    (`minted_table()` 에 행이 있다) — 이 예외는 그 **뒤** `enact_minted!` 안에서
    #    났다. `registered` 는 그 사실을 안 잃는다.
    @test r3.registered === true
    @test r3.impl_rejected_why === nothing
    @test haskey(CB.minted_table(), "alt_ok!")
    @test r3.handled === false
    # 🔴 B4(2026-09-03 최종 리뷰). **이 값을 못박는다.** 이것은 바깥 `catch` 의 반환이고,
    #    그 자리는 `false`(F20 전) → `nothing`(F20) → `true`(B4) 로 세 번 바뀌는 동안
    #    **레포 전체에 단언이 하나도 없어서** 셋 다 초록이었다. 오늘의 계약은 `true` 다:
    #    이 필드는 가능성 술어("세계가 더러울 **수** 있는가")라 "못 쟀다" 가 "그럴 수 있다"
    #    로 무너지고, 소비자(`minted_handled`)가 `&&` 의 항으로 읽어 `Bool` 을 요구한다.
    @test r3.world_maybe_dirty === true
    @test r3.world_maybe_dirty isa Bool
end

@testset "(4) 🔴 F9(R9): 한정 이름(D6-모양) 이 경계 끝까지 던지지 않고 자기 사유로 거절된다" begin
    # 🔴 2026-09-03 최종 리뷰 F9. 셋 중 **가장 위험한 모양** — 모델이 가려진 능력을 다시
    #    이름 붙이려 할 때 실제로 쓸 법한 것은 한정 이름(`ConstructionBots.foo!`)이다.
    #    F9 전에는 이 payload 가 `check_impl_conventions` 안의 `String(sig.args[1])` 에서
    #    던져 `verdict=:reject, registered=nothing, impl_rejected_why=nothing,
    #    reason="...threw: MethodError..."` 로 도착했다 — D6 신호가 기록되지 않고
    #    소실됐다. 지금은 등록 단계에서 **거절**로 잡혀 사유가 남는다.
    CB.reset_minted_table!()
    e4 = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "qual_e2e_touch!",
        "impl_code" => "function ConstructionBots.qual_e2e_touch!(env; note = \"x\")\n    return :ok\nend\n",
        "surface" => "sched", "reversible" => false,
        "params" => Dict{String,Any}(),
        "body_names" => ["qual_e2e_touch!"], "wrote" => true, "calls" => nothing))
    r4 = enact_minted_decision!(BARE_ENV, nothing, _dec(e4))
    @test r4.verdict === :reject
    @test !occursin("threw", r4.reason)   # 예외가 아니라 거절이다 — 던진 적이 없다
    # 🔴 핵심 단언. `registered` 는 `nothing`(판정 불가)이 아니라 `false`(봤는데 안
    #    됐다)다 — 등록 시도가 실제로 돌아 규약 위반으로 거절됐음을 안다.
    @test r4.registered === false
    @test r4.impl_rejected_why !== nothing &&
          startswith(r4.impl_rejected_why, "reject:impl_name_is_qualified:")
    @test isempty(r4.steps)
    @test !isdefined(CB, :qual_e2e_touch!)
    @test r4.handled === false
end

# =============================================================================
# (5) 🔴 교차언어 **타입** 계약 — 파이썬이 실제로 낸 기록을 줄리아가 먹는다
#
# 🔴 유료 0건. `synthesize_multi` 를 **가짜 프로그램 셋**으로 돌린다(dspy 프로그램이 전부
#    주입되므로 LM 은 만들어지지도 않는다). 호출은 `env -u OPENAI_API_KEY` 로 감싼다.
# 🔴 **자극과 단언을 가른다.** 아래 파이썬 블록의 리터럴(스키마 문자열 등)은 *모델이 낼
#    법한 것*, 즉 **자극**이다 — 그래서 일부러 라이브 모양(JSON Schema 봉투)으로 적는다.
#    반면 단언은 파이썬 리터럴을 **하나도 안 베낀다**: 값을 전부 `synthesize_multi` 가 실제로
#    낸 기록에서 읽고, 타입은 아래 `BOUNDARY_TYPES` 표 하나가 갖는다. C-F1 이 살아남은 이유가
#    정확히 그 구별이 없었기 때문이다 — `test_write_tool_impl.py` 가 자극 자리에 **이미
#    정규화된** 평평한 맵을 박아 두어, 단언이 통과해도 라이브에서는 아무 말도 못 했다.
# =============================================================================
const _PY_BIN = normpath(joinpath(@__DIR__, "..", ".venv", "bin", "python"))
const _PY_DIR = normpath(joinpath(@__DIR__, "..", "src", "respec", "llm_service"))

# 🔴 이 블록 안에 큰따옴표 **세 개 연속**이나 `\` + 큰따옴표를 쓰지 말 것. 줄리아의 raw
#    삼중따옴표 리터럴은 (a) 따옴표 셋에서 **끝나고** (b) 역슬래시+따옴표를 따옴표 하나로
#    **접는다** — 그래서 파이썬 소스 안의 큰따옴표는 `chr(34)` 로 짓는다(이스케이프를 두
#    언어에 걸쳐 세는 순간 한쪽이 조용히 틀린다).
const _PY_RECORD = raw"""
import json, os, sys
sys.path.insert(0, sys.argv[1])
import synthesize as SY
os.environ[SY.SYNTHESIS_ENV] = "1"
NAME = sys.argv[2]

class _P:
    def __init__(self, **kw): self.__dict__.update(kw)

# 큰따옴표는 chr(34) 로 짓는다 — 이유는 줄리아 쪽 `_PY_RECORD` 의 주석에 있다.
Q = chr(34)
BARE = ("function " + NAME + "(env; note = " + Q + "x" + Q + ")\n"
        "    return (status = :crosslang_ok, note = note)\nend\n")
# 🔴 R18 (2026-09-03) — **자극**이 라이브 모양으로 바뀌었다: 모델은 코드를 마크다운
#    펜스로 감싼다(두 번째 유료 런의 실측 모양). 이것을 벗기는 것은 파이썬의 몫이고
#    (`synthesize.strip_code_fence`), 이 게이트는 그 정규화가 **경계를 건너 살아 있는지**
#    를 잰다 — 펜스가 그대로 오면 줄리아 등록이 `reject:impl_code_is_fenced` 로 거절해
#    아래 (5-b) 가 통째로 빨개진다.
CODE = "```julia\n" + BARE + "```"
progs = {
    "observe": lambda **kw: _P(reasoning_log="the robot is degraded"),
    "design":  lambda **kw: _P(expressible=False, tool_name="CrossLangProbe",
                               params='{"note": {"type": "string"}}', mechanism="m"),
    "compose": lambda **kw: _P(wrote=True, impl_name=NAME, surface="env_param",
                               reversible=True, impl_code=CODE,
                               params='{"type": "object", "properties": {"note": {"type": "string"}}}',
                               calls=[{"primitive": NAME, "args": {"note": "hi"}}]),
}
rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(), programs=progs)
print("__RECORD__" + json.dumps({
    "chosen": "NOOP", "ranking": ["NOOP"], "margin": None, "rationale": "r",
    "policy": "dspy:offline", "coerced": False, "error": None,
    "tool_minted": rec["tool_minted"], "synthesis": rec}, ensure_ascii=False))
"""

"""
    py_service_response(name) -> JSON3.Object

`synthesize.py` 가 **실제로 짓는** 합성 기록을 서비스 응답 모양으로 감싸 돌려준다.
🔴 파이썬에 못 닿으면 **skip 이 아니라 빨개진다** — skip 은 이 시험이 막으려는 구멍에
단계만 하나 더한 것이다(`synth_lane_keys_survive.jl` 의 같은 규약).
"""
function py_service_response(name::AbstractString)
    isfile(_PY_BIN) || error("교차언어 타입 게이트: 파이썬이 없다 — $(_PY_BIN) (skip 하지 않는다)")
    local o = IOBuffer(); local e = IOBuffer()
    local pr = run(pipeline(ignorestatus(
        `env -u OPENAI_API_KEY $(_PY_BIN) -c $(_PY_RECORD) $(_PY_DIR) $(name)`);
        stdout = o, stderr = e))
    local out = String(take!(o)); local errs = String(take!(e))
    pr.exitcode == 0 || error("교차언어 타입 게이트: 기록 생성 실패 (rc=$(pr.exitcode))\n$(errs)")
    local marked = filter(l -> startswith(l, "__RECORD__"), split(out, "\n"))
    length(marked) == 1 ||
        error("교차언어 타입 게이트: `__RECORD__` 줄이 정확히 하나가 아니다 ($(length(marked)))\n$(out)")
    return JSON3.read(chop(marked[1], head = length("__RECORD__"), tail = 0))
end

"""
    BOUNDARY_TYPES

**경계 키마다: 파이썬이 내는 값이 줄리아에서 무슨 타입으로 물질화돼야 하는가.**

🔴 이 표가 이 파일이 새로 지는 하중이다. `SYNTH_LANE_KEYS`(이름 축)는
`test/synth_lane_keys_survive.jl` 이 파이썬 소스의 AST 로 지키는데, 그 게이트는 **타입도 값도
안 본다** — 그래서 파이썬이 `params` 를 JSON 스키마 **문자열**로 내고 줄리아 등록 가드가
`AbstractDict` 를 요구하는 파열이 양쪽 스위트가 초록인 채로 다섯 리뷰 라운드를 살아남았다.
오른쪽 타입은 **줄리아 소비자가 실제로 요구하는 것**이고, 요구하는 자리를 같이 적는다:

| 키 | 요구하는 자리 |
|---|---|
| `impl_name`  | `enact.jl`: `nm isa AbstractString ‖ reject:impl_name_not_a_string` |
| `impl_code`  | `enact.jl`: `cd isa AbstractString ‖ reject:impl_code_not_a_string` |
| `surface`    | `enact.jl`: `surf_raw isa AbstractString ‖ reject:surface_not_a_string` |
| `params`     | `enact.jl`: `praw isa AbstractDict ‖ reject:params_not_an_object` 🔴 B2 |
| `reversible` | `enact.jl`: `... === true` (Bool 이 아니면 조용히 false 가 된다) |
| `body_names` | `minted_tool.jl`: `String.(body_names)` — 벡터여야 한다 |
| `calls`      | `minted_tool.jl`: `normalize`가 원소마다 `primitive`/`args` 를 읽는다 |
| `wrote`      | `enact.jl` 의 조기반환 로그(줄리아 유일 독자) — 삼상이라 Bool 이어야 한다 |
| `refused`    | 같은 로그. 이 판은 G1 가드가 돌고 통과했으므로 `false` 다 |
"""
const BOUNDARY_TYPES = [
    "tool_minted"     => Bool,
    "synthesis_event" => Bool,
    "synthesis_ran"   => Bool,
    "refused"         => Bool,
    "tool_name"       => AbstractString,
    "body_names"      => AbstractVector,
    "params"          => AbstractDict,
    "calls"           => AbstractVector,
    "impl_name"       => AbstractString,
    "impl_code"       => AbstractString,
    "surface"         => AbstractString,
    "reversible"      => Bool,
    "wrote"           => Bool,
]

@testset "(5) 🔴 교차언어: 파이썬이 낸 기록의 **타입**이 줄리아 경계와 맞고, 그대로 집행된다" begin
    CB.reset_minted_table!()
    local NAME = "crosslang_probe!"
    local resp = py_service_response(NAME)
    local e = policy_entry(resp, "dspy")

    # 먼저 성공 분기가 실제로 탔는지 — 아니면 아래 표는 "실패 분기가 우연히 nothing 이 아니다"
    # 를 재는 것이 된다.
    @test e["available"] === true
    @test e["impl_name"] == NAME

    # ---- (5-0) 🔴 R18 FIX A: 펜스는 경계를 못 건넌다 ------------------------------------------
    # 자극은 펜스로 감싼 코드였다(위 `_PY_RECORD`). 경계에 도착하는 것은 맨 Julia 다 —
    # 정규화는 파이썬 하나가 하고(`strip_code_fence`), 줄리아는 진단만 한다.
    @test !occursin("`", e["impl_code"])
    @test startswith(e["impl_code"], "function " * NAME)

    # ---- (5-a) 타입 계약 -------------------------------------------------------------------
    for (k, T) in BOUNDARY_TYPES
        @test haskey(e, k)
        @test e[k] isa T
    end
    # 삼상: 이 판은 성공이므로 오류 필드는 "쟀고 없다" 가 아니라 `nothing` 이다.
    @test e["synthesis_error"] === nothing
    # 🔴 B2 가 고친 그 축을 **따로** 못박는다. 위 루프만 있으면 누가 표의 `params` 행을
    #    `Any` 로 넓히는 순간 조용히 통과한다.
    @test !(e["params"] isa AbstractString)
    # 🔴 **모양도 계약이다.** 라이브 모델은 JSON Schema **봉투**
    #    (`{"type":"object","properties":{...},"required":[...]}`)를 낸다 — 위 가짜
    #    프로그램도 그 모양을 낸다. 줄리아 등록 행의 `params` 는 봉투가 아니라 **키워드
    #    맵**이어야 한다(`_enactability` 연언지 (iii): 키가 전부 그 메서드의 키워드).
    #    봉투를 그대로 보내면 키가 `type`/`properties`/`required` 가 되어 원시가
    #    **등록은 되고 영영 호출 불가**(`reject:unenactable:…:kwargs`)가 된다 — 이 게이트가
    #    실제로 잡아낸 층이다. 파이썬의 `params_object` 가 봉투를 벗긴다.
    @test e["params"]["note"]["type"] == "string"
    @test !haskey(e["params"], "properties")
    @test !haskey(e["params"], "type")

    # ---- (5-b) 그 기록이 실제로 등록·집행된다 ------------------------------------------------
    local r = enact_minted_decision!(BARE_ENV, nothing, _dec(e))
    @test r.verdict === :admit
    @test r.registered === true
    @test r.impl_rejected_why === nothing
    @test r.args_from === :calls && r.n_calls == 1
    @test length(r.steps) == 1 && r.steps[1].status === :crosslang_ok

    # ---- (5-c) 🔴 음성 대조: 그 타입이 정말로 하중을 지는가 ------------------------------------
    # `params` **만** 라이브 이전 모양(JSON 스키마 문자열)으로 되돌린다. 나머지는 그대로다.
    # 이것이 2026-09-03 이전의 파이썬이 실제로 내던 값이고, 그때 이 경계는 등록을 거절하며
    # `Core.eval` 에 도달조차 못 했다.
    local as_text = Dict{String,Any}(String(k) => v for (k, v) in pairs(resp[:synthesis]))
    as_text["params"] = JSON3.write(resp[:synthesis][:params])
    as_text["impl_name"] = "crosslang_probe_text!"
    as_text["impl_code"] = replace(String(resp[:synthesis][:impl_code]),
                                   NAME => "crosslang_probe_text!")
    as_text["body_names"] = ["crosslang_probe_text!"]
    as_text["calls"] = nothing
    local r_text = enact_minted_decision!(BARE_ENV, nothing, _dec(_lane(as_text)))
    @test r_text.verdict === :reject
    @test r_text.registered === false
    @test r_text.impl_rejected_why == "reject:params_not_an_object:String"
    @test isempty(r_text.steps)
    @test !isdefined(CB, :crosslang_probe_text!)   # Core.eval 에 도달조차 못 했다

    # ---- (5-d) 🔴 R18 FIX C 음성 대조: 펜스가 **정말로** 경계에서 거절되는가 -------------------
    # 위 (5-0) 은 "파이썬이 벗겼다" 를 잰다. 그것이 하중을 지려면 **안 벗겼을 때 실제로
    # 거절된다**는 것이 참이어야 한다 — 아니면 (5-0) 은 아무것도 안 지키는 단언이다.
    # 🔴 이 사유는 **진단이지 둘째 고침이 아니다**: 정상 배관에서 펜스는 여기 못 온다.
    #    오면 파이썬 정규화가 실패했다는 뜻이고, `impl_not_a_function`(=agent-3 에게 가는
    #    틀린 수리 신호)이 아니라 배관 고장을 가리키는 이름으로 도착해야 한다.
    local as_fenced = Dict{String,Any}(String(k) => v for (k, v) in pairs(resp[:synthesis]))
    as_fenced["impl_name"] = "crosslang_probe_fenced!"
    as_fenced["impl_code"] = "```julia\n" *
        replace(String(e["impl_code"]), NAME => "crosslang_probe_fenced!") * "```"
    as_fenced["body_names"] = ["crosslang_probe_fenced!"]
    as_fenced["calls"] = nothing
    local r_fenced = enact_minted_decision!(BARE_ENV, nothing, _dec(_lane(as_fenced)))
    @test r_fenced.verdict === :reject
    @test r_fenced.registered === false
    @test r_fenced.impl_rejected_why == "reject:impl_code_is_fenced"
    @test isempty(r_fenced.steps)
    @test !isdefined(CB, :crosslang_probe_fenced!)
end

@testset "(6) 🔴 B6: 무동작 생성 원시도 handled=true 다 — 행동이 아니라 **측정**이다" begin
    # 🔴 **행동을 바꾸지 마라.** `world_maybe_dirty = touched || partial` 이고 생성 원시에
    #    대해 `_step_touched_world` 는 **일부러** true 다(`src/respec/minted_tool.jl` 이
    #    근거를 적는다: 임의의 생성 코드가 라이브 `env` 를 받아 끝까지 돌았으므로 "손을 댔을
    #    **수** 있는가" 의 답은 참이고, 더러워졌을 수 있는 세계 위에 폴백을 쌓는 것이 더
    #    나쁘다). 이 testset 은 그 계약의 **귀결**을 잰다:
    #      · body 가 세계를 한 바이트도 안 바꿔도 `world_maybe_dirty === true`
    #      · ⟹ `handled === true` ⟹ 기본 복구 사슬을 건너뛰고 그 OOD 사건은 소비된다
    #      · 그런데 `applied === nothing` 이다 — "노린 적응이 일어났나" 는 **못 쟀다**.
    #    🔴 Task 11 의 귀결(사전등록에 적힌 것): 성공률을 `handled` 로 세면 생성 어휘는
    #    구조적으로 100% 가 된다. 세어야 하는 것은 `applied` 이고 그 값은 오늘 삼상이다.
    CB.reset_minted_table!()
    local env = live_cache_env()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "b6_noop_probe!",
        # 세계를 한 바이트도 안 건드린다 — `env` 를 읽지도 않는다.
        "impl_code" => "function b6_noop_probe!(env; note = \"x\")\n    return (status = :b6_noop, note = note)\nend\n",
        # 🔴 `surface` 가 `RESOLVE_SURFACES`(sched·milp) 밖이라 공통 재풀이가 안 돈다
        #    (`resolve = :not_needed_surface`). 넷째 연언지를 고립시키려는 것이 아니라,
        #    무동작 body 에 진짜 MILP 재풀이를 얹으면 이 시험이 재려는 것이 흐려진다.
        "surface" => "env_param", "reversible" => true,
        "params" => Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
        "body_names" => ["b6_noop_probe!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "b6_noop_probe!",
                                     "args" => Dict{String,Any}("note" => "hi"))]))
    local r = enact_minted_decision!(env, nothing, _dec(e))
    # 전제 — 이 판이 정말 **생성** 경로이고 body 가 돌았는가.
    @test r.registered === true
    @test r.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :b6_noop
    # 🔴 파킹된 C1 의 행동, 이제 **잰다**.
    @test r.applied === nothing              # "적응했나" 는 못 쟀다(생성 원시의 status 어휘가 없다)
    @test r.world_maybe_dirty === true       # "손을 댔을 수 있나" 는 쟀다 — 참이다
    @test r.resume === :issued
    @test r.resolve === :not_needed_surface
    @test isempty(env.cache.active_set)      # 재개가 실제로 나갔다 — 세계에 보인다
    # 🔴 생산이 읽는 유일한 값. 이 줄이 없으면 이 브랜치 전체에서 생성 경로의 `handled` 를
    #    재는 단언이 0개다.
    @test r.handled === true
end


@testset "(7) 🔴 D16: JSON3 배열·객체가 선언 타입으로 변환돼 호출이 산다" begin
    CB.reset_minted_table!()
    # 🔴 2026-09-04 fix round 1 (F4). 이 testset 의 **이름**은 처음부터 "배열·객체" 였는데
    #    배열과 `Int` 만 태우고 있었다 — 객체 사례가 세 시험 어디에도 없었다. 그리고 그
    #    빈 자리에 실제 결함이 있었다: `JSON3.Object` 의 `keytype` 은 `Symbol` 이라
    #    `convert(Dict{String,Any}, ::JSON3.Object)` 는 **던진다**. 즉 이 레포가 도처에서
    #    쓰는 가장 자연스러운 철자로 주석한 객체 인자가 전부 `reject:param_convert:` 로
    #    막혀 원시가 영영 안 돌았다(거절이라 안전하지만 채널은 닫힌 것이다).
    code = """
    function d16_array_tool!(env; task_ids::Array{String,1}=String[], k::Int=0,
                             meta::Dict{String,Any}=Dict{String,Any}())
        return (status = Symbol("saw_", length(task_ids), "_", k, "_", length(meta)),)
    end
    """
    params = Dict{String,Any}("task_ids" => Dict("type" => "array",
                                                 "items" => Dict("type" => "string")),
                              "k" => Dict("type" => "integer"),
                              "meta" => Dict("type" => "object"))
    @test CB.register_minted_primitive!(name = "d16_array_tool!", code = code,
                                        params = params, surface = "sched",
                                        reversible = false) === nothing
    prim = CB.resolve_primitive("d16_array_tool!")
    @test prim !== nothing
    calls = CB.normalize_calls(JSON3.read(
        """[{"primitive":"d16_array_tool!","args":{"task_ids":["t1","t2","t3"],"k":7,""" *
        """"meta":{"a":1,"b":2}}}]"""))
    @test !(calls isa String)
    b = CB.bind_primitive_args(prim, (env = :DUMMY, truth = nothing, params = calls[1][2]))
    @test !(b isa String)
    # 🔴 뷰가 아니라 네이티브 컨테이너여야 한다
    @test b[2].task_ids isa Vector{String}
    # 🔴 F4: 키를 `Symbol` 에서 `String` 으로 옮겨 주는 것은 **경계의 몫**이다.
    @test b[2].meta isa Dict{String,Any}
    @test b[2].meta["a"] == 1 && b[2].meta["b"] == 2
    r = Base.invokelatest(getfield(CB, Symbol("d16_array_tool!")), b[1]...; b[2]...)
    @test r.status === :saw_3_7_2
end

@testset "(8) 🔴 D16: 변환 실패는 예외가 아니라 거절이다" begin
    CB.reset_minted_table!()
    code = """
    function d16_bad_tool!(env; n::Int=0)
        return (status = :ok,)
    end
    """
    @test CB.register_minted_primitive!(name = "d16_bad_tool!", code = code,
        params = Dict{String,Any}("n" => Dict("type" => "string")),
        surface = "sched", reversible = false) === nothing
    calls = CB.normalize_calls(JSON3.read(
        """[{"primitive":"d16_bad_tool!","args":{"n":"not a number"}}]"""))
    b = CB.bind_primitive_args(CB.resolve_primitive("d16_bad_tool!"),
                               (env = :DUMMY, truth = nothing, params = calls[1][2]))
    @test b isa String
    @test startswith(b, "reject:param_convert:n:")
end

@testset "(9) 🔴 D16: 주석 없는 키워드는 오늘 그대로 흐른다" begin
    CB.reset_minted_table!()
    code = """
    function d16_plain_tool!(env; anything="x")
        return (status = :ok,)
    end
    """
    @test CB.register_minted_primitive!(name = "d16_plain_tool!", code = code,
        params = Dict{String,Any}("anything" => Dict("type" => "string")),
        surface = "sched", reversible = false) === nothing
    prim = CB.resolve_primitive("d16_plain_tool!")
    @test !haskey(prim.param_types, "anything")   # 키가 **없다** (nothing 을 넣지 않는다)
end


@testset "(10) 🔴 D18: 집행 전후 세계 다이제스트가 기록된다" begin
    # 🔴 사전등록 결정 1(R11)이 "못 잰다" 고 적은 축. 오늘의 관측 넷 중 어느 것도 **세계가
    #    바뀌었다** 를 못 잰다: `handled` 는 생성 body 면 구성상 ~100%, `applied` 는 항상
    #    `nothing`, `world_maybe_dirty` 는 무조건 `true`(testset (6) 이 그것을 실측한다),
    #    `steps.status` 는 모델의 자기신고다. `world_delta` 가 그 자리를 대신한다.
    # 🔴 브리핑의 픽스처(`enact_minted_decision!(env, nothing, sl)` — 손으로 지은
    #    `Dict{String,Any}` 를 **decision 자리에** 직접)는 이 파일에서 못 쓴다: 셋째 인자는
    #    `decision` 이라 `decision.synth_lane` 을 읽는데 `Dict` 에는 그 필드가 없어
    #    조기 `:deferred` 로 떨어진다(= body 가 아예 안 돈다). 이 파일의 규약대로
    #    `_lane(...)`(JSON3 왕복) → `_dec(...)` 를 지나간다.
    # ⚠️ `surface` 는 `env_param` 이다(브리핑의 `sched` 가 아니라). `sched` 는
    #    `RESOLVE_SURFACES` 안이라 공통 MILP 재풀이가 돌고, 그러면 이 시험이 재려는 차분에
    #    body 가 아닌 재풀이의 편집이 섞인다 — testset (6) 이 같은 이유로 같은 선택을 했다.
    CB.reset_minted_table!()
    local env = live_cache_env()
    local before = length(env.cache.closed_set)
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "d18_touch_tool!",
        "impl_code" => "function d18_touch_tool!(env; v::Int = 1)\n" *
                       "    push!(env.cache.closed_set, v)\n" *
                       "    return (status = :d18_touched,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["d18_touch_tool!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "d18_touch_tool!",
                                     "args" => Dict{String,Any}("v" => 999_001))]))
    local r = enact_minted_decision!(env, nothing, _dec(e))
    # 전제 — 이 판이 정말 생성 경로이고 body 가 돌았는가(음성 대조 없이 0 을 읽지 않는다).
    @test r.registered === true
    @test r.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :d18_touched
    @test 999_001 in env.cache.closed_set
    # 🔴 재는 것.
    @test r.world_delta !== nothing
    @test r.world_delta.closed == length(env.cache.closed_set) - before
    @test r.world_delta.closed == 1
end

@testset "(11) 🔴 D18: 무동작 원시의 차분은 0 이다 — nothing 이 아니다" begin
    # 🔴 **이 testset 이 삼상 규약 그 자체다.** `nothing`("못 쟀다")과 0 의 튜플("쟀는데
    #    안 바뀌었다")은 서로 다른 관측이고, `_world_digest` 의 `catch` 가 그 둘을 뭉개면
    #    D18 은 아무것도 안 재는 필드가 된다 — 세계를 안 바꾸는 body 가 정확히 오늘의
    #    지배적인 판이므로(testset (6)), 뭉개진 판에서는 **모든** 판이 `nothing` 으로 보인다.
    CB.reset_minted_table!()
    local env = live_cache_env()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "d18_noop_tool!",
        # 세계를 한 바이트도 안 건드린다 — `env` 를 읽지도 않는다((6) 과 같은 body 모양).
        "impl_code" => "function d18_noop_tool!(env; v::Int = 1)\n" *
                       "    return (status = :d18_did_nothing,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["d18_noop_tool!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "d18_noop_tool!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local r = enact_minted_decision!(env, nothing, _dec(e))
    @test r.registered === true
    @test r.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :d18_did_nothing
    @test r.world_delta !== nothing            # 🔴 "쟀는데 0" 이지 "못 쟀다" 가 아니다
    @test r.world_delta.closed == 0
    @test r.world_delta.active == 0
    @test r.world_delta.n_edges == 0
    @test r.world_delta.n_binding_changed == 0
    # 🔴 음성 대조. 지문을 못 찍는 env 에서는 **같은 모양의 body** 가 `nothing` 을 낸다 —
    #    이 줄이 없으면 위 네 0 이 "다이제스트가 살아 있다" 의 증거가 못 된다(`world_delta`
    #    로 상수 0-튜플을 돌려주는 구현도 위 넷을 전부 통과한다). `BARE_ENV` 에는
    #    `cache`/`sched`/`active_build_steps` 가 하나도 없다.
    # 🔴 **이름을 바꿔야 한다.** 위 body 를 그대로 재사용하면 등록이
    #    `reject:impl_name_already_minted` 로 먼저 돌아서서(실측) 다이제스트 자리에 아예
    #    도달하지 않는다 — 그러면 `nothing` 은 "지문을 못 찍었다" 가 아니라 "집행 전에
    #    거절됐다" 의 증거가 되어 이 대조가 재려던 것을 못 잰다.
    local e0 = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "d18_noop_bare!",
        "impl_code" => "function d18_noop_bare!(env; v::Int = 1)\n" *
                       "    return (status = :d18_did_nothing,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["d18_noop_bare!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "d18_noop_bare!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local r0 = enact_minted_decision!(BARE_ENV, nothing, _dec(e0))
    @test r0.registered === true                      # 집행 자리까지 실제로 갔다
    @test r0.verdict === :admit
    @test length(r0.steps) == 1 && r0.steps[1].status === :d18_did_nothing
    @test r0.world_delta === nothing                  # 🔴 그런데 지문은 못 찍었다
end

@testset "(12) 🔴 D16/F2: zone 블록이 선언 타입 변환을 덮어쓰지 않는다" begin
    # 🔴 2026-09-04 fix round 1 (F2). `bind_primitive_args` 의 키워드 루프 **뒤**에 오는
    #    zone 블록이 `kw[:zone_keys]` 를 **무조건** `Vector{Symbol}` 로 갈아 끼웠다.
    #    생성 원시가 `zone_keys::Array{String,1}` 로 주석하면 D16 이 만들어 준
    #    `Vector{String}` 이 그 자리에서 되돌아가고, 호출이
    #    `TypeError: in keyword argument zone_keys, expected Vector{String}, got
    #    Vector{Symbol}` 로 죽는다 — **거절이 아니라 예외**라 `enact_minted!` 의 catch 가
    #    손도 안 댄 세계를 `partial=true → handled=true` 로 적어 폴백을 삼킨다. 그것이
    #    정확히 이 태스크가 없애려던 사건이다.
    CB.reset_minted_table!()
    code = """
    function d16_zone_tool!(env; zone_keys::Array{String,1}=String[])
        return (status = Symbol("zones_", length(zone_keys)),)
    end
    """
    CB.RESTRICTION_ZONES[][:d16zone] = CB.LazySets.Ball2([0.0, 0.0], 1.0)
    try
        @test CB.register_minted_primitive!(name = "d16_zone_tool!", code = code,
            params = Dict{String,Any}("zone_keys" =>
                Dict("type" => "array", "items" => Dict("type" => "string"))),
            surface = "sched", reversible = false) === nothing
        prim = CB.resolve_primitive("d16_zone_tool!")
        @test prim.param_types["zone_keys"] === Vector{String}
        calls = CB.normalize_calls(JSON3.read(
            """[{"primitive":"d16_zone_tool!","args":{"zone_keys":["d16zone"]}}]"""))
        b = CB.bind_primitive_args(prim, (env = :DUMMY, truth = nothing, params = calls[1][2]))
        @test !(b isa String)
        @test b[2].zone_keys isa Vector{String}
        r = Base.invokelatest(getfield(CB, Symbol("d16_zone_tool!")), b[1]...; b[2]...)
        @test r.status === :zones_1
        # 🔴 음성 대조 — 비켜서기가 **살아 있는 존 검사까지** 끄지 않았다. 이 줄이 없으면
        #    zone 블록을 통째로 건너뛰는 구현도 위를 전부 통과한다.
        calls2 = CB.normalize_calls(JSON3.read(
            """[{"primitive":"d16_zone_tool!","args":{"zone_keys":["d16_not_a_live_zone"]}}]"""))
        b2 = CB.bind_primitive_args(prim, (env = :DUMMY, truth = nothing, params = calls2[1][2]))
        @test b2 isa String
        @test startswith(b2, "reject:unknown_zone_key:")
    finally
        delete!(CB.RESTRICTION_ZONES[], :d16zone)
    end
end

@testset "(13) 🔴 D16/F3: 못 읽는 주석은 **거절**이지 예외가 아니다" begin
    # 🔴 2026-09-04 fix round 1 (F3). `Vector{<:AbstractString}` 는
    #    `Expr(:curly, :Vector, Expr(:<:, :AbstractString))` 이라 `_is_type_shape` 가
    #    거짓이다. 초판은 그 키를 **버렸고**, 그러면 JSON3 뷰가 그대로 흘러 호출이
    #    `TypeError` 로 죽는다 — F2 와 같은 `partial=true → handled=true` 삼킴이다.
    #    즉 "키를 조용히 버린다" 는 이 태스크가 고치려던 바로 그 실패를 남기는 선택지다.
    #    그래서 **삼상**으로 만들었다: 키 없음(주석 없음, testset (9)) · `Type`(읽었다) ·
    #    `String`(주석은 있는데 못 읽었다) — 셋째는 값이 실제로 올 때만 거절이 된다.
    CB.reset_minted_table!()
    code = """
    function d16_where_tool!(env; xs::Vector{<:AbstractString}=String[])
        return (status = :ok,)
    end
    """
    @test CB.register_minted_primitive!(name = "d16_where_tool!", code = code,
        params = Dict{String,Any}("xs" =>
            Dict("type" => "array", "items" => Dict("type" => "string"))),
        surface = "sched", reversible = false) === nothing
    prim = CB.resolve_primitive("d16_where_tool!")
    @test haskey(prim.param_types, "xs")            # 🔴 키가 **있다** — (9) 와 다른 상태다
    @test !(prim.param_types["xs"] isa Type)        #    값은 못 읽은 주석의 **원문**이다
    calls = CB.normalize_calls(JSON3.read(
        """[{"primitive":"d16_where_tool!","args":{"xs":["a","b"]}}]"""))
    b = CB.bind_primitive_args(prim, (env = :DUMMY, truth = nothing, params = calls[1][2]))
    @test b isa String
    @test startswith(b, "reject:param_annotation_unreadable:xs:")
end

end # module
