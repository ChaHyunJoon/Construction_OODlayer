module WorldInterfaceClosure
using Test
using ConstructionBots
import JSON3
const CB = ConstructionBots
const ART = normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "core",
                              "world_interface.json"))

@testset "(1) 폐포가 run 3 이 지어낸 타입들에 실제로 도달한다" begin
    j = JSON3.read(read(ART, String))
    names_in = Set(String[String(t.name) for t in j.types])
    # 🔴 run 3 은 `node.assigned_robot` 을 지어냈다. ScheduleNode 의 실제 필드는 (id, node, spec).
    @test "ScheduleNode" in names_in
    # 🔴 run 3 은 `robot.charge` 를 지어냈다. 값 타입은 VelocityController 이고 그런 필드가 없다.
    @test "VelocityController" in names_in
    @test "PathSpec" in names_in
    @test "AbstractID" in names_in
end

@testset "(2) 추상 타입은 필드가 아니라 subtypes 를 싣는다" begin
    # 🔴 `fieldnames(SceneTreeEdge)` 는 ArgumentError 를 **던진다**(실측).
    #    순진한 전이 전개는 생성기를 죽인다.
    j = JSON3.read(read(ART, String))
    e = only(filter(x -> x.name == "SceneTreeEdge", collect(j.types)))
    @test haskey(e, :subtypes) && !haskey(e, :fields)
    @test Set(String.(collect(e.subtypes))) == Set(["PermanentEdge", "TemporaryEdge"])
    # 빈-통과 방지: 구상 타입은 반대여야 한다
    s = only(filter(x -> x.name == "ScheduleNode", collect(j.types)))
    @test haskey(s, :fields) && !haskey(s, :subtypes)
    @test Set(String[String(f.name) for f in s.fields]) == Set(["id", "node", "spec"])
end

@testset "(3) 🔴 서드파티 타입은 절대 안 들어온다 — 폐포가 폭발한다" begin
    # 실측: 필터를 풀면 깊이 2 에서 1,302 타입, 깊이 3 에서 25,160 타입.
    j = JSON3.read(read(ART, String))
    ns = Set(String[String(t.name) for t in j.types])
    for gone in ("Dict", "Set", "SimpleDiGraph", "PriorityQueue", "Ball2")
        @test !(gone in ns)
    end
    @test 40 <= length(ns) <= 120   # 상한: 폭발 트립와이어. 실측 68(66 → Task 1 의 VelocityController → S4 의 InvariantSpec).
end

@testset "(4) 폐포는 이름으로 정렬돼 결정적이다" begin
    # 🔴 `subtypes` 의 반환 순서는 계약이 아니다. 정렬이 없으면 게이트 (2) 의 바이트
    #    비교가 실행마다 이유 없이 흔들린다 (`method_entries` 의 MergeSort 와 같은 논거).
    j = JSON3.read(read(ART, String))
    ns = String[String(t.name) for t in j.types]
    @test ns == sort(ns)
end

@testset "(5) 도달 경로 색인이 run 3 이 필요로 한 타입들을 짚는다" begin
    j = JSON3.read(read(ART, String))
    @test haskey(j, :access)
    acc = Dict(String(k) => String[String(x) for x in v] for (k, v) in pairs(j.access))
    @test any(p -> occursin("env.sched.nodes", p), acc["ScheduleNode"])
    @test any(p -> occursin("env.agent_policies", p), acc["VelocityController"])
    # 🔴 색인의 계약: **키가 있으면 경로가 있다.** 도달 못 하는 타입은 키 자체가 없다
    #    (`add!` 는 push 와 함께만 키를 만든다) — 빈 목록으로 실리면 렌더가 "경로가 있다"
    #    고 읽고 `missing` 주석을 안 붙인다. 이전 판의 `v isa Vector` 단언은 바로 윗줄의
    #    `String[...]` 내포가 값을 이미 Vector 로 짓기 때문에 **항진**이었다(리뷰 M1).
    @test all(!isempty, values(acc))
end

