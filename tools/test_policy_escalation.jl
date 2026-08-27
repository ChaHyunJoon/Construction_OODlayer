# tools/test_policy_escalation.jl
# =============================================================================
# **표현력 격상 게이트**(`policy.jl:escalation_target`)의 자기점검.
#
# 왜 이 파일이 필요한가 (2026-08-14)
# ----------------------------------
# 이 게이트는 "싼 정책이 이 사건의 유효 매크로를 표현조차 못 하면 LLM 으로 올린다" 다.
# 그런데 판정이 `decide_all` 안에 인라인으로 있어 env·truth·파이썬 서비스가 전부 살아 있어야
# 검사할 수 있었고, 그래서 한 번도 검사되지 않았다. 그 사이 정확히 이런 회귀가 들어왔다:
#
#   surrogate 가 "개입 후보가 전멸했다"(supported ∩ legal = {NOOP})를 알리는 방법은
#   `UNSUPPORTED:` + 빈 chosen 이다 -> `available = false` -> `enacted` 는 이 판정 **전에**
#   이미 canonical 로 떨어진다 -> 옛 조건은 `pol[enacted]["unsupported"]` 를 읽었는데
#   pol["canonical"] 에는 그 키가 없다 -> 게이트가 **영원히 안 열린다**.
#
# 즉 격상이 존재하는 이유가 되는 바로 그 사건에서만 꺼져 있었다. 스윕(--router 0)에서는
# 무해하지만 데모·라우터 런에서는 살아 있는 결함이다. 여기서 Dict 만으로 못박는다.
#
# 시뮬레이터도 서비스도 띄우지 않는다(판정이 순수 함수라 Dict 수준에서 전부 검증 가능).
#
# 실행:  julia +lts --project=. tools/test_policy_escalation.jl
# =============================================================================
module TestPolicyEscalation

import HTTP, JSON3
using InteractiveUtils: @code_lowered   # T8 의 정적 검사(아래)가 쓴다 -- stdlib, Pkg.add 아님
include(joinpath(@__DIR__, "monitor", "policy.jl"))

npass = 0; nfail = 0
function check(name, ok, detail = "")
    global npass, nfail
    ok ? (npass += 1) : (nfail += 1)
    println("  [", ok ? "PASS" : "FAIL", "] ", name, isempty(detail) ? "" : "  -- " * detail)
end

# ---------------------------------------------------------------------------------------------
# dict 는 **실제 생산자**(`policy.policy_entry`)로 만든다 — 손으로 쓴 복제본이 아니다.
#
# 2026-08-14 최종 리뷰가 잡은 것: 이 파일의 `unavail()` 은 원래 `decide_all` 이 만드는 dict 의
# 축자 복제본이었다. 실측 — `policy.jl` 의 폴백 분기에서 `"unsupported" => miss0` 를 지워도
# 여기 9개 검사가 **전부 초록**이었고 회귀(격상이 영원히 안 열림)가 그대로 복원됐다.
# 복제본을 검사하면 복제본만 지켜진다. 그래서 `decide_all` 의 dict 조립부를 `policy_entry`
# 로 뽑아 여기서 그 함수를 부른다: 이제 그 줄을 지우면 T0/T1 이 즉시 빨개진다.
#
# 인자는 서비스 응답(JSON3 object)의 자리에 NamedTuple 을 넣는다 — `policy_entry` 는
# `get(b, :key, default)` 와 `b.chosen` 만 쓰므로 둘의 인터페이스가 같다.
# ---------------------------------------------------------------------------------------------
avail(chosen; unsup = String[]) =
    policy_entry((chosen = chosen, ranking = [chosen], margin = 0.5, rationale = "",
                  unsupported = unsup, policy = "x"), "surrogate:RandomForest")
# ↓ Ruling 1 이후 surrogate 가 "개입 전멸" 을 알릴 때 서비스가 보내는 것: chosen 이 비어 있고
#   unsupported 만 실려 있다. `policy_entry` 는 이것을 available=false dict 로 바꾼다.
#   이 모양이 곧 회귀의 현장이다.
unavail(; unsup = String[]) =
    policy_entry((chosen = "", ranking = String[], unsupported = unsup, error = nothing), "x")
canon(chosen) =
    Dict("chosen" => chosen, "ranking" => [chosen], "margin" => nothing, "rationale" => "",
         "label" => "canonical", "available" => true)          # ← unsupported 키가 **없다**

println("== 표현력 격상 게이트 ==")

