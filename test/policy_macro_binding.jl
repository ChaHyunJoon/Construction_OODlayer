# =============================================================================
# `tools/monitor/policy.jl` 의 `enactable_macros()` 가 행동 어휘의 단일 진실원
# (`wm4spacecraft_manufacturing/core/action_registry.json`)에 **묶여 있는지** 못박는다.
#
# 왜 이 파일이 필요한가 (2026-08-24, Task 6 수정 라운드 1 · 판정 R-46)
# ------------------------------------------------------------------
# 이 메뉴는 처음에 `const ENACTABLE_MACROS = (...)` 라는 **리터럴 튜플**로 들어왔고
# `"ReformTeam"` 을 포함했다.
# 그 이름은 레지스트리가 2026-08-20 에 삭제한 팔이라, `DEMO_FORCE_MACRO=ReformTeam` 이
# 검사를 통과한 뒤 `macro_to_proposal` → `run_demo.jl` 의 `mac == "ReformTeam"` 분기로
# **실제로 집행됐다.** 그러면 어휘 도장이 `v4-3arms` 인 판에 어휘 밖 팔이 라벨로 박히고,
# `truth_key(::ReformTruth)` 는 이미 삭제됐으므로 그 결정은 **영원히 grounding 되지 않는다**
# (= 매번 순수 hallucination 으로 채점된다). 리터럴은 레지스트리의 네 번째 진실원이었다.
#
# 이 파일이 재는 것은 두 방향이다. 한 방향만 재면 반쪽이다:
#   (A) 메뉴 ⊆/⊇ 레지스트리 — 리터럴이 되살아나거나 은퇴한 이름이 섞이면 빨개진다.
#   (B) 메뉴의 모든 이름이 `macro_to_proposal` 에서 **실제로 집행된다** — 레지스트리에
#       팔을 늘리고 policy.jl 에 분기를 안 만들면(= 빈 제안으로 조용히 떨어지면) 빨개진다.
#   (C) 두 손잡이(`DEMO_FORCE_MACRO` · `DS_DEVIATE_ARM`)가 **둘 다** 그 메뉴로 막힌다.
#       (C)는 로드 시점 `error()` 라서 서브프로세스로만 잴 수 있다. 양성 대조를 같이 둔다 —
#       그게 없으면 "무슨 이유로든 죽었다" 를 "메뉴가 막았다" 로 오독한다.
#   (D) 🔴 2026-08-25 (최종 브랜치 리뷰 C2) `valid_macros(env, ::BatteryTruth)` 도 같은
#       레지스트리에서 유도된다. R-46 은 `enactable_macros()`(디버그 손잡이 둘을 게이트한다)만
#       고쳤고 **420줄 위의 진짜 메뉴**는 하드코딩 튜플로 남아 있었다 — 그 반환값이 LLM 의
#       메뉴·oracle/canonical 규칙의 메뉴·채점기가 읽는 `valid` 필드다. (A)~(C) 만으로는
#       그 자리를 한 번도 재지 못한다.
#
# 실행:  julia +lts --project=. test/policy_macro_binding.jl
# =============================================================================
module PolicyMacroBinding

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3

const REPO = normpath(joinpath(@__DIR__, ".."))

# policy.jl 은 이 모듈 안으로 include 된다 — `ActionRegistry` 도 policy.jl 의 가드 있는
# include 를 통해 같이 들어온다(그래서 여기서 따로 include 하지 않는다: 그러면 두 번째
# 진실원이 아니라 두 번째 **로더 경로**가 생긴다).
# (D) 가 `BatteryTruth`/`BATTERY_FLEET` 를 쓴다 — 둘 다 navigator 레이어에 있고 기본
# `using ConstructionBots` 로는 안 들어온다. policy.jl 의 ActionRegistry include 와 같은
# 가드 패턴으로 한 번만 얹는다(전체 스위트에서는 test_demo.jl 이 먼저 얹어 둔다).
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

include(joinpath(REPO, "tools", "monitor", "policy.jl"))

const MENU = collect(enactable_macros())
const REGISTRY_MENU = [ActionRegistry.NAME[i] for i in ActionRegistry.active_ids()]

# 세 묶음을 바깥 @testset 으로 싼다 — 안 그러면 (A) 가 빨개지는 순간 거기서 던져서
# (B)·(C) 가 **아예 안 돌고**, 변형 검증이 "어느 게이트가 잡았나" 를 못 보여준다.
@testset "policy.jl enactable_macros() ↔ action_registry.json" begin