@testset "(6) 🔴 호출 가능성 분할 — PlannerEnv 메서드 23 중 23, 그중 세계 변경자 16" begin
    # ⚠️ 표제의 수는 전부 **오늘 잰 값**이다. 이전 판 표제의 "오늘 5 에서" 의 5 는 계획서·
    #    설계 어디에서도 재유도되지 않아 지웠다(리뷰 M3).
    j = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    @test all(m -> haskey(m, :callable), ms)
    envms = [m for m in ms if occursin("PlannerEnv", String(m.signature))]
    @test length(envms) == 23                      # 실측
    ok = [m for m in envms if m.callable === true]
    @test length(ok) == 23                         # D9 의 씨앗 확장이 전부 연다
    bang = [m for m in ok if endswith(String(m.name), "!")]
    @test length(bang) == 16
    @test "apply_cmd!" in Set(String[String(m.name) for m in bang])
    @test "close_node!" in Set(String[String(m.name) for m in bang])
    # 🔴 I2: `Vararg{Any}` 는 `isa DataType` 가 false 라 `_arg_obtainable` 이 통째로
    #    떨어뜨렸다 — 그래서 **경로가 이미 있는** 기하 변경자가 "못 부른다" 쪽에 실렸다.
    #    이 다섯이 유일하게 Vararg 하나로만 막혀 있던 것들이다(실측).
    for (nm, sig) in (
            ("set_desired_global_transform!", "(g::ConstructionBots.GeomNode, args::Vararg{Any})"),
            ("set_desired_global_transform!", "(n::ConstructionBots.SceneNode, args::Vararg{Any})"),
            ("set_desired_global_transform!", "(n::ConstructionBots.TransformNode, t, args::Vararg{Any})"),
            ("set_desired_global_transform_without_affecting_children!",
             "(n::ConstructionBots.TransformNode, t, args::Vararg{Any})"),
            ("is_within_capture_distance",
             "(parent::ConstructionBots.SceneNode, child::ConstructionBots.SceneNode, args::Vararg{Any})"))
        m = only(filter(x -> String(x.name) == nm && String(x.signature) == sig, ms))
        @test m.callable === true
    end
    # 🔴 재유도해서 적을 것 — 이 숫자는 export 를 더할 때마다 낡는다(testset (34) 의 짝이
    #    실제로 낡은 채 커밋돼 HEAD 를 빨갛게 했다). 실측 2026-09-05 (나-1) = **195**.
    #    직전 이력: Vararg 고침 전 181 · S4 의 `InvariantSpec` 씨앗 전 186 ·
    #    S3 의 `ood_event_target()` 전 187 · S5 의 `forbid_heavy_cargo!` 전 188 ·
    #    (나-1) 의 좌표 접근자 전 **189**.
    # 🔴 189 → 195 의 내역(실측, 전수): `global_transform` 3 · `project_to_2d` 2 ·
    #    `get_center` 1 = **6**. 이 트립와이어는 **의도대로 울렸다** — (나-1) 이 광고
    #    표면을 넓혔고, 그 넓힘이 이 줄 하나로 기록에 남는다.
    #    ⚠️ `get_center` 의 셋 중 `Ball2` 판 하나만 열린다: 나머지 둘(`Hyperrectangle` ·
    #    `HyperSphere`)은 `_OBTAINABLE_FOREIGN` 에 없다 — 세계가 그 둘을 손에 쥐여 주는
    #    광고된 접근자가 없기 때문이고, 그래서 `callable=false` 가 그 둘에 대해서는 **참**이다.
    @test count(m -> m.callable === true, ms) == 195
    # 🔴 그 넓힘의 내역을 숫자로만 두지 않는다 — 어느 이름이 몇 개 열렸는지를 직접 잰다.
    #    숫자만 고치는 습관이 들면 다음 번에 **다른 것이 열려도** 이 줄은 초록으로 남는다.
    local opened = Dict(nm => count(m -> String(m.name) == nm && m.callable === true, ms)
                        for nm in ("global_transform", "project_to_2d", "get_center"))
    @test opened == Dict("global_transform" => 3, "project_to_2d" => 2, "get_center" => 1)