# ---------------------------------------------------------------------------------------------
# T0  (생산자 계약) `policy_entry` 의 폴백 dict 가 `unsupported` 를 **싣는다**.
#     이것이 위 unavail() 이 fixture 가 아니라 출력이라는 사실 그 자체의 검사다 — 이 키를
#     policy.jl 에서 지우면 여기서 먼저 죽는다.
# ---------------------------------------------------------------------------------------------
u0 = unavail(unsup = ["ReformTeam"])
check("T0 생산자가 낸 폴백 dict 에 unsupported 가 실려 있다",
      haskey(u0, "unsupported") && u0["unsupported"] == ["ReformTeam"] &&
      u0["available"] == false && isempty(u0["chosen"]),
      "dict=$(u0)")
check("T0b 폴백 dict 의 rationale 이 어느 팔이 없었는지 말한다",
      occursin("ReformTeam", u0["rationale"]), u0["rationale"])
a0 = avail("ReformTeam", unsup = ["RelocateBuild"])
check("T0c 생산자가 낸 available dict 도 unsupported 를 보존한다",
      a0["available"] == true && a0["chosen"] == "ReformTeam" &&
      a0["unsupported"] == ["RelocateBuild"] && a0["label"] == "x", "dict=$(a0)")

# ---------------------------------------------------------------------------------------------
# T1  (회귀의 현장) surrogate 가 available=false 로 와도, unsupported 가 있으면 격상한다.
#     옛 코드는 여기서 아무것도 안 했다: enacted 가 이미 canonical 이었고 그 dict 에는
#     unsupported 키가 없었기 때문이다.
# ---------------------------------------------------------------------------------------------
pol1 = Dict("canonical" => canon("ReformTeam"),
            "surrogate" => unavail(unsup = ["ReformTeam"]),
            "dspy"      => avail("ReformTeam"))
t1, m1 = escalation_target(pol1, "surrogate", true)
check("T1 개입 전멸(available=false)이어도 unsupported 가 있으면 dspy 로 격상",
      t1 == "dspy" && m1 == ["ReformTeam"], "target=$(t1) missing=$(m1)")

# ---------------------------------------------------------------------------------------------
# T2  판정은 **요청된** 정책을 본다. enacted(=canonical)를 보면 안 된다.
#     canonical dict 에는 unsupported 키 자체가 없으므로, 그것을 읽으면 언제나 빈 값이다.
# ---------------------------------------------------------------------------------------------
t2, m2 = escalation_target(pol1, "canonical", true)
check("T2 canonical 을 기준으로 보면 격상 근거가 없다(= 옛 코드가 읽던 자리)",
      t2 == "" && isempty(m2), "target=$(t2) missing=$(m2)")

# ---------------------------------------------------------------------------------------------
# T3  기존 경로 회귀 방지: available=true + unsupported 도 그대로 격상한다.
# ---------------------------------------------------------------------------------------------
pol3 = Dict("canonical" => canon("NOOP"),
            "surrogate" => avail("NOOP", unsup = ["RelocateBuild"]),
            "dspy"      => avail("RelocateBuild"))
t3, m3 = escalation_target(pol3, "surrogate", true)
check("T3 고를 수는 있었지만 일부 팔이 없던 기존 경로도 그대로 격상",
      t3 == "dspy" && m3 == ["RelocateBuild"], "target=$(t3) missing=$(m3)")

# ---------------------------------------------------------------------------------------------
# T4  라우터가 꺼져 있으면(정책 비교 런) 격상하지 않는다 — 그러나 **누락 목록은 돌려준다**.
#     그 목록이 스트림의 `requested_unsupported` 가 되어, 라우터가 꺼진 스윕에서도
#     "이 사건에서 무엇을 표현 못 했나"가 기록으로 남는다.
# ---------------------------------------------------------------------------------------------
t4, m4 = escalation_target(pol1, "surrogate", false)
check("T4 라우터 OFF 면 격상 안 함(정책 고정 비교가 조용히 오염되지 않는다)", t4 == "")
check("T4b 격상은 안 해도 누락 목록은 기록용으로 남는다", m4 == ["ReformTeam"], "missing=$(m4)")

# ---------------------------------------------------------------------------------------------
# T5  격상 대상이 없거나(dspy 불가) 요청이 이미 dspy 면 격상하지 않는다.
# ---------------------------------------------------------------------------------------------
pol5 = Dict("canonical" => canon("ReformTeam"),
            "surrogate" => unavail(unsup = ["ReformTeam"]),
            "dspy"      => Dict("chosen" => "", "ranking" => String[], "margin" => nothing,
                                "rationale" => "", "label" => "dspy", "available" => false))