@testset "(A) enactable_macros() 는 action_registry.json 에서 유도된다" begin
    # 순서까지 같아야 한다 — 리터럴로 되돌리면 순서가 맞아도 내용이 갈리고, 내용이 맞아도
    # 레지스트리를 안 읽는다는 사실 자체가 이 어서션으로 드러난다.
    @test MENU == REGISTRY_MENU
    @test length(MENU) == length(ActionRegistry.active_ids())

    # 은퇴한 이름은 하나도 통과하면 안 된다. `ReformTeam` 이 라운드 1 의 실제 결함이다.
    for retired in ("ReformTeam", "Deprioritize", "DeprioritizeAgent",
                    "RelocateBuild", "ForbidZone", "ForbidAgent", "ForbidWindow")
        @test !(retired in MENU)
    end
end

@testset "(B) 메뉴의 모든 이름이 실제로 집행된다 (빈 제안으로 안 떨어진다)" begin
    truth = (robot = CB.RobotID(3),)
    for name in MENU
        prop = macro_to_proposal(truth, name)
        if name == "NOOP"
            # NOOP 은 "제약 없음"이 정답이다(policy.jl 의 계약). 빈 제안이 정상.
            @test isempty(prop.constraints)
        else
            # 여기가 빨개지면 레지스트리에 팔이 늘었는데 `macro_to_proposal` 에 분기가 없다는
            # 뜻이다 — 화이트리스트는 통과하는데 집행은 안 되는, 고치려던 그 결함이다.
            @test !isempty(prop.constraints)
        end
    end
end

# ---------------------------------------------------------------------------------------------
# (C) 두 손잡이가 같은 메뉴로 막힌다. 로드 시점 `error()` 이므로 서브프로세스로 잰다.
# ---------------------------------------------------------------------------------------------
"policy.jl 을 빈 모듈에 include 하는 서브프로세스를 띄운다. 반환: (exitcode, 합친 출력)"
function load_policy(overrides::Pair{String,String}...)
    env = copy(ENV)
    # 부모가 켜 둔 두 손잡이를 **반드시** 지운다 — 안 그러면 양성 대조가 부모 환경을 잰다.
    for k in ("DEMO_FORCE_MACRO", "DS_DEVIATE_ARM", "DS_DEVIATE_AT")
        delete!(env, k)
    end
    for (k, v) in overrides
        env[k] = v
    end
    code = """
    module _M
    import HTTP, JSON3
    include(raw"$(joinpath(REPO, "tools", "monitor", "policy.jl"))")
    println("LOADED_OK")
    end
    """
    out = Pipe()
    p = run(pipeline(setenv(`$(Base.julia_cmd()) --project=$(REPO) -e $code`, env),
                     stdout = out, stderr = out), wait = false)
    close(out.in)
    txt = read(out, String)
    wait(p)
    return (p.exitcode, txt)
end

@testset "(C) DEMO_FORCE_MACRO · DS_DEVIATE_ARM 둘 다 이 메뉴로 막힌다" begin
    # 양성 대조 먼저 — 이게 초록이어야 아래의 빨강이 "메뉴가 막았다" 를 뜻한다.
    ok_code, ok_txt = load_policy()
    @test ok_code == 0
    @test occursin("LOADED_OK", ok_txt)

    for arm in MENU
        c, t = load_policy("DEMO_FORCE_MACRO" => arm)
        @test c == 0
        @test occursin("LOADED_OK", t)
    end

    c1, t1 = load_policy("DEMO_FORCE_MACRO" => "ReformTeam")
    @test c1 != 0
    @test occursin("DEMO_FORCE_MACRO", t1) && occursin("ReformTeam", t1)

    c2, t2 = load_policy("DS_DEVIATE_ARM" => "ReformTeam", "DS_DEVIATE_AT" => "1")
    @test c2 != 0
    @test occursin("DS_DEVIATE_ARM", t2) && occursin("ReformTeam", t2)

    # DS_DEVIATE_ARM 의 양성 대조: 메뉴 안의 이름은 통과해야 한다.
    # 이름은 **메뉴에서 뽑는다** — 여기에 "SwapBattery" 라고 적으면 이 파일이 어휘의 또 다른
    # 리터럴 사본이 되고, 그게 바로 이 게이트가 막으려는 결함이다.
    local pos_arm = first(a for a in MENU if a != "NOOP")
    c3, t3 = load_policy("DS_DEVIATE_ARM" => pos_arm, "DS_DEVIATE_AT" => "1")
    @test c3 == 0
    @test occursin("LOADED_OK", t3)