end
@testset "(7) 🔴 R11·R33 + 설계 §6.2: 경로는 접지 않고, 없는 것은 `missing` 으로 이름을 댄다" begin
    j = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    @test all(m -> haskey(m, :missing), ms)

    # 🔴 R11 → R33. 이전 판은 인자당 `first(ps)` **하나**만 실었다 — `AbstractID` 의 9개
    #    경로 중 사전순 첫째 하나. R11 이 그것을 넷으로 올렸고, 판정 R33 이 **상한을 아예
    #    안 물리게** 했다(어느 경로가 더 정밀한지는 선언에서 유도할 수 없다 — 아홉 경로의
    #    선언된 산출 타입이 9/9 동일하다는 실측). 이제 인자 하나가 아홉을 다 본다.
    ag = only(filter(m -> String(m.name) == "asset_generation", ms))
    @test length(ag.argpaths) == 9                       # 인자 하나 × 경로 아홉 (안 자른다)
    @test any(p -> occursin("env.sched.vtx_ids", String(p)), ag.argpaths)
    rr = only(filter(m -> String(m.name) == "replace_robot!", ms))
    @test length(rr.argpaths) == 18                      # AbstractID 인자 둘 × 9

    # 🔴 설계 §6.2. 둘째 표제의 **모든** 항목은 무엇이 없는지를 말해야 한다.
    later = [m for m in ms if m.callable !== true]
    @test !isempty(later)
    @test all(m -> !isempty(m.missing), later)

    # 🔴 I1. 첫째 표제도 거짓말을 했다 — `callable=true` 인데 경로가 없는 인자를 가진 항목
    #    32건이 "every argument is obtainable" 아래 앉아 있었다. 같은 `missing` 채널로 갚는다.
    ap = only(filter(m -> String(m.name) == "apply_cmd!" &&
                          occursin("DepositCargo", String(m.signature)), ms))
    @test ap.callable === true
    @test Set(String.(collect(ap.missing))) == Set(["DepositCargo", "Twist"])
    # 🔴 실측 2026-09-05 (나-1) = **36**. 직전 이력: S4 전 32 · (나-1) 전 33.
    #    33 → 36 의 내역(전수): `get_center(::Ball2)` missing=[Ball2] ·
    #    `global_transform(::TransformNode)` missing=[TransformNode] ·
    #    `global_transform(::GeomNode, args...)` missing=[GeomNode] = **셋**.
    #    이 셋에 `missing` 이 남는 것은 **설계다**(S4 의 `missing: InvariantSpec` 과 같다):
    #    그 타입들은 env 의 필드가 아니라 다른 광고된 함수가 만들어 준다
    #    (`Ball2` ← `restriction_zones()` · `TransformNode` ← `goal_config`). 그 이음매를
    #    모델이 스스로 잇는지가 실험이므로 메우지 않는다.
    @test count(m -> m.callable === true && !isempty(m.missing), ms) == 36
    # 🔴 숫자만 고치지 않는다 — 어느 셋이 늘었는지를 직접 잰다(위 (6) 과 같은 규율).
    local added = Set(String[String(m.name) * "|" * join(String.(collect(m.missing)), ",")
                             for m in ms if m.callable === true && !isempty(m.missing) &&
                                 String(m.name) in ("get_center", "global_transform")])
    @test added == Set(["get_center|Ball2", "global_transform|TransformNode",
                        "global_transform|GeomNode"])
    # 빈-통과 방지: 경로가 다 있는 항목은 missing 이 비어야 한다
    cn = only(filter(m -> String(m.name) == "close_node!" &&
                          occursin("ScheduleNode", String(m.signature)), ms))
    @test isempty(cn.missing) && !isempty(cn.argpaths)
