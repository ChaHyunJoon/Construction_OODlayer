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

# 🔴 이것이 이 태스크의 전부다: `allowed` 는 novelty 교정이 아니라 **사람이 켠 손잡이만**
#    나른다. [역사 · 2026-08-29 §B-1] 여기서 "교정 파일 유무"를 나르던 술어가
#    `have_det`(= `install_novelty!()` 의 반환값)이었고, 그 축이 삭제되면서 그 이름이 가리키던
#    것이 레포에서 없어졌다 — 이 검사가 지키는 명제("격상은 교정과 무관하다")는 그대로다.
t7, m7 = escalation_target(pol7, "surrogate", true)
check("T7 어휘 미달은 손잡이가 켜져 있으면 격상한다(novelty 교정과 무관)",
      t7 == "dspy" && m7 == ["SwapBattery"], "target=$(t7) missing=$(m7)")

# 손잡이를 끈 비교 실행에서는 레인이 안 바뀐다 — 그런데 **진단은 남는다.**
t7b, m7b = escalation_target(pol7, "surrogate", false)
check("T7b 손잡이가 꺼지면 격상은 안 하지만 누락 진단은 남긴다",
      t7b == "" && m7b == ["SwapBattery"], "target=$(t7b) missing=$(m7b)")

# ---------------------------------------------------------------------------------------------
# 🔴 2026-08-29 (§B-1) — **T8 · T8b · T9b · T9c · T9d 를 지웠다** (`@test_skip` 도 주석 처리도
#    아니다: 이 레포의 규칙은 무효가 된 시험은 지우고 왜 지웠는지를 머리말에 적는 것이다).
#
#    다섯이 지키던 명제는 전부 **`router_drives()` 가 `router_enabled()`/`install_novelty!()` 의
#    교정 의존을 되찾지 못하게 하는 것**이었다(Ruling R11 회귀). §B-1 이 novelty 축을 통째로
#    지우면서 `router_enabled()` 도 `install_novelty!()` 도 **레포에 존재하지 않게 됐다** —
#    막으려던 대상이 없으므로 명제가 무효다.
#      · T8   `router_drives()` 의 lowered IR 에 `install_novelty!` 가 없다  → 항진명제가 된다
#      · T8b  (양성 대조) `router_enabled()` 의 lowered IR 에는 있다         → UndefVarError
#      · T9b  `decide_all` 이 `router_enabled()` 를 안 부른다                → 항진명제
#      · T9c  `decide_all` 이 `install_novelty!` 을 안 부른다                → 항진명제
#      · T9d  (양성 대조) `route()` 의 lowered IR 에는 있다                   → **거짓이 된다**
#    🔴 양성 대조(T8b·T9d)가 가리키던 함수가 사라졌으면 대조도 같이 간다 — 대조 없는 항진명제만
#    남기면 "검사는 있는데 막으려는 것을 못 막는다" 는 이 파일이 F2 에서 이름 붙인 실패로 돌아간다.
#    남는 것은 **T9**(`decide_all` 이 `router_drives()` 를 정확히 2회 부른다) 하나이고, 그것은
#    지금도 실제 호출부를 잰다.

# ---------------------------------------------------------------------------------------------
# T9 (2026-08-27, Fix round 2 -- 실제 회귀 지점을 겨눈다) decide_all 의 게이트들이 실제로
#     router_drives() 를 부른다.
#     🔴 2026-08-29 (§B-1): 짝이던 "router_enabled() 를 안 부른다"(T9b) 는 그 함수가 삭제되어
#     지웠다 -- 위 머리말 참조.
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
#     소스 텍스트 grep 을 안 쓴 이유: 파일 전체 grep 은 docstring·주석에 있는 같은 이름에
#     걸려 항진적으로 "OK" 가 나온다(2026-08-29 §B-1 이후 이 파일과 policy.jl 의 역사 주석이
#     정확히 그런 문자열을 들고 있다). lowered 코드는 **decide_all 자신의 본문**만 보므로 그
#     문제가 없다 -- route() 는 별도 메서드라 그 호출은 decide_all 의 lowered 코드에
#     인라인되지 않고 `Main.route(...)` 한 호출로만 보인다.
# ---------------------------------------------------------------------------------------------
wrapper_src = string(@code_lowered decide_all(nothing, nothing))
m9 = match(r"var\"(#decide_all#\d+)\"", wrapper_src)
if m9 === nothing
    # 🔴 (2026-08-27 최종 리뷰 F8) 예전 문구는 "빨강 아님, 미측정" 이라고 적었는데 동작은
    #    `check(..., false)` -> `nfail += 1` -> `exit(1)` 이다. 동작이 옳다(측정 못 한 게이트를
    #    초록으로 넘기면 그게 이 파일이 막으려는 실패 그 자체다) -- 틀린 것은 문구였다.
    check("T9 decide_all 의 숨은 kwarg 바디 함수 이름을 못 찾았다 -- Julia 버전/kwarg 컴파일 " *
          "방식이 바뀐 것으로 보인다. **못 쟀으므로 빨강으로 낸다**(T9/T9b/T9c 가 통째로 " *
          "안 돌았다는 사실을 초록으로 덮지 않는다)", false, wrapper_src)