t5, _ = escalation_target(pol5, "surrogate", true)
check("T5 dspy 도 못 쓰면 격상하지 않는다(갈 곳이 없다)", t5 == "")
t5b, _ = escalation_target(pol1, "dspy", true)
check("T5b 이미 dspy 면 자기 자신으로 격상하지 않는다", t5b == "")

# ---------------------------------------------------------------------------------------------
# T6  누락이 없으면 격상하지 않는다. 없는 정책 이름에도 죽지 않는다.
# ---------------------------------------------------------------------------------------------
pol6 = Dict("canonical" => canon("Replace"),
            "surrogate" => avail("Replace"),
            "dspy"      => avail("Replace"))
t6, m6 = escalation_target(pol6, "surrogate", true)
check("T6 누락이 없으면 격상하지 않는다", t6 == "" && isempty(m6))
t6b, m6b = escalation_target(pol6, "oracle", true)
check("T6b 모르는 정책 이름이면 조용히 빈 값(예외 아님)", t6b == "" && isempty(m6b))

# ---------------------------------------------------------------------------------------------
# T7 (2026-08-27, 계약 고정) 어휘 미달 격상은 novelty 교정과 무관하다.
#     🔴 이 파일에는 `@testset`이 없다(자체 check() 관용구로 센다) — 파일 끝의 println/exit
#     뒤에 @testset을 붙이면 exit 뒤의 죽은 코드가 되어 영원히 안 도는 검사가 된다.
#     `pol` 은 서비스 응답을 정규화한 Dict 다. surrogate 가 SwapBattery 를 학습한 적이 없다.
# ---------------------------------------------------------------------------------------------
pol7 = Dict(
    "surrogate" => Dict("chosen" => "NOOP", "available" => true,
                        "unsupported" => ["SwapBattery"]),
    "dspy"      => Dict("chosen" => "SwapBattery", "available" => true))

# 🔴 이것이 이 태스크의 전부다: 교정 파일이 없어도(=have_det false) 어휘 미달은 격상한다.
#    `allowed` 는 이제 have_det 이 아니라 사람이 켠 손잡이만 나른다.
t7, m7 = escalation_target(pol7, "surrogate", true)
check("T7 어휘 미달은 손잡이가 켜져 있으면(have_det 와 무관) 격상한다",
      t7 == "dspy" && m7 == ["SwapBattery"], "target=$(t7) missing=$(m7)")

# 손잡이를 끈 비교 실행에서는 레인이 안 바뀐다 — 그런데 **진단은 남는다.**
t7b, m7b = escalation_target(pol7, "surrogate", false)
check("T7b 손잡이가 꺼지면 격상은 안 하지만 누락 진단은 남긴다",
      t7b == "" && m7b == ["SwapBattery"], "target=$(t7b) missing=$(m7b)")

# ---------------------------------------------------------------------------------------------
# T8 (2026-08-27, Fix round 1 — 재발 방지) 격상 손잡이(`router_drives`)는 교정 파일 유무를
#     나르지 않는다.
#
#     round 1 은 `escalation_allowed`/select_lane 게이트에 `router_enabled() && POLICY != "noop"`
#     를 썼는데, `router_enabled()` 는 `install_novelty!()` 를 불러 **교정 JSON 유무**를 도로
#     실어 왔다 — "뗀다"고 한 have_det 결합이 하나도 안 끊긴 회귀. 그래서 `router_drives()` 를
#     새로 만들었다(policy.jl). 🔴 (2026-08-27, Fix round 2 정정) 이 T8/T8b 는 `router_drives()`
#     **자신의 정의**가 교정 의존을 되찾을 때만 빨개진다 -- decide_all 의 **호출부**가 다시
#     `router_enabled()` 로 되돌아가는 실제로 일어났던 회귀 경로는 안 잡는다(그건 아래 T9/T9b 가
#     잡는다). "이 T8 은 그 재발을 막는다" 는 round 1 의 과장이었다.
#
#     ENV 를 바꿔 프로세스 재기동으로 검사하는 방법은 안 썼다 — `ROUTER_MODE`/`POLICY` 가
#     `const` 라 같은 프로세스 안에서는 재현이 안 되고, 이 파일이 여러 프로세스를 띄우면
#     "시뮬레이터도 서비스도 안 띄운다"는 이 파일의 원래 계약(19행)이 깨진다. 대신 **정적
#     검사**를 골랐다: `router_drives()` 의 저수준 코드(lowered IR)에 `install_novelty!` 호출이
#     **문법적으로 존재하지 않는다**는 것은 어떤 ENV 조합에서도 참인, 더 강한 계약이다.
#     대조군으로 `router_enabled()` 의 lowered 코드에는 그 호출이 실제로 있다는 것도 같이
#     확인해 이 검사 방법 자체가 뭔가를 놓치고 있지 않다는 것을 보인다(양성 대조).
# ---------------------------------------------------------------------------------------------
lowered_drives  = string(@code_lowered router_drives())
lowered_enabled = string(@code_lowered router_enabled())
check("T8 router_drives() 의 lowered 코드에 install_novelty! 호출이 없다(정적 -- ENV 무관)",
      !occursin("install_novelty", lowered_drives), lowered_drives)
