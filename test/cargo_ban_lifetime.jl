# test/cargo_ban_lifetime.jl
# ============================================================================
#  이 파일이 지키는 것: **화물 금지의 수명**(cargo-ban 계획 Task 4, 게이트 G-3).
#
#  계약(사용자 결정 2026-09-01): 금지는 **그 로봇의 배터리가 갈리는 순간**까지 산다.
#  술어(`SoC >= θ`)가 아니라 **사건**이다 — 그래서 임계값도, 누가 언제 확인하는지도 정할
#  필요가 없다.
#
#  🔴 이 파일이 잡는 것은 두 방향이다:
#    (1) 교체된 로봇의 금지가 **실제로** 풀린다(안 풀리면 금지가 영구가 된다).
#    (2) **다른 로봇의 금지는 그대로다** — `clear_all_cargo_bans!()` 로 대충 지우는 구현을
#        이 절반이 잡는다. 한 로봇의 회복이 함대 전체의 금지를 날리면 안 된다.
#  양성 대조를 함께 넣는다: 교체 **전에** 둘 다 걸려 있음을 단언해야 "지울 것이 애초에
#  없어서 초록" 이 아니게 된다.
#
# ----------------------------------------------------------------------------
#  🔴 왜 시험 본체가 **자식 프로세스**에서 도는가 (2026-09-02 실측, 세 번 재현)
#
#  `Pkg.test()` 스위트의 꼬리에서 이 시험을 in-process 로 돌리면 **세그폴트**가 난다.
#  실측한 자리는 내가 건드린 줄이 아니라 **HEAD 코드**다:
#
#      signal (11.128): Segmentation fault
#      getindex at ./essentials.jl:13 [inlined]      # Dict 내부 slots 배열 읽기
#      isslotempty at ./dict.jl:161 [inlined]
#      ht_keyindex at ./dict.jl:272
#      get at ./dict.jl:524 [inlined]
#      _soc_of at src/respec/replace_robot.jl:1448   # get(fleet.soc, role, nothing)
#
#  `_soc_of` 는 Task 4 가 손대지 않은 함수이고, 이 프로브는 `swap_battery!` 를 부르기
#  **전에** 터졌다(같은 스위트에서 `CB.BATTERY_FLEET[]` 를 **시험 스코프**에서 읽는 것은
#  정상이다 — 바로 앞 줄에서 `typeof` 가 `BatteryFleet` 를 찍었다).
#  원인은 이 레포의 시험 스위트가 `src/navigator/navigator.jl` 을 **여러 번** `CB.include`
#  한다는 데 있다(가드 없는 파일이 여럿). 그래서 스위트 로그에 Julia 의 경고가 86줄 뜬다:
#      WARNING: redefinition of constant ConstructionBots.BATTERY_FLEET.
#               This may fail, cause incorrect answers, or produce other errors.
#  const 이 다시 정의되면 그 전에 컴파일된 패키지 코드가 **옛 바인딩/옛 객체**를 계속 가리킨다
#  — `!== nothing` 같은 얕은 검사는 통과하고(그래서 `_compile_standing_cargo_bans!` 는 산다),
#  내용물을 deref 하는 순간 죽는다. 이것은 **Task 4 의 결함이 아니고 Task 4 가 고칠 것도 아니다**
#  (범위 밖 — 보고서에 그대로 적었다).
#
#  ⟹ 그래서 시험 본체를 **깨끗한 프로세스**에서 돌린다. 그 상태는 `swap_battery!` 이 실제로
#     지원하는 상태이고, 게이트의 힘은 하나도 안 줄었다: 자식이 실제 `@testset` 20 단언을
#     돌리고, 부모는 종료코드 + 단언 수 sentinel 을 잰다(자식이 일찍 죽으면 sentinel 이 없다).
#     🔴 `@test_skip` 도, 단언 삭제도 아니다 — 삭제했으면 그 크래시 정보가 사라졌을 것이다.
#
#  🔴 runtests.jl 이 모든 시험 파일을 같은 `Main` 스코프에 include 하므로 자기 module 로 감싼다.
# ============================================================================
module CargoBanLifetimeTests