end
@testset "(8) 🔴 R33: 인자당 경로는 **자르지 않는다** — 정당화할 수 없는 순위를 프롬프트가 암시하지 않는다" begin
    # ── 이 testset 이 지키는 것과 지키지 **않는** 것 (리뷰 I3 를 정직하게 갚는다) ──────────
    #
    #  지킨다 (전부 산출물만 읽어서 판정된다):
    #    (a) `access` 색인이 아홉을 다 들고 있다,
    #    (b) 🔴 **어떤 인자의 경로 목록도 잘리지 않는다** — 렌더에 실린 경로 집합이 색인의
    #        경로 집합과 **같다**. `_MAX_PATHS` 는 이제 무음 절단기가 아니라 **트립와이어**다:
    #        상한이 물면 이 단언이 빨개진다(조용히 사전순으로 넷을 고르는 대신),
    #    (c) 목록이 **사전순**이다 — 즉 위치가 순위를 뜻하지 않는다,
    #    (d) 설계 §6.2 가 이름 댄 두 경로와 `restage_assembly!` 의 전제조건 집합이 실제로 실린다.
    #
    #  🔴 지키지 **못한다**: "1위가 실제로 로봇 id 를 준다" 같은 **실행시각 조성**은 이 파일이
    #     `env` 를 안 만들므로 잴 수 없다. 그것은 정적 성질이 아니다 — wave-b-review 가 살아
    #     있는 `PlannerEnv` 에서 한 번 쟀고(`keys(env.agent_policies)` = {BotID 18,
    #     TemplatedID{TransportUnitNode} 27}), 그 조성은 보드·함대 크기에 따라 움직인다.
    #     예전 판의 주석은 "기전이 아니라 성질을 고정한다" 고 적어 놓고 문자열 하나
    #     (`first(ids) == "keys(env.agent_policies)"`)를 단언했다 — 그 문장이 거짓이었다.
    #
    # ── 왜 더 나은 순위가 아니라 **컷 제거**인가 (판정 R33) ──────────────────────────────
    #  R21 은 "정밀한 출처를 남기라" 였고 wave B 는 그것을 `Dict` 의 **선언된 값 타입**으로
    #  구현했다(CB 소유면 "키가 역할을 이름한다"). 그 규칙은 오늘 데이터에서 **반상관**이다:
    #  `agent_policies`(값=`VelocityController`, 1등급) 키는 40% 만 로봇이고,
    #  `staging_circles`(값=`Ball2`, 최하등급) 키는 **8/8 이 `AssemblyID`** 다.
    #  그리고 정적으로는 가를 수가 없다 — 실측: `AbstractID` 를 내는 아홉 경로의 **선언된
    #  산출 타입은 9/9 가 `ConstructionBots.AbstractID` 하나**다(distinct = 1). 선언에는
    #  정밀도 정보가 0비트 들어 있다. 그래서 순위를 매기는 대신 **아무것도 안 자른다.**
    j = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    acc = Dict(String(k) => String[String(x) for x in v] for (k, v) in pairs(j.access))
    ids = acc["AbstractID"]

    # (a) 색인은 아홉을 다 들고 있다.
    @test length(ids) == 9
    # (c) 사전순이다 — 위치가 순위가 아니다. (옛 판의 `ids != sort(ids)` 는 정확히 반대를
    #     요구했고, 그것은 "정밀도순" 이라는 정당화 못 하는 주장의 대리였다.)
    @test ids == sort(ids)

    # (b) 🔴 어떤 메서드의 어떤 인자도 잘리지 않는다. `argpaths` 는 `"<인자이름> <- <경로>"`
    #     줄이므로 인자 이름으로 묶으면 한 묶음이 곧 한 인자의 경로 집합이다. 그 집합은
    #     반드시 **어떤 타입의 색인 전체**와 같아야 한다 — 부분집합이면 상한이 문 것이다.
    full = Set(Set(v) for v in values(acc))
    ntrunc = 0
    for m in ms
        isempty(m.argpaths) && continue
        byarg = Dict{String,Set{String}}()
        for line in m.argpaths
            s = String(line); i = findfirst(" <- ", s)
            nm = s[1:first(i)-1]; pt = s[last(i)+1:end]
            push!(get!(byarg, nm, Set{String}()), pt)
        end
        for (_, ps) in byarg
            ps in full || (ntrunc += 1)
        end
    end
    @test ntrunc == 0
    # 빈-통과 방지: 위 루프가 실제로 무언가를 봤다.
    @test count(m -> !isempty(m.argpaths), ms) > 0

    # (d) `AbstractID` 인자는 아홉을 다 본다 — 예전엔 넷이었다.
    sb = only(filter(x -> String(x.name) == "swap_battery!", ms))
    @test length(sb.argpaths) == 9
    _rhs(line) = (s = String(line); i = findfirst(" <- ", s); s[last(i)+1:end])
    sbp = Set(String[_rhs(p) for p in sb.argpaths])
    @test sbp == Set(ids)
    # 🔴 설계 §6.2 가 `swap_battery!` 의 예시로 직접 이름 댄 두 경로가 **둘 다** 있다
    #    (리뷰 I4: 상한이 4 였을 때 `env.sched.vtx_ids[i]` 는 마지막 칸에 겨우 걸려 있었다).
    @test "env.sched.vtx_ids[i]" in sbp
    @test "keys(env.agent_policies)" in sbp
    # 🔴 리뷰 I1 회귀: `keys(env.staging_circles)` 는 `restage_assembly!` 의 **전제조건 집합**
    #    이다(`haskey(env.staging_circles, assembly_id) || return (status = :no_staging, …)`,
    #    src/respec/restage_zone.jl). 등급 규칙은 그것을 컷 아래로 보냈다 — 값 타입이
    #    서드파티(`LazySets.Ball2`)라서. 실측하면 그 키집합은 8/8 이 `AssemblyID` 다.
    for nm in ("restage_assembly!", "find_clear_staging_center")
        m = only(filter(x -> String(x.name) == nm, ms))
        @test any(p -> occursin("keys(env.staging_circles)", String(p)), m.argpaths)
    end
    # 로봇 id 를 요구하는 메서드들도 그 출처를 여전히 본다.
    for nm in ("swap_battery!", "hot_swap_robot!", "dispatch_battery_courier!")
        m = only(filter(x -> String(x.name) == nm, ms))
        @test any(p -> occursin("keys(env.agent_policies)", String(p)), m.argpaths)
    end
    # 빈-통과 방지: 옛 판이 "잘려 나갔다" 의 증거로 쓰던 `vtx_map` 둘이 이제 **실린다**.
    #    (옛 단언 `!any(occursin("vtx_map", …))` 은 등급을 어떻게 뒤집어도 참이라 사실상
    #     항진이었다 — 리뷰 m-3.)
    @test count(p -> occursin("vtx_map", String(p)), sb.argpaths) == 2