else
    local bodyfn = getfield(@__MODULE__, Symbol(m9.captures[1]))
    local body_src = string(Base.uncompressed_ast(only(methods(bodyfn))))
    local n_drives  = count("router_drives", body_src)
    # 🔴 (2026-08-27 최종 리뷰 F6) 기대값이 2 -> **3** 이 됐다. 세 번째는 서비스 호출 생략
    #    게이트(`j = ... ? nothing : service_decide(...)`)다. 그 자리는 원래
    #    `!get(rt, "enabled", false)` 를 읽었는데, Task 3 이후 `router_drives()` 가 true 인데
    #    `rt["enabled"]` 가 false 인 상태가 도달 가능해져서 `DEMO_ALL_POLICIES=0` 런이
    #    **라우팅한다고 주장하면서 서비스 호출을 통째로 건너뛰었다** — 그러면 pol["surrogate"]/
    #    pol["dspy"] 가 둘 다 unavailable 이라 축 1 이 구조적으로 발화 불가가 된다.
    #    셋 다 같은 술어를 써야 한다: "라우터가 이 런에서 레인을 모는가".
    check("T9 decide_all 의 실제 게이트 세 곳(서비스 호출 · 레인 선택 · 격상)이 " *
          # 🔴 2026-08-29 (T11/T12): **3 → 2.** 세 게이트 중 하나(표현력 격상)가 사라졌다 —
          #    kind 축에서 zone 은 이미 dspy 라 격상할 곳이 없고, 축 1(어휘 미달)은 kind 축으로
          #    대체됐다(§0-C 결정 2·충돌 ⑤). 남은 둘은 **레인 선택**과 **서비스 청구**다.
          #    ⚠️ 이 숫자를 다시 3 으로 되돌리려 하지 말 것 — 늘었다면 조용한 폴백이나 격상이
          #    돌아온 것이고, 그것이 §0-C 결정 3 이 없앤 바로 그 상태다.
          "router_drives() 를 부른다(정확히 2회 기대)",
          n_drives == 2, "n_drives=$(n_drives)")


    # -----------------------------------------------------------------------------------------
    # 🔴 2026-08-29 (T11/T12): 옛 T11·T11b 를 **지웠다** (`@test_skip` 이나 주석 처리가 아니라
    #    삭제 — 이 레포의 규칙). 명제:
    #      T11  "decide_all 이 support_measured 를 rt 에 심는다"
    #      T11b "decide_all 이 vocabulary_gap_arms 를 rt 에 심는다"
    #    둘 다 **축 1(어휘 미달)의 기록**이고, 그 축이 kind 축으로 대체되면서 계산 자체가
    #    사라졌다(§0-C 결정 2·충돌 ⑤). 심을 값이 없으므로 "심는지" 를 물을 수 없다.
    #    그 자리를 대신 지키는 것: `rt["routing_kind"]`·`rt["router_axis"]`·`rt["lane_reason"]`
    #    이고, 그 셋의 게이트는 `tools/monitor/test_lane_select.jl`(분기표 전수)과
    #    `test/tool_choice_gate.jl` (7)절(두 kind 유도의 교차 게이트)이다.
    #    ⚠️ T10(아래, `surrogate_support_measured` 의 순수 함수 계약)은 **남긴다** — 그 함수는
    #    아직 존재하고 진단용으로 부를 수 있다. 다만 **생산 호출자가 0개**가 됐다.
    # -----------------------------------------------------------------------------------------
end

# ---------------------------------------------------------------------------------------------
# T10 (2026-08-27, 최종 리뷰 F4) `surrogate_support_measured` 의 계약.
#
# 🔴 왜: `supported = isempty(missing)` 은 Bool 하나라 **"재서 없다"와 "못 쟀다"가 같은 값**이
#     된다. 독립 검증 에이전트 실측 —
#
#         support UNKNOWN(모델 적재 실패) → unsupported=[] → supported=true → axis="none"
#         진짜 어휘 미달                  → unsupported=[SwapBattery] → supported=false → axis="vocabulary_gap"
#
#     즉 축 1 이 자기가 존재하는 이유인 그 실패 모드에서 스스로를 과소 집계했다. Ruling R13 에
#     따라 axis enum 은 그대로 두고 **기록에** 구분을 남긴다.
#
# 아래 dict 들은 손으로 쓴 복제본이 아니라 **실제 생산자**(`policy_entry`)의 출력이다 — 이 파일
# 37-46 행이 왜 그래야 하는지 적는다(복제본을 검사하면 복제본만 지켜진다).
#
# 무엇이 바뀌면 빨개지나: 유도가 다시 `isempty(missing)` 하나로 접히거나, `available` 을 안 보게
# 되거나, 못 쟀을 때 `true` 를 돌려주게 되면.
# ---------------------------------------------------------------------------------------------
# (a) 못 쟀다 — 서비스가 "support is unknown" 으로 되돌린 실제 모양(chosen 비었고 unsupported 도 빈다).
m_unknown = policy_entry((chosen = "", ranking = String[], unsupported = String[],
                          error = "surrogate macro support is unknown (model not loaded)"),
                         "surrogate:SurrogateV2")