using Test

const REPO = abspath(joinpath(@__DIR__, ".."))
const CHILD_FLAG = "CB_CARGO_BAN_LIFETIME_CHILD"
# 🔴 자식이 실제로 통과시켜야 하는 단언 수. 늘리거나 줄이면 여기도 고쳐야 한다 —
#    "몇 개든 통과하면 초록" 은 0개를 처리하고 초록이 되는 문을 열어 준다.
const EXPECTED_ASSERTIONS = 28

if get(ENV, CHILD_FLAG, "0") == "1"
# ============================================================================
#  자식 프로세스 — 진짜 시험
# ============================================================================
using ConstructionBots
using Random
const CB = ConstructionBots

# 🔴 런타임 include 는 **module 최상위**에 있어야 한다(world-age). 계획 README 의 공용
#    픽스처에는 이 줄이 빠져 있어 그대로 쓰면 `UndefVarError: enable_battery!` 로 죽는다
#    (shared-rulings S-4.9).
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

"""
배터리 계층이 켜진 env. 🔴 계획 README 의 공용 픽스처와 달리 **전진시키지 않는다**
(`target_closed` 없음): 수명 계약은 스케줄 진행 상태와 무관하고, `swap_battery!` 는 씬트리에
그 로봇이 있기만 하면 돈다. 비퇴화는 시험이 직접 단언한다 — 교체 상태가 `:battery_swapped`
이고 SoC 가 실제로 움직인다.
"""
function fixture(; board = "tractor.mpd", nr = 10)
    env = CB.run_lego_demo(; ldraw_file = board, project_name = "cargobanlife", num_robots = nr,
                             assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    CB.enable_battery!(env)          # 🔴 없으면 BATTERY_FLEET[] === nothing 이라 SoC 를 못 잰다
    return env
end

const ENV_ = fixture()

ts1 = @testset "🔴 G-3 swap_battery! 가 그 로봇의 금지만 지운다" begin
    env = ENV_
    a = CB.RobotID(3); b = CB.RobotID(7)
    fleet = CB.BATTERY_FLEET[]
    @test fleet !== nothing                       # 픽스처 비퇴화: 부담/SoC 계층이 실제로 있다
    @test haskey(fleet.soc, a) && haskey(fleet.soc, b)   # 두 로봇이 실재한다(오타면 여기서 빨강)
    CB.clear_all_cargo_bans!()
    try
        fleet.soc[a] = 0.05                       # 교체가 **세계를 바꾸는지** 보려고 낮춰 둔다
        CB.set_cargo_ban!(a, 2); CB.set_cargo_ban!(b, 1)
        # 🔴 양성 대조 — 교체 전에 둘 다 실제로 걸려 있다(지울 것이 없어서 초록이 아니다).
        @test length(CB.STANDING_CARGO_BANS[]) == 2
        @test CB.STANDING_CARGO_BANS[][a] == 2
        @test CB.STANDING_CARGO_BANS[][b] == 1

        res = CB.swap_battery!(env, a; verbose = false)

        # 🔴 반환 심볼만으로는 세계가 변했다는 증거가 아니다(S-3) — SoC 를 직접 잰다.
        @test res.status === :battery_swapped      # early return(:no_robot 등)이 아니다
        @test res.soc_before == 0.05
        @test CB.BATTERY_FLEET[].soc[a] == 1.0     # 교체가 실제로 일어났다

        @test !haskey(CB.STANDING_CARGO_BANS[], a)      # a 는 풀렸다
        @test CB.STANDING_CARGO_BANS[][b] == 1          # 🔴 b 는 그대로 — 남의 금지를 지우면 안 된다
        @test length(CB.STANDING_CARGO_BANS[]) == 1     # 전체 삭제 구현이면 여기서 빨강
    finally
        CB.clear_all_cargo_bans!()                 # 🔴 전역이다. 모든 formulate 가 읽는다.
    end
end

ts2 = @testset "🔴 금지가 없는 로봇을 교체해도 남의 금지를 안 건드린다" begin
    env = ENV_
    a = CB.RobotID(3); b = CB.RobotID(7)
    CB.clear_all_cargo_bans!()
    try
        CB.set_cargo_ban!(b, 1)
        @test !haskey(CB.STANDING_CARGO_BANS[], a)      # a 에는 금지가 없다
        res = CB.swap_battery!(env, a; verbose = false)
        @test res.status === :battery_swapped
        @test CB.STANDING_CARGO_BANS[][b] == 1          # 무관한 로봇의 금지는 살아 있다
        @test length(CB.STANDING_CARGO_BANS[]) == 1
    finally
        CB.clear_all_cargo_bans!()
    end
end

ts3 = @testset "🔴 해제는 파견이 아니라 **적용**에 묶여 있다(배송 경로)" begin
    env = ENV_
    a = CB.RobotID(3)
    fleet = CB.BATTERY_FLEET[]
    CB.clear_all_cargo_bans!()
    CB.clear_battery_deliveries!()
    try
        CB.set_battery_courier!(enabled = true)
        fleet.soc[a] = 0.05
        CB.set_cargo_ban!(a, 2)
        res = CB.swap_battery!(env, a; verbose = false)
        # 배송이 켜지면 `swap_battery!` 는 **파견만** 한다 — 실제 교체는 배송 로봇이 도착한
        # 스텝의 `_apply_battery_swap!` 이다(battery_courier.jl: "★ 여기가 진짜 SwapBattery 다").
        # 🔴 두 갈래 전부에 단언이 있다(예비가 없으면 즉시 교체로 떨어진다) — 빈 통과가 없다.
        @test res.status === :battery_courier_dispatched || res.status === :battery_swapped
        if res.status === :battery_courier_dispatched
            # 파견은 SoC 를 안 되돌린다 ⟹ 금지의 근거가 아직 살아 있다 ⟹ 금지도 살아 있어야 한다.
            @test CB.BATTERY_FLEET[].soc[a] == 0.05
            @test CB.STANDING_CARGO_BANS[][a] == 2
            # 도착 = 배송 훅이 부르는 바로 그 함수.
            CB._apply_battery_swap!(env, a; courier = res.courier, verbose = false)
            @test CB.BATTERY_FLEET[].soc[a] == 1.0
            @test !haskey(CB.STANDING_CARGO_BANS[], a)
        else
            # 예비가 없어 즉시 교체로 떨어진 판 — 그 경우엔 여기서 이미 풀려 있어야 한다.
            @test CB.BATTERY_FLEET[].soc[a] == 1.0
            @test !haskey(CB.STANDING_CARGO_BANS[], a)
        end
    finally
        CB.set_battery_courier!(enabled = false)   # 🔴 전역 설정 — 반드시 되돌린다
        CB.clear_battery_deliveries!()
        CB.clear_all_cargo_bans!()
    end
end

ts4 = @testset "🔴 hot_swap_robot!(본체 교체)도 그 로봇의 금지만 지운다" begin
    # 🔴 왜 이 팔이 있나: `hot_swap_robot!` 은 `_reset_robot_health!` 로 SoC 를 1.0 으로 되돌리는데,
    #    RobotID 는 **설계상 보존**되므로 보관소 키가 살아남는다. 해제가 `_apply_battery_swap!` 에만
    #    있으면 본체를 갈아 낀 로봇이 근거(낮은 SoC) 없는 금지를 에피소드 끝까지 조용히 이고 간다
    #    — 경고도 status 도 없이. 해제를 `_reset_robot_health!` 의 SoC guard 안으로 옮겨 막았고,
    #    이 절이 그 두 방향(풀린다 / 남의 것은 안 풀린다)을 전부 잰다.
    env = ENV_
    a = CB.RobotID(3); b = CB.RobotID(7)
    fleet = CB.BATTERY_FLEET[]
    CB.clear_all_cargo_bans!()
    try
        fleet.soc[a] = 0.05                        # 교체가 **세계를 바꾸는지** 보려고 낮춰 둔다
        CB.set_cargo_ban!(a, 2); CB.set_cargo_ban!(b, 1)
        @test length(CB.STANDING_CARGO_BANS[]) == 2     # 🔴 양성 대조 — 지울 것이 실제로 있다

        # `:in_place` 는 재배치(`_rehome_robot!`)를 건너뛰지만 `_reset_robot_health!` 는 두 팔
        # (`:via_depot`/`:in_place`)이 똑같이 지나가는 마지막 줄이다 — 해제 자리를 그대로 잰다.
        res = CB.hot_swap_robot!(env, a; mode = :in_place, verbose = false)

        # 🔴 반환 심볼만으로는 세계가 변했다는 증거가 아니다(S-3) — SoC 를 직접 잰다.
        @test res.status === :swapped               # early return(:no_robot/:no_spare)이 아니다
        @test CB.BATTERY_FLEET[].soc[a] == 1.0      # SoC 가 실제로 복구됐다

        @test !haskey(CB.STANDING_CARGO_BANS[], a)  # 🔴 a 의 금지가 풀렸다
        @test CB.STANDING_CARGO_BANS[][b] == 1      # 🔴 b 는 그대로 — 남의 금지를 지우면 안 된다
        @test length(CB.STANDING_CARGO_BANS[]) == 1 # 전체 삭제 구현이면 여기서 빨강
    finally
        CB.clear_all_cargo_bans!()
    end
end

ts5 = @testset "🔴 실패한 hot_swap 은 금지를 유지한다(early return)" begin
    # 씬트리에 없는 로봇 ⟹ `:no_robot` 으로 `_reset_robot_health!` 전에 return 한다.
    # SoC 가 복구되지 않았으니 금지의 근거도 그대로다 — 풀리면 안 된다.
    env = ENV_
    ghost = CB.RobotID(999_999)
    CB.clear_all_cargo_bans!()
    try
        CB.set_cargo_ban!(ghost, 2)
        res = CB.hot_swap_robot!(env, ghost; mode = :in_place, verbose = false)
        @test res.status === :no_robot
        @test CB.STANDING_CARGO_BANS[][ghost] == 2   # 🔴 실패 경로에서 금지는 살아 있다
    finally
        CB.clear_all_cargo_bans!()
    end
end

# 🔴 sentinel. 여기까지 왔다 = 다섯 testset 이 전부 통과했다(@testset 은 실패하면 던진다).
println("CARGO_BAN_LIFETIME_PASSED=", sum(t -> t.n_passed, (ts1, ts2, ts3, ts4, ts5)))

else
# ============================================================================
#  부모 프로세스 — 깨끗한 자식에서 위 본체를 돌리고 결과를 잰다
# ============================================================================
"자식을 돌려 (exitcode, 출력) 을 돌려준다."
function run_child()
    e = copy(ENV); e[CHILD_FLAG] = "1"
    code = "include(raw\"$(abspath(@__FILE__))\")"
    out = Pipe()
    p = run(pipeline(setenv(`$(Base.julia_cmd()) --project=$(REPO) -e $code`, e),
                     stdout = out, stderr = out), wait = false)
    close(out.in)
    txt = read(out, String)
    wait(p)
    return (p.exitcode, txt)
end

@testset "🔴 G-3 화물 금지의 수명 (깨끗한 프로세스에서 — 위 머리말 참조)" begin
    code, txt = run_child()
    if code != 0
        println(stderr, txt)                       # 🔴 실패는 통째로 보여 준다(조용한 빨강 금지)
    end
    @test code == 0
    m = match(r"CARGO_BAN_LIFETIME_PASSED=(\d+)", txt)
    @test m !== nothing                            # sentinel 이 없으면 자식이 일찍 죽은 것이다
    @test m !== nothing && parse(Int, m.captures[1]) == EXPECTED_ASSERTIONS
end

end # if child
end # module