end

# 🔴 S4 (2026-09-04). `export` 한 줄만으로는 재배정 동사가 **호출 불가**로 렌더된다 — 씨앗
#    프록시가 시그니처의 `PlannerEnv` **주석**을 보는데 respec 층은 `env` 를 무타입으로
#    받기 때문이다(실측: export 만 한 산출물에서 `callable == false`, 렌더 제목은
#    `FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET`). `_CURATED_SEEDS` 가 그것을
#    고치고, 이 testset 이 그 고침과 **넓히지 않았다**는 사실을 함께 잰다.
@testset "(9) 🔴 S4: 재배정 동사가 실제로 호출 가능하게 렌더된다" begin
    j = JSON3.read(read(ART, String))
    ns = Set(String[String(t.name) for t in j.types])
    ms = collect(j.methods)
    @test "InvariantSpec" in ns
    rel = only(filter(m -> String(m.name) == "release_pending_assignments!", ms))
    # 🔴 이것이 이 태스크의 성패다. `false` 면 모델이 "지금은 못 부른다" 로 읽고 광고가 무동작이다.
    @test rel.callable === true
    # 설계상 `argpaths` 는 비어 있다 — `InvariantSpec` 은 `env` 의 필드가 아니라
    # `build_invariant(env)` 가 만든다. 그 이음매를 모델이 스스로 잇는지가 실험이다.
    @test isempty(rel.argpaths)
    @test Set(String.(collect(rel.missing))) == Set(["InvariantSpec"])
    # `build_invariant` 가 같은 산출물에 호출 가능하게 실려 있어야 그 이음매가 성립한다.
    bi = only(filter(m -> String(m.name) == "build_invariant", ms))
    @test bi.callable === true
    # 🔴 음성 대조 — 프록시를 넓히지 **않았다**. 넓혔다면 respec DSL 문법 열다섯이 들어와
    #    모델이 보는 표면이 통째로 달라진다(실측: 67 → 82).
    for gone in ("RespecProposal", "ConstraintSpec", "LinearConstraint", "Disjunction",
                 "VarRef", "ForbidZone", "ForbidAgent", "SwapBattery")
        @test !(gone in ns)
    end
end