check("T10 지원집합을 못 쟀으면 support_measured=false " *
      "(unsupported 가 비어 있다고 '전부 지원'으로 읽지 않는다)",
      surrogate_support_measured(m_unknown, String[]) == false,
      "entry=$(m_unknown)")
# (b) 재서 없다 — 점수를 냈고 누락도 없다. 같은 `unsupported=[]` 인데 사건이 다르다.
m_all_ok = avail("SwapBattery")
check("T10b 재서 미달이 없으면 support_measured=true (위와 unsupported 는 똑같이 비어 있다)",
      surrogate_support_measured(m_all_ok, String[]) == true, "entry=$(m_all_ok)")
# (c) 진짜 어휘 미달 — UNSUPPORTED 규약. 지원집합을 읽었으므로 쟀다.
m_gap = unavail(unsup = ["SwapBattery"])
check("T10c UNSUPPORTED 규약이 나왔으면(= 지원집합을 읽었다) support_measured=true",
      surrogate_support_measured(m_gap, ["SwapBattery"]) == true, "entry=$(m_gap)")

# ---------------------------------------------------------------------------------------------
# T12 (2026-08-27, 최종 리뷰 F3) 라우터의 **기록이 자기가 집행한 레인과 모순되지 않는다.**
#
# 🔴 실측(2026-08-27 당시 작업 트리 기본 env):
#
#       router_drives()  = true       # decide_all 이 select_lane 으로 레인을 고른다
#       select_lane(...) -> lane=surrogate
#
#   그런데 `route_verdict` 는 `"gate inactive (DEMO_POLICY=canonical fixed for the run)"` 을
#   찍었고, Task 3 이 거기에 `" · LANE: …"` 를 덧붙여 **자기모순 문자열**을 만들었다.
#   `dashboard.html` 이 그 문자열로 `ROUTER off` 를 렌더했다 — 라우터가 실제로 결정한 판에 대해.
#   [역사] 당시 그 분기를 고른 술어는 `router_enabled() = false`("novelty calibration not
#   found")였다. 🔴 2026-08-29 §B-1 이 그 축을 지웠으므로 오늘 `reason` 을 가르는 것은
#   `drives_lane` **하나뿐**이고, 아래 검사가 재는 명제는 그때와 같다.
#
# 🔴 2026-08-29 (§B-1) — **T12d · T12e 를 지웠다.** 그 둘은 `route_verdict` 의 **advisory 분기**
#    (`have_det=true` · `drives=false` · `v` 주입 → "advisory only …")를 쟀는데, novelty 축이
#    삭제되면서 그 분기도 `v`/`eps` 키워드도 없어졌다. 잴 대상이 없으므로 지운다(주석 처리도
#    `@test_skip` 도 아니다). 남는 T12/T12b/T12c 가 같은 명제를 두 분기 전수로 지킨다.
#
# 무엇이 바뀌면 빨개지나: `reason` 이 다시 `drives_lane` 과 무관해지거나(= 레인을 몰면서도
# "fixed for the run"/"gate inactive" 를 주장), `drives_lane` 키가 사라지면.
# ⚠️ `drives_lane` 을 kwarg 로 명시해 잰다 — `ROUTER_MODE`/`POLICY` 는 `const` 라 같은
#    프로세스 안에서 ENV 로 가를 수 없다.
# ---------------------------------------------------------------------------------------------
v_drive = route_verdict(desc = nothing, policy = "canonical", drives_lane = true)
v_fixed = route_verdict(desc = nothing, policy = "canonical", drives_lane = false)
check("T12 route_verdict 가 레인 구동 사실(drives_lane)을 나른다",
      v_drive["drives_lane"] === true && v_fixed["drives_lane"] === false,
      "drive=$(get(v_drive, "drives_lane", :MISSING)) fixed=$(get(v_fixed, "drives_lane", :MISSING))")
check("T12b 라우터가 레인을 몰면 reason 이 'fixed for the run' / 'gate inactive' 를 주장하지 않는다",
      !occursin("fixed for the run", v_drive["reason"]) &&
      !occursin("gate inactive", v_drive["reason"]), v_drive["reason"])
check("T12c (음성 대조) 라우터가 안 몰면 예전 문구가 그대로 남는다 " *
      "— 정책 고정 비교 녹화의 기록이 바뀌면 안 된다",
      occursin("fixed for the run", v_fixed["reason"]) &&
      occursin("gate inactive", v_fixed["reason"]), v_fixed["reason"])

println()
println(nfail == 0 ? "전부 통과 ($(npass))" : "$(nfail)개 실패 / $(npass)개 통과")
exit(nfail == 0 ? 0 : 1)

end # module
