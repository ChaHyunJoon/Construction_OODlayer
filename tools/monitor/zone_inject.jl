# =============================================================================
# zone_inject.jl -- **사람이 sim 전에 고른** 좌표에 no-go 구역을 심는다.
#
# 왜 탐색을 안 하나: ForbidZone(국소 재적치)의 도메인은 **아직 시작 안 한(pristine) 조립체**뿐인데,
# tractor 는 첫 시뮬 배치에서 ~58 노드를 닫고 restageable 집합은 그 전에 이미 0 이 된다.
# 게다가 `schedule_ood_at_closed!` 은 배치 경계에서만 발화하므로 closed<58 에 **도달 자체가 안 된다**
# (실측: oracle/out/fz_scan.csv, 관측 가능한 전 구간 pristine=0). 즉 이 팔이 살아 있는 시점은
# sim 시작 전뿐이고, 그 자리는 런타임에 "찾는" 것이 아니라 **미리 정하는** 것이다.
#
# 좌표는 oracle/out/fz_presim.csv(Task 1 카탈로그)에서 사람이 고른다. 그 표의 각 행은
# "이 좌표에 이 반지름으로 심으면 진단이 무엇이 되는가"를 sim 전 기하로 미리 계산해 둔 것이다.
#
# 기존 주입기 두 개(inject_staging_zone! / inject_blocking_zone!)는 **건드리지 않는다** --
# RESULTS_LLM7H §5 의 20판이 그 함수들이 만든 세계이고, 그 재현성이 비교의 전제다.
#
# 전제: 이 파일을 include 하는 쪽에 CB 가 정의돼 있다.
# =============================================================================

"""
    inject_declared_zone!(env; cx, cy, r, key = :zone_declared) -> Union{String,Nothing}

`(cx, cy)` 에 반지름 `r` 의 구역을 심고, **실제로 결정 문제가 되는지 확인한 뒤** truth 를 기록한다.

확인하는 두 조건과 그 이유:
  · `n_restage_feasible >= 1` — ForbidZone 이 옮길 자리가 실제로 있다. 0 이면 그 팔은 NOOP 과
    바이트 동일해지고(restage_all_blocked! 이 `:none` 으로 조기 반환), 메뉴에 넣어 봐야 동점을 제조할 뿐이다.
  · `n_nav_blocked >= 1` — 그 구역이 실제로 항법 목표를 막는다. 덮임은 해로움이 아니다(STEP 6 실측:
    root 하역목표를 8/8 삼켜도 완주했다). 안 막는 구역은 정답이 언제나 NOOP 이라 결정이 아니다.

둘 중 하나라도 안 되면 **구역을 지우고 `nothing` 을 돌려준다**. 조용히 심어 두면 "LLM 이 ForbidZone 을
안 골랐다"와 "고를 수 없었다"가 요약에서 구분되지 않는다.
"""
function inject_declared_zone!(env; cx::Float64, cy::Float64, r::Float64,
                               key::Symbol = :zone_declared)
    c = Float64[cx, cy]
    z = CB.add_restriction_zone!(key, c, r)
    d = try CB.zone_diagnosis(env, key; check_restage = true) catch e
        @warn "[zone] zone_diagnosis 실패" exception = e; nothing
    end
    if d === nothing || d.n_restage_feasible < 1 || d.n_nav_blocked < 1
        CB.remove_restriction_zone!(key)
        println("[zone] declared zone @($(cx), $(cy)) r=$(r) 은 결정 문제가 아니다 " *
                "(restage_feasible=$(d === nothing ? -1 : d.n_restage_feasible), " *
                "nav_blocked=$(d === nothing ? -1 : d.n_nav_blocked)) -> 심지 않음")
        return nothing
    end
    println("[zone] declared zone @($(cx), $(cy)) r=$(r) -> " *
            "restage_feasible=$(d.n_restage_feasible) nav_blocked=$(d.n_nav_blocked)/$(d.n_nav_goals) " *
            "verdict=$(d.verdict)")
    # 관찰만 남기고 "그러니 무엇을 하라"는 붙이지 않는다 -- 뒷절이 곧 정답이라, 주는 순간
    # 재는 것이 추론이 아니라 프롬프트 준수가 된다(STEP 4).
    nl = "A no-go exclusion zone has appeared at ($(round(cx; digits = 2)), " *
         "$(round(cy; digits = 2))) with radius $(round(r; digits = 2)). " *
         "Robots that enter the disc are pushed back out of it."
    # assembly 를 nothing 으로 남기면 안 된다: canonical_respec(::ZoneTruth)(baselines.jl:73)는
    # 정확히 이 필드로 분기해서, assembly===nothing 이면 "nav zone -> motion-stack detour(no DSL)"
    # 라며 빈 제안(NOOP)을 낸다 -- 그런데 우리는 방금 위에서 n_restage_feasible>=1 을 확인했다,
    # 즉 staging 이 실제로 막혀 있다. nothing 을 실으면 그 확인과 모순되는 truth 를 기록하는
    # 셈이라 canonical 규칙이 "이 구역은 아무것도 안 막는다"는, 우리가 방금 반증한 세계에 답한다.
    # d.feasible 은 zone_diagnosis 가 이미 계산해 둔 "실제로 옮길 수 있는" 조립체 목록(그 개수가
    # n_restage_feasible)이므로 그 첫 원소를 대상으로 싣는다. 순서는 env 구성 순서(고정 시드)에서
    # 결정적이다 -- zone_blocked_assemblies(restage_zone.jl)가 env.staging_circles 를 그대로
    # 순회해 만들고 zone_diagnosis 의 filter 는 그 순서를 보존한다(재정렬 없음).
    try CB.record_ood_truth!(nl,
        CB.ZoneTruth(key, Float64[cx, cy], Float64(CB.get_radius(z)), first(d.feasible))) catch e
        @warn "[zone] record_ood_truth! 실패" exception = e
    end
    return nl
end

"""
    declared_zone_spec() -> Union{NamedTuple,Nothing}

`DEMO_ZONE_AT="cx,cy,r"` 를 파싱한다. 없거나 형식이 틀리면 `nothing`(= 기존 경로).
형식 오류를 조용히 무시하지 않고 경고를 찍는 이유: 오타 하나로 "선언적 주입을 켰다"고 적은 판이
사실은 옛 argmin 주입기 판이 되는데, 요약만 봐서는 구분이 안 되기 때문이다.
"""
function declared_zone_spec()
    s = strip(get(ENV, "DEMO_ZONE_AT", ""))
    isempty(s) && return nothing
    parts = split(s, ",")
    if length(parts) != 3
        @warn "[zone] DEMO_ZONE_AT 형식은 \"cx,cy,r\" 이다 — 무시하고 기존 주입기를 쓴다" got = s
        return nothing
    end
    return try
        (cx = parse(Float64, strip(parts[1])),
         cy = parse(Float64, strip(parts[2])),
         r  = parse(Float64, strip(parts[3])))
    catch e
        @warn "[zone] DEMO_ZONE_AT 파싱 실패 — 무시하고 기존 주입기를 쓴다" got = s exception = e
        nothing
    end
end