# 🔴 (나-1) (2026-09-05). 좌표를 꺼내는 길을 광고한다 — 유료 런 19·20 이 여기서 죽었다.
#    run19 1차 `Vector{Float64}(::TransformNode)` · run19 2차 `get_center(::Pair{Symbol,Ball2})`
#    · run20 2차 `Vector{Float64}(::AffineMap)`. 셋 다 **defined 인데 export 가 없어서**
#    `names(CB)` 를 도는 생성기에 안 보였고, 모델은 없는 생성자를 지어냈다.
#    레포 자신의 관용구는 `global_transform(goal_config(n)).translation` ·
#    `project_to_2d(t.translation)` · `get_center(ball)` 다.
@testset "(9b) 🔴 (나-1): 좌표 접근자가 실제로 호출 가능하게 렌더된다" begin
    j = JSON3.read(read(ART, String))
    ns = Set(String[String(t.name) for t in j.types])
    ms = collect(j.methods)

    # ---- 셋 다 산출물에 있고, 부를 수 있는 메서드가 하나 이상 있다 ----------------------
    for nm in ("global_transform", "project_to_2d", "get_center")
        got = filter(m -> String(m.name) == nm, ms)
        @test !isempty(got)                       # export 가 먹었다
        # 🔴 이것이 이 태스크의 성패다. `false` 뿐이면 렌더가 전부
        #    `FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET` 아래로 보내고,
        #    그 자리는 모델이 "지금은 못 부른다" 로 읽는다 = S4 와 같은 무동작.
        @test any(m -> m.callable === true, got)
    end

    # ---- run19 가 정확히 부르려던 그 메서드 --------------------------------------------
    gc = only(filter(m -> String(m.name) == "get_center" &&
                          occursin("Ball2", String(m.signature)), ms))
    @test gc.callable === true
    # 설계상 `missing` 은 남는다(S4 의 `InvariantSpec` 과 같다) — `Ball2` 는 env 의 필드가
    # 아니라 `restriction_zones()` 가 준다. 그 이음매를 모델이 스스로 잇는지가 실험이다.
    @test Set(String.(collect(gc.missing))) == Set(["Ball2"])
    # 그 이음매가 성립하려면 공급자가 같은 산출물에 호출 가능해야 한다.
    rz = only(filter(m -> String(m.name) == "restriction_zones", ms))
    @test rz.callable === true

    # ---- TransformNode → 변환 -----------------------------------------------------------
    # 🔴 부분 문자열로 물리면 둘이 잡힌다 — `(tree::…, n::ConstructionBots.TransformNode)`
    #    도 같은 조각을 담는다(실측: `only` 가 ArgumentError 로 죽었다). 정확히 문다.
    gt = only(filter(m -> String(m.name) == "global_transform" &&
                          String(m.signature) == "(n::ConstructionBots.TransformNode)", ms))
    @test gt.callable === true
    # 공급자: `goal_config` 가 TransformNode 를 돌려준다.
    @test any(m -> String(m.name) == "goal_config", ms)

    # ---- 🔴 음성 대조: 타입 폐포를 **안 넓혔다** ----------------------------------------
    #    `_OBTAINABLE_FOREIGN` 은 `_arg_obtainable` **한 술어**만 고친다. 폐포를 넓혔다면
    #    `WORLD TYPES` 절에 LazySets/GeometryBasics 내부가 통째로 들어와 모델이 보는 표면이
    #    이 레인이 재려는 것과 달라진다(S4 가 프록시 넓히기를 재고 버린 것과 같은 근거).
    @test !("Ball2" in ns)
    @test !("Hyperrectangle" in ns)
    @test !("HyperSphere" in ns)
    @test !("AffineMap" in ns)
    # S4 의 음성 대조도 그대로 살아 있다 — respec 문법은 여전히 폐포 밖이다.
    for gone in ("RespecProposal", "ConstraintSpec", "LinearConstraint", "SwapBattery")
        @test !(gone in ns)
    end
end

# 🔴 S5 (2026-09-05). 화물 금지 동사는 S4 의 함정을 **안 밟는다** — 위치인자가 무타입 `env`
#    하나뿐이고 kwarg 에 전부 기본값이 있어 `_arg_obtainable(Any) == true` 로 바로 열린다.
#    그래서 `_CURATED_SEEDS` 를 늘리지 않았고, 이 testset 이 그 사실(씨앗을 안 늘렸다 +
#    그럼에도 첫째 표제 아래다)을 함께 잰다.
@testset "(10) 🔴 S5: 화물 금지 동사는 씨앗 없이 호출 가능하다" begin
    j = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    fhc = only(filter(m -> String(m.name) == "forbid_heavy_cargo!", ms))
    @test fhc.callable === true
    @test isempty(fhc.missing)                    # 🔴 S4 와 다른 점이 정확히 이것이다
    @test isempty(fhc.argpaths)                   # `env` 는 하네스가 준다 — 경로가 필요 없다
    @test occursin("agent", String(fhc.signature)) && occursin("n", String(fhc.signature))
    # 음성 대조: `ForbidHeavyCargo` **타입**은 여전히 폐포 밖이다(동사만 열었다).
    ns = Set(String[String(t.name) for t in j.types])
    @test !("ForbidHeavyCargo" in ns)
end