check("T8b (양성 대조) router_enabled() 의 lowered 코드에는 install_novelty! 호출이 있다 " *
      "-- 즉 위 검사 방법이 실제로 그 호출을 잡아낼 수 있다",
      occursin("install_novelty", lowered_enabled))

# ---------------------------------------------------------------------------------------------
# T9 (2026-08-27, Fix round 2 -- 실제 회귀 지점을 겨눈다) decide_all 의 두 게이트가 실제로
#     router_drives() 를 부르고 router_enabled() 를 안 부른다.
#
#     리뷰 지적(round 2, I-2): T8/T8b 는 router_drives() **자신의 정의**만 재서, 실제로 났던
#     회귀(policy.jl:1073/:1105 의 **호출부**가 router_enabled() 를 썼던 것)를 되돌려도 초록으로
#     남는다 -- decide_all 이 그 두 줄에서 여전히 router_drives() 대신 router_enabled() 를 부르게
#     되돌려도 T8/T8b 는 router_drives() 정의 자체가 안 바뀌었으니 안 빨개진다. 이 T9 이 그
#     구멍을 메운다: **호출부**를 직접 본다.
#
#     decide_all 은 keyword 인자(`nl::AbstractString=""`)가 있어 Julia 가 실제 본문을 숨은
#     `#decide_all#N` 함수로 컴파일한다(N 은 Julia 내부 카운터라 하드코딩하지 않고, decide_all
#     자신의 lowered 코드에서 정규식으로 찾는다). `@code_lowered`/`Base.uncompressed_ast` 는
#     함수를 **실행하지 않는다** -- env/truth 자리에 `nothing` 을 넣어도 안전하다(호출이 아니라
#     메서드 선택 + 정적 조회뿐이고, 인자 타입이 전부 `Any` 라 `nothing` 으로도 같은 메서드가
#     골라진다).
#
#     소스 텍스트 grep 을 안 쓴 이유: `route()` 안의 `drives = have_det && router_enabled() &&
#     POLICY != "noop"`(novelty 축, 정당한 용법)에도 `router_enabled` 문자열이 있어서
#     파일 전체 grep 은 그 정당한 용법에 걸려 항진적으로 "OK" 가 나온다. lowered 코드는
#     **decide_all 자신의 본문**만 보므로 그 문제가 없다 -- route() 는 별도 메서드라 그 호출은
#     decide_all 의 lowered 코드에 인라인되지 않고 `Main.route(...)` 한 호출로만 보인다.
# ---------------------------------------------------------------------------------------------
wrapper_src = string(@code_lowered decide_all(nothing, nothing))
m9 = match(r"var\"(#decide_all#\d+)\"", wrapper_src)
if m9 === nothing
    check("T9 decide_all 의 숨은 kwarg 바디 함수 이름을 못 찾았다 -- Julia 버전/kwarg 컴파일 " *
          "방식이 바뀐 것으로 보인다. 이 검사는 못 쟀다(빨강 아님, 미측정)", false, wrapper_src)
else
    local bodyfn = getfield(@__MODULE__, Symbol(m9.captures[1]))
    local body_src = string(Base.uncompressed_ast(only(methods(bodyfn))))
    local n_drives  = count("router_drives", body_src)
    local n_enabled = count("router_enabled", body_src)
    check("T9 decide_all 의 실제 게이트 두 곳이 router_drives() 를 부른다(정확히 2회 기대)",
          n_drives == 2, "n_drives=$(n_drives)")
    check("T9b decide_all 은 router_enabled() 를 직접 부르지 않는다 " *
          "(그 함수는 별도 메서드인 route() 안에서만, novelty 축에 정당하게 쓰인다)",
          n_enabled == 0, "n_enabled=$(n_enabled)")
end

println()
println(nfail == 0 ? "전부 통과 ($(npass))" : "$(nfail)개 실패 / $(npass)개 통과")
exit(nfail == 0 ? 0 : 1)

end # module