end

@testset "(D) valid_macros(::BatteryTruth) 도 레지스트리에서 유도된다" begin
    # 오늘의 레지스트리에서 기대되는 두 메뉴를 **레지스트리에서** 만든다(리터럴 금지).
    local batt_ids = ActionRegistry.kind_valid("battery")
    local full     = [ActionRegistry.NAME[i] for i in batt_ids]
    # 배터리 레이어가 꺼진 판의 메뉴 = battery 전용이 아닌 팔만.
    local no_fleet = [ActionRegistry.NAME[i] for i in batt_ids
                      if length(collect(ActionRegistry.REGISTRY[i].kinds)) > 1]

    local truth = CB.BatteryTruth(CB.RobotID(3), 0.05)
    local saved = CB.BATTERY_FLEET[]
    try
        CB.BATTERY_FLEET[] = CB.BatteryFleet(CB.BatteryParams(), Dict{Any,Float64}(),
                                             Dict{Any,Float64}(), Dict{Any,Int}(), Set{Any}())
        @test valid_macros(nothing, truth) == full
        # 메뉴가 레지스트리의 부분집합이라는 것도 따로 못박는다 — 리터럴로 되돌아가면
        # 위 등식과 함께 여기도 빨개진다.
        @test all(m -> m in REGISTRY_MENU, valid_macros(nothing, truth))

        CB.BATTERY_FLEET[] = nothing
        @test valid_macros(nothing, truth) == no_fleet
        # 전제조건 분기가 실제로 무언가를 뺀다(= 두 메뉴가 다르다). 같아지면 이 분기가
        # 아무 일도 안 하는 것이고, 그러면 위 두 어서션 중 하나가 항진명제가 된다.
        @test length(no_fleet) < length(full)
    finally
        CB.BATTERY_FLEET[] = saved
    end
end

@testset "(E) valid_macros(::ZoneTruth) 는 어휘 밖 팔을 LLM 메뉴에 넣지 않는다" begin
    # 🔴 2026-08-25. 이 자리는 **비어 있었다**: `valid_macros` 가 zone 에 `String[]` 을 돌려주고,
    # 그러면 `service_decide` 가 `payload["valid"]` 를 아예 안 싣는다 → 서비스의 `_valid_for` 가
    # `VALID.get("zone", MACROS)` 로 **전체 3팔로 폴백**한다(레지스트리에 zone 키가 없으므로).
    # 실측(2026-08-25, gpt-4o): 구역 사건에서 LLM 이 `SwapBattery` 를 2순위로 올렸다. 1순위였다면
    # `run_demo.jl` 의 집행 사슬이 `hasproperty(truth, :robot)` 가드에 걸려 **아무 일도 안 하는데**
    # 결정 기록에는 `macro="SwapBattery"` 가 남는다 — 집행되지 않은 팔이 라벨이 되는, 이 파일이
    # (C) 에서 막으려던 바로 그 오염의 다른 입구다.
    #
    # 정직한 메뉴는 `NOOP` 하나다: 닫힌 어휘에 이 구역의 수복이 **없다**(= `:line_stop`).
    # 그 사실이 메뉴에 드러나야 `decide_all` 의 표현력 에스컬레이션이 의미를 갖는다.
    # 기대값은 `ood_mdp_shim._zone_arms()` 와 **같은 규약**으로 만든다(NOOP + 레지스트리 zone 팔).
    local zone_menu = [ActionRegistry.NAME[i]
                       for i in sort(unique(vcat(0, ActionRegistry.kind_valid(:zone))))]
    local ztruth = CB.ZoneTruth(:zone_test, Float64[0.0, 0.0], 0.5, nothing)

    @test valid_macros(nothing, ztruth) == zone_menu
    # 로봇을 지목하는 팔은 zone 사건에서 집행이 **구조적으로** 불가능하다(ZoneTruth 에 :robot 이
    # 없다). 그 이름이 메뉴에 있으면 그것만으로 거짓 라벨의 입구다.
    @test !any(m -> m in ("Replace", "SwapBattery"), valid_macros(nothing, ztruth))
    # 빈 메뉴여도 안 된다 — 빈 벡터는 "호출자가 모른다" 는 신호라 서비스가 다시 3팔로 폴백한다.
    @test !isempty(valid_macros(nothing, ztruth))