# 🔴 (다) (2026-09-05). 무타입 위치 인자의 **변환**을 광고한다 — 유료 런 19·20·22 가
#    전부 이 자리에서 죽었다: `Vector{Float64}(::TransformNode)`(19) ·
#    `Vector{Float64}(::AffineMap)`(20·22). (나-1)이 좌표를 **꺼내는** 길을 열자 런 22 의
#    body 는 그 길을 맞게 골랐고(`global_transform(goal_config(node))`), 그 AffineMap 을
#    `free_space_status` 의 무타입 `goal` 에 넘겼다. 요구는 callee 의 body 에 이미 적혀
#    있었다(`Vector{Float64}(goal)[1:2]`) — 광고만 그것을 안 옮겼다.
@testset "(9c) 🔴 (다): 무타입 인자가 소스에서 무엇으로 바뀌는지 광고된다" begin
    j  = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    _ac(m) = haskey(m, :arg_coercions) ? String[String(x) for x in m.arg_coercions] : nothing

    # ---- 런 22 를 죽인 바로 그 메서드 ---------------------------------------------------
    fs = only(filter(m -> String(m.name) == "free_space_status", ms))
    ac = _ac(fs)
    @test ac !== nothing
    @test length(ac) == 2
    @test any(c -> startswith(c, "start <- "), ac)
    @test any(c -> startswith(c, "goal <- "),  ac)
    # 🔴 첨자를 지키는 것이 이 개입의 절반이다: `[1:2]` 가 빠지면 "벡터여야 한다" 까지만
    #    남고 **평면 점**이라는 사실이 사라진다.
    @test all(c -> occursin("Vector{Float64}", c) && occursin("[1:2]", c), ac)

    ge = only(filter(m -> String(m.name) == "goal_engulfed", ms))
    @test _ac(ge) !== nothing
    @test all(c -> occursin("[1:2]", c), _ac(ge))

    # ---- 🔴 음성 대조 1: **타입이 붙은** 인자에는 절대 안 붙는다 -------------------------
    #    붙으면 시그니처가 이미 말하는 것에 둘째 진실원이 생긴다(규약 6 이 `soc` 에서
    #    걷어낸 것과 같은 결함 부류).
    n_ac = 0
    for m in ms
        a = _ac(m); a === nothing && continue
        pos = first(split(lstrip(String(m.signature), '('), ';'))
        for c in a
            n_ac += 1
            arg = first(split(c, " <- "))
            @test !occursin(string(arg, "::"), pos)
            @test occursin(arg, pos)
        end
    end
    @test n_ac >= 5                      # 모집단이 비면 위 시험들이 아니라 여기가 빨개진다

    # ---- 🔴 음성 대조 2: 삼상 — 못 유도하면 **키가 없다** --------------------------------
    #    `[]` 를 실으면 "변환이 없다" 는 주장이 되는데 우리는 그것을 안 쟀다.
    @test !any(m -> _ac(m) == String[], ms)
    @test any(m -> _ac(m) === nothing, ms)

    # ---- 🔴 음성 대조 3: 폐포도 호출 가능성도 **안 움직였다** ----------------------------
    #    이 개입은 `method_entries` 의 필드 하나만 더한다. 수가 움직였다면 그것은
    #    이 태스크가 의도하지 않은 부작용이고, 조용히 지나가면 안 된다.
    @test length(ms) == 224
    @test count(m -> m.callable === true, ms) == 195
    ns = Set(String[String(t.name) for t in j.types])
    @test !("AffineMap" in ns)
    @test !("Ball2" in ns)
end


# 🔴 (라) (2026-09-05). 유도가 맨 `NamedTuple` 로 넓어진 자리에 **필드 이름**을 싣는다 —
#    유료 런 23·26 이 여기서 죽었다. run23 의 body 가 자기 주석에 원인을 적었다:
#    "No query returns the blocked schedule-node objects directly, so inspect the active
#    unfinished frontier and test each cargo-navigation path." 그래서 탐지를 손수 짰고
#    `env.cache.active_set` 으로 걸렀는데 존 주입기는 **일부러 active 가 아닌 목표**를 고른다
#    ⟹ 빈손 ⟹ 던졌다. 그 질의는 있었다: `zone_blockage(...).blocked`.
@testset "(9d) 🔴 (라): 넓어진 NamedTuple 반환의 필드 이름이 광고된다" begin
    j  = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    _rf(m) = haskey(m, :returned_fields) ? String[String(x) for x in m.returned_fields] : nothing

    # ---- run23 이 "없다" 고 적은 그 질의 -------------------------------------------------
    zb = only(filter(m -> String(m.name) == "zone_blockage", ms))
    rf = _rf(zb)
    @test rf !== nothing
    @test "blocked" in rf
    @test "n_blocked" in rf
    @test "project_blocked" in rf

    # ---- 🔴 음성 대조 1: **return 위치만** 센다 -----------------------------------------
    #    body 중간의 `push!(blocked, (vtx=…, id=…, kind=…, status=…))` 는 **원소**를 짓는다.
    #    그 넷을 최상위 필드로 광고하면 거짓말이다.
    for leaked in ("vtx", "id", "kind")
        @test !(leaked in rf)
    end

    # ---- 🔴 회귀: 갈래 전부의 합집합이어야 한다 -------------------------------------------
    #    첫 구현의 안쪽 클로저가 누산기와 같은 이름(`acc`)을 써서 **마지막 return 의 필드만**
    #    남았다(줄리아의 클로저 포획). `detail`·`reason` 은 마지막이 아닌 갈래에만 있으므로
    #    그 침묵을 잡는 초병이다.
    tw = only(filter(m -> String(m.name) == "translate_whole_build!", ms))
    @test "detail" in _rf(tw)
    fr = only(filter(m -> String(m.name) == "fault_robot_and_reassign!", ms))
    @test "detail" in _rf(fr)
    @test "reason" in _rf(fr)

    # ---- 🔴 음성 대조 2: 유도가 말한 자리엔 **안 묻는다** ---------------------------------
    #    타입이 이미 필드를 말하면 이것은 둘째 진실원이다.
    n_rf = 0
    for m in ms
        _rf(m) === nothing && continue
        n_rf += 1
        @test String(m.returns) == "NamedTuple"
    end
    @test n_rf == 4
    zd = only(filter(m -> String(m.name) == "zone_diagnosis", ms))
    @test startswith(String(zd.returns), "NamedTuple{(")
    @test _rf(zd) === nothing

    # ---- 🔴 음성 대조 3: 삼상 · 폐포도 호출 가능성도 안 움직였다 --------------------------
    @test !any(m -> _rf(m) == String[], ms)
    @test any(m -> _rf(m) === nothing, ms)
    @test length(ms) == 224
    @test count(m -> m.callable === true, ms) == 195
end


# 🔴 (마) (2026-09-05). 유료 런 27·28·29. (라)가 `zone_blockage(...).blocked` 를 광고하자
#    **세 판 다 그것을 찾아 썼다** — 개입은 도달했다. 그런데 세 판 다 그것을 *id 의 목록*으로
#    읽어(`env.sched.vtx_map[blocked_id]` · `node.id in blocked_ids`) 매칭이 전부 빗나갔고
#    셋 다 빈손으로 끝났다. 원소는 `(vtx, id, kind, status)` 다.
#    ⟹ 필드 **이름**만 대고 안의 **모양**을 안 대면 모델은 손을 뻗은 그 자리에서 넘어진다.
@testset "(9e) 🔴 (마): NamedTuple 벡터 필드의 원소 모양이 광고된다" begin
    j  = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    _fe(m) = haskey(m, :field_element_fields) ?
             String[String(x) for x in m.field_element_fields] : nothing

    zb = only(filter(m -> String(m.name) == "zone_blockage", ms))
    @test _fe(zb) == ["blocked[] :: (id, kind, status, vtx)"]

    # 🔴 특례가 아니라 일반 규칙이라는 증거 — 같은 수확이 이 레인이 실제로 부르는 다른
    #    동사도 덮는다.
    rb = only(filter(m -> String(m.name) == "restage_all_blocked!", ms))
    @test _fe(rb) == ["failed[] :: (id, status)", "moved[] :: (from, id, to)"]

    # ---- 🔴 음성 대조 1: 모집단은 정확히 둘이고 삼상이다 ---------------------------------
    got = String[String(m.name) for m in ms if _fe(m) !== nothing]
    @test sort(got) == ["restage_all_blocked!", "zone_blockage"]
    @test !any(m -> _fe(m) == String[], ms)
    @test any(m -> _fe(m) === nothing, ms)

    # ---- 🔴 음성 대조 2: 둘째 진실원이 되는 날을 알리는 초병 -------------------------------
    #    이 사실은 타입이 **침묵하는** 자리를 메운다. 누군가 원소 타입을 좁히면 타입과 이 줄이
    #    같은 것을 두 번 말하게 되고, 그날 게이트를 걸어야 한다.
    #    🔴 이름으로 훑지 않는다 — `status` 는 원소 필드이자 바깥 필드이기도 하다(실측: 첫
    #    판이 그 오탐으로 빨개졌다). 정확히 "그 필드의 원소 타입" 하나만 문다.
    for m in (zb, rb)
        ret = String(m.returns)
        for entry in _fe(m)
            fld = first(split(entry, "[]"))
            occursin(string(fld, "::"), ret) || continue
            @test occursin(string(fld, "::Vector{NamedTuple}"), ret)
        end
    end

    # ---- 🔴 음성 대조 3: 폐포도 호출 가능성도 안 움직였다 ---------------------------------
    @test length(ms) == 224
    @test count(m -> m.callable === true, ms) == 195
end

end # module