end

# ---------------------------------------------------------------------------------------------
# (D2) 진짜 음성 대조. (A)·(D) 는 둘 다 **오늘의** 레지스트리에서 기대값을 만들므로, 누가
#      오늘의 이름 그대로 리터럴을 다시 박으면 초록으로 통과한다 — 이 계획이 여섯 번 만난
#      "실패할 수 없는 게이트" 의 모양이다. 그래서 레지스트리를 **실제로 바꿔 끼운**
#      서브프로세스에서 메뉴가 따라오는지 잰다. 최종 브랜치 리뷰가 C2 를 측정한 방법 그대로다.
# ---------------------------------------------------------------------------------------------
"레지스트리를 바꿔 끼운 서브프로세스에서 두 메뉴를 재고 (exitcode, 출력) 을 돌려준다."
function menus_under(registry_path::AbstractString)
    env = copy(ENV)
    for k in ("DEMO_FORCE_MACRO", "DS_DEVIATE_ARM", "DS_DEVIATE_AT")
        delete!(env, k)
    end
    env["ACTION_REGISTRY"] = registry_path
    code = """
    module _M
    using ConstructionBots
    const CB = ConstructionBots
    import HTTP, JSON3
    CB.include(raw"$(joinpath(REPO, "src", "navigator", "navigator.jl"))")
    include(raw"$(joinpath(REPO, "tools", "monitor", "policy.jl"))")
    CB.BATTERY_FLEET[] = CB.BatteryFleet(CB.BatteryParams(), Dict{Any,Float64}(),
                                         Dict{Any,Float64}(), Dict{Any,Int}(), Set{Any}())
    println("ENACTABLE=", join(enactable_macros(), ","))
    println("MENU=", join(valid_macros(nothing, CB.BatteryTruth(CB.RobotID(3), 0.05)), ","))
    end
    """
    out = Pipe()
    p = run(pipeline(setenv(`$(Base.julia_cmd()) --project=$(REPO) -e $code`, env),
                     stdout = out, stderr = out), wait = false)
    close(out.in)
    txt = read(out, String)
    wait(p)
    return (p.exitcode, txt)
end

"출력에서 `KEY=a,b,c` 줄을 뽑아 Vector{String} 으로."
function parse_menu(txt::AbstractString, key::AbstractString)
    for line in split(txt, '\n')
        startswith(line, key * "=") || continue
        body = strip(line[(length(key) + 2):end])
        return isempty(body) ? String[] : String.(split(body, ","))
    end
    return String[]
end

@testset "(D2) 레지스트리를 바꿔 끼우면 valid_macros 도 따라온다 (음성 대조)" begin
    # battery 전용 팔(오늘은 SwapBattery)의 **이름만** 바꾼 레지스트리를 만든다. 이름은
    # 레지스트리에서 읽는다 — 여기에 "SwapBattery" 라고 적으면 이 게이트가 막으려는 결함이
    # 게이트 자신에게서 난다.
    local batt_ids = ActionRegistry.kind_valid("battery")
    local excl = [i for i in batt_ids if length(collect(ActionRegistry.REGISTRY[i].kinds)) == 1]
    @test !isempty(excl)          # 이게 비면 아래 변이가 아무것도 안 바꾼다 = 대조가 무의미
    local old_name = ActionRegistry.NAME[first(excl)]
    local new_name = old_name * "MUT"

    local dir = mktempdir()
    try
        local raw = read(ActionRegistry.PATH, String)
        local mutated = replace(raw, "\"$(old_name)\"" => "\"$(new_name)\"")
        @test mutated != raw      # 치환이 실제로 일어났는가(양성 대조)
        local path = joinpath(dir, "action_registry_mut.json")
        write(path, mutated)

        local code, txt = menus_under(path)
        @test code == 0
        local enact = parse_menu(txt, "ENACTABLE")
        local menu  = parse_menu(txt, "MENU")
        # 리뷰가 실측한 그 자리: 예전에는 enact 만 따라가고 menu 는 안 따라갔다(에러 없이).
        @test new_name in enact
        @test new_name in menu
        @test !(old_name in menu)
        @test menu == enact       # battery kind 가 오늘 활성 팔 전부를 덮는다
    finally
        rm(dir; force = true, recursive = true)
    end
end

end # outer testset

end # module
