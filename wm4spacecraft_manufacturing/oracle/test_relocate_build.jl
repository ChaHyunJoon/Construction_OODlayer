# =============================================================================
# test_relocate_build.jl -- RelocateBuild(매크로 7) 배선 단위검사. 시뮬레이션 없음(수 초).
#
# 왜 이 파일이 있나: RelocateBuild 는 5곳(DSL/검증기/dispatch/shim/비용표)에 동시에 손을 대야
# 하고, 한 곳만 빠져도 **시뮬은 정상인데 행을 쓰는 순간** KeyError 로 죽거나(2026-08-02 ACTION_NAME
# 실측) 조용히 NOOP 으로 붕괴한다. 14분짜리 판을 돌리기 전에 그 5곳을 초 단위로 대조한다.
#
#   julia +lts --project=<repo> oracle/test_relocate_build.jl
# =============================================================================
using ConstructionBots
const CB = ConstructionBots

# ood_truth.jl(ZoneTruth/record_ood_truth! 등)은 navigator.jl 안에 있고 **런타임에 CB 스코프로**
# include 된다(world-age 회피). 생성기가 하는 것과 같은 방식으로 여기서도 올려야 CB.ZoneTruth 가 보인다.
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

include(joinpath(@__DIR__, "ood_mdp_shim.jl"))

const FAILED = Ref(0)
function check(name, cond, detail = "")
    if cond
        println("  PASS  $name")
    else
        FAILED[] += 1
        println("  FAIL  $name   $detail")
    end
end

println("== 1. DSL: RelocateBuild 타입이 닫힌 합집합에 들어왔는가 ==")
rb = CB.RelocateBuild(:zoneblk)
check("RelocateBuild <: ConstraintSpec", rb isa CB.ConstraintSpec)
check("zone 필드 보존", rb.zone === :zoneblk, "got $(rb.zone)")
check("referenced_ids 는 비어야 함(노드를 안 지목)",
      isempty(collect(CB.referenced_ids(rb))), "got $(CB.referenced_ids(rb))")
check("compile_constraint! 는 0 제약(MILP 우회)",
      CB.compile_constraint!(nothing, nothing, nothing, nothing, nothing, rb) == 0)

println("== 2. dispatch 판별기 ==")
p_rb = CB.RespecProposal(CB.ConstraintSpec[rb], "test", "nl")
check("_is_relocate_build(RelocateBuild 제안)", CB._is_relocate_build(p_rb))
check("_is_zone_respec 는 false(다른 종류)", !CB._is_zone_respec(p_rb))
p_fz = CB.RespecProposal(CB.ConstraintSpec[CB.ForbidZone(CB.AssemblyID(1), :zoneblk)], "", "")
check("_is_relocate_build(ForbidZone 제안) = false", !CB._is_relocate_build(p_fz))
# 혼합 제안: 둘 다 참이어야 하고, replan.jl 이 RelocateBuild 분기를 **먼저** 검사한다.
p_mix = CB.RespecProposal(CB.ConstraintSpec[CB.ForbidZone(CB.AssemblyID(1), :zoneblk), rb], "", "")
check("혼합 제안에서 두 판별기 모두 true", CB._is_relocate_build(p_mix) && CB._is_zone_respec(p_mix))

println("== 3. verify_relocate 게이트 ==")
# env 없이도 zone-exists 검사만 따로 확인할 수 있게, 실제 구역을 등록/삭제해 대조한다.
CB.clear_restriction_zones!()
CB.add_restriction_zone!(:zoneblk, [0.0, 0.0], 1.0)
check("등록된 구역이 RESTRICTION_ZONES 에 보임", haskey(CB.RESTRICTION_ZONES[], :zoneblk))
check("없는 구역 이름은 게이트가 막아야 함(수동 대조)",
      !haskey(CB.RESTRICTION_ZONES[], :nosuchzone))
CB.clear_restriction_zones!()

println("== 4. shim: zone 사건의 팔이 [0,7] 인가 ==")
ctx_zone = (type = :zone, agent = nothing, zone = :zoneblk, assembly = CB.AssemblyID(3),
            soc = NaN, after = 0.0, source = "a no-go zone appeared")
check("valid_actions(:zone) == [0,7]", valid_actions(ctx_zone) == [0, 7],
      "got $(valid_actions(ctx_zone))")
check("canonical_action(:zone) == 7", canonical_action(ctx_zone) == 7,
      "got $(canonical_action(ctx_zone))")
prop = action_to_proposal(ctx_zone, 7)
check("action_to_proposal(ctx,7) 가 제안을 만든다", prop !== nothing)
if prop !== nothing
    check("그 제안이 RelocateBuild 하나", length(prop.constraints) == 1 &&
          prop.constraints[1] isa CB.RelocateBuild)
    check("zone 키가 그대로 전달됨", prop.constraints[1].zone === :zoneblk)
end
# assembly 가 없어도 성립해야 한다 — 이게 ForbidZone 과 갈리는 핵심(전체를 옮기므로 grounding 불필요).
ctx_noasm = (type = :zone, agent = nothing, zone = :zoneblk, assembly = nothing,
             soc = NaN, after = 0.0, source = "zone")
check("assembly=nothing 이어도 7 은 유효(ForbidZone 과 갈리는 지점)",
      action_to_proposal(ctx_noasm, 7) !== nothing)
check("assembly=nothing 이면 3 은 NOOP 으로 붕괴(기존 동작 유지)",
      action_to_proposal(ctx_noasm, 3) === nothing)

println("== 4b. STEP 2: 최소수복 규칙이 zone 의 팔/기준정책을 정하는가 ==")
# 시뮬 없이 검사하기 위해 진단 결과(zdiag)를 손으로 만들어 붙인다. 진짜 기하로 계산한 zdiag 가
# 규칙과 일치하는지는 tools/tests.jl zone_diagnosis 가 env 위에서 확인한다. 여기서 보는 것은
# "그 판정이 팔과 기준정책으로 올바르게 번역되는가" 하나뿐이다.
zctx(zd) = (type = :zone, agent = nothing, zone = :zoneblk, assembly = nothing,
            soc = NaN, after = 0.0, source = "a no-go zone appeared", zdiag = zd)
mkzd(; verdict, nf = 0, target = nothing, root = 0, teams = 0, reloc = true) =
    (verdict = verdict, n_blocked = nf, n_restage_feasible = nf, restage_target = target,
     root_covered = root, root_total = 8, n_work_overlap = 0,
     n_teams_forming = teams, n_teams_covered = teams,
     relocate_feasible = reloc, relocate_norm = reloc ? 5.0 : Inf)

# (a) 아무것도 안 덮음 -> 개입 불가 팔은 빼고, 기준정책은 절제.
c_noop = zctx(mkzd(verdict = :noop))
check("noop: 팔 == [0,7] (옮길 게 없으니 3 은 빠진다)", valid_actions(c_noop) == [0, 7],
      "got $(valid_actions(c_noop))")
check("noop: canonical == 0 (옛 '무조건 개입' 을 뒤집음)", canonical_action(c_noop) == 0,
      "got $(canonical_action(c_noop))")

# (b) 국소 재적치 가능 -> 3 이 팔에 들어오고 그게 기준정책.
c_fz = zctx(mkzd(verdict = :forbid_zone, nf = 2, target = CB.AssemblyID(3), root = 8))
check("forbid_zone: 팔 == [0,3,7]", valid_actions(c_fz) == [0, 3, 7], "got $(valid_actions(c_fz))")
check("forbid_zone: canonical == 3", canonical_action(c_fz) == 3, "got $(canonical_action(c_fz))")
p_fz3 = action_to_proposal(c_fz, 3)
# 이게 이 커밋의 핵심 구멍 메우기다: ZoneTruth 가 assembly 를 안 실어줘도 진단이 대상을 준다.
check("assembly=nothing 이어도 3 이 제안을 만든다(진단이 대상을 준다)", p_fz3 !== nothing)
p_fz3 === nothing || check("그 제안이 ForbidZone(대상=진단이 고른 조립체)",
    p_fz3.constraints[1] isa CB.ForbidZone && p_fz3.constraints[1].assembly == CB.AssemblyID(3))

# (c) 도메인은 비었는데 root 가 갇힘 -> 전역 이동.
c_rb = zctx(mkzd(verdict = :relocate_build, root = 5))
check("relocate_build: 팔 == [0,7]", valid_actions(c_rb) == [0, 7], "got $(valid_actions(c_rb))")
check("relocate_build: canonical == 7", canonical_action(c_rb) == 7, "got $(canonical_action(c_rb))")

# (d) 형성 중인 팀이 갇힘(새 술어) -> 같은 전역 팔. ReformTeam(4)이 아니다 —
#     집결지가 금지구역이면 recover_stalled_teams! 가 snap 을 거부하고 restage/translate 를 한다.
c_team = zctx(mkzd(verdict = :relocate_build, teams = 1))
check("팀 갇힘: canonical == 7 (ReformTeam 아님)", canonical_action(c_team) == 7,
      "got $(canonical_action(c_team))")
check("팀 갇힘: 4 는 zone 팔에 없다", !(4 in valid_actions(c_team)))

# (e) 어떤 개입도 행동할 수 없음 -> 팔은 [0] 뿐. 닫힌 어휘에 수복이 없다는 정직한 진술.
c_ls = zctx(mkzd(verdict = :line_stop, root = 8, reloc = false))
check("line_stop: 팔 == [0]", valid_actions(c_ls) == [0], "got $(valid_actions(c_ls))")
check("line_stop: canonical == 0", canonical_action(c_ls) == 0, "got $(canonical_action(c_ls))")

# (f) 명시 지정(DS_ZONE_ARMS)은 진단보다 우선한다 — 옛 덤프 재현 경로가 살아 있는가.
ENV["DS_ZONE_ARMS"] = "0,7"
check("DS_ZONE_ARMS 가 진단을 이긴다", valid_actions(c_ls) == [0, 7], "got $(valid_actions(c_ls))")
delete!(ENV, "DS_ZONE_ARMS")

println("== 5. 다른 종류의 팔은 건드리지 않았는가(회귀) ==")
ctx_fault = (type = :fault, agent = CB.RobotID(1), zone = nothing, assembly = nothing,
             soc = NaN, after = 0.0, source = "broken")
# 2026-08-16: fault 의 팔이 `[0,1]` 리터럴에서 **레지스트리 파생**으로 바뀌었다.
#   왜 기대값을 고치는가(코드가 아니라): `[0,1]` 은 삭제 이전 덤프에서 베낀 리터럴인데,
#   `valid_actions` 는 `action_to_proposal` 의 문지기이기도 해서 그 리터럴이 fault 사건에
#   `ReformTeam(4)`·`Deprioritize(2)` 를 **원리적으로 못 쓰게** 막고 있었다. 실행 레인은 같은
#   사건에 ReformTeam 을 1182회 집행하는데(2026-08-15 실측) 라벨 격자에는 그 팔이 없었고,
#   그게 Reform 축 gap 이 13/13 = 100% 였던 원인이다.
#   옛 고정 집합 재현은 `DS_ARMS_LEGACY=1` 로 남아 있고, 아래에서 그것도 함께 검사한다.
check("valid_actions(:fault) == kind_valid(:fault) (레지스트리 파생)",
      valid_actions(ctx_fault) == ActionRegistry.kind_valid(:fault),
      "got $(valid_actions(ctx_fault))  expected $(ActionRegistry.kind_valid(:fault))")
check("그 집합이 조합 팔 없이는 [0,1,2,4] 다",
      (get(ENV, "DS_COMBO_ARMS", "0") == "1") || valid_actions(ctx_fault) == [0, 1, 2, 4],
      "got $(valid_actions(ctx_fault))")
ENV["DS_ARMS_LEGACY"] = "1"
check("DS_ARMS_LEGACY=1 이 옛 고정 집합 [0,1] 을 되돌린다",
      valid_actions(ctx_fault) == [0, 1], "got $(valid_actions(ctx_fault))")
delete!(ENV, "DS_ARMS_LEGACY")
ctx_batt_mild = (type = :battery, agent = CB.RobotID(1), zone = nothing, assembly = nothing,
                 soc = 0.55, after = 0.0, source = "battery")
# 2026-08-04 SwapBattery(8) 도입 후 battery 의 팔은 양쪽 칸 모두 8 을 포함한다(shim 주석 참조).
# 이 기대값은 그 변경 전에 쓰여 있어서 계속 FAIL 하고 있었다 — 코드가 아니라 기대값이 낡은 것이었다.
check("valid_actions(:battery mild) == [0,2,8]", valid_actions(ctx_batt_mild) == [0, 2, 8],
      "got $(valid_actions(ctx_batt_mild))")
ctx_batt_deep = (type = :battery, agent = CB.RobotID(1), zone = nothing, assembly = nothing,
                 soc = 0.05, after = 0.0, source = "battery")
check("valid_actions(:battery deep) == [0,1,8]", valid_actions(ctx_batt_deep) == [0, 1, 8],
      "got $(valid_actions(ctx_batt_deep))")
check("valid_actions(:reform) == [0,4]",
      valid_actions((type = :reform, agent = nothing, zone = nothing, assembly = nothing,
                     soc = NaN, after = 0.0, source = "")) == [0, 4])

println("== 6. DS_ZONE_ARMS 로 옛 동작(0,3) 복원 가능한가 ==")
ENV["DS_ZONE_ARMS"] = "0,3"
check("DS_ZONE_ARMS=0,3 이면 [0,3]", valid_actions(ctx_zone) == [0, 3],
      "got $(valid_actions(ctx_zone))")
check("그때 canonical 은 3(ForbidZone)", canonical_action(ctx_zone) == 3)
delete!(ENV, "DS_ZONE_ARMS")
check("환경변수 지우면 다시 [0,7]", valid_actions(ctx_zone) == [0, 7])

println("== 7. 비용/이름표가 파이썬 쪽과 같은 값인가 ==")
# gen_oracle_dataset.jl 의 표를 파일에서 직접 읽어 대조한다(그 파일을 통째로 include 하면
# 시뮬 세팅이 전부 실행되므로 불가). 파이썬 쪽 값은 features_agnostic.py 에서 읽는다.
gen_src = read(joinpath(@__DIR__, "gen_oracle_dataset.jl"), String)
check("gen 의 ACTION_NAME 에 7=>\"RelocateBuild\"", occursin("7=>\"RelocateBuild\"", gen_src))
check("gen 의 MACRO_COST 에 7 => 1.5", occursin(r"7\s*=>\s*1\.5", gen_src))
py_src = read(joinpath(@__DIR__, "..", "features_agnostic.py"), String)
# 2026-08-16: 이 검사는 `features_agnostic.py` 안에 `7: 1.5` **리터럴**이 있는지를 봤는데,
#   2026-08-15 에 그 표가 `MACRO_COST = dict(_reg.MACRO_COST)` 로 **레지스트리 파생**이 되면서
#   리터럴이 사라져 그날부터 계속 FAIL 하고 있었다(실제 값은 1.5 로 맞다 — 검사가 낡은 것이다).
#   리터럴을 되살리는 것은 정확히 반대 방향이므로, **파생을 하고 있는지**를 검사한다.
#   값 자체는 레지스트리에서 직접 확인한다(그게 단일 진실원이다).
check("features_agnostic 가 MACRO_COST 를 레지스트리에서 파생한다",
      occursin("import action_registry as _reg", py_src) &&
      occursin(r"MACRO_COST\s*=\s*dict\(_reg\.MACRO_COST\)", py_src))
check("레지스트리의 7(RelocateBuild) 비용이 1.5 다",
      ActionRegistry.COST[7] == 1.5, "got $(ActionRegistry.COST[7])")
check("features_agnostic._ACTION_TABLE 에 7 행", occursin("RelocateBuild", py_src))

println("== 7b. 배경 알람(팀 교착)이 마지막 truth 로 오분류되지 않는가 ==")
# 2026-08-04 회귀: maybe_emit_reform_ood! 는 truth 를 안 남기므로 NL 매칭이 실패한다.
# 예전 코드가 last(log) 를 집어 :zone 으로 뒤집어썼고, 그 결과 producer 의 :reform 분기를 못 타
# 자가복구가 통째로 죽었다(팀 교착 499회 → ReformTeam 0건). 이 검사가 그 재발을 막는다.
CB.clear_ood_truth_log!()
CB.record_ood_truth!("A no-go exclusion zone has appeared over the central build area.",
                     CB.ZoneTruth(:zoneblk, Float64[0.0, 0.0], 1.0, nothing))
const REFORM_NL = "A multi-robot transport team is deadlocked while forming: some members are " *
                  "waiting in their carrying positions but the team cannot complete and the build has stalled."
ctx_bg = event_context(nothing, REFORM_NL)
check("팀 교착 알람이 :reform 으로 분류된다(마지막 ZoneTruth 를 안 뒤집어씀)",
      ctx_bg.type === :reform, "got $(ctx_bg.type)")
check("그래서 팔이 [0,4] 가 된다", valid_actions(ctx_bg) == [0, 4], "got $(valid_actions(ctx_bg))")
check("canonical 이 ReformTeam(4)", canonical_action(ctx_bg) == 4)
# 반대로 **매칭되는** NL 은 여전히 truth 를 그대로 써야 한다(폴백 제거가 정상 경로를 깨지 않았는지).
ctx_zone2 = event_context(nothing, "A no-go exclusion zone has appeared over the central build area.")
check("매칭되는 NL 은 truth 대로 :zone", ctx_zone2.type === :zone, "got $(ctx_zone2.type)")
CB.clear_ood_truth_log!()

println("== 8. core zone(harm 축) 생성 가드가 배선됐는가 ==")
# 기하가 필요한 검사(실제 커버리지/복구가능성)는 tools/tests.jl relocatebuild_parse 가 env 위에서 한다.
# 여기서는 심볼이 존재하고 표/키가 서로 어긋나지 않았는지만 초 단위로 본다.
for f in (:root_goal_coverage, :zone_relocatable, :core_zone_for_severity)
    check("CB.$(f) export 됨", isdefined(CB, f))
end
gen_src2 = read(joinpath(@__DIR__, "gen_oracle_dataset.jl"), String)
check("place_core_zone! 정의됨", occursin("function place_core_zone!", gen_src2))
check("zonecore 가 :zone 이벤트로 분류됨",
      occursin(r"_event_type\(kind::Symbol\)\s*=\s*kind in \(:zoneblk, :zoneharm, :zonecore\)", gen_src2))
# 이게 깨지면 kind one-hot 이 다시 정답을 결정해 과제가 trivial 해진다(GRADED severity 원칙).
check("zonecore 의 row_kind 라벨이 zoneblk 와 **같다**",
      occursin(r":zoneblk, :zoneharm, :zonecore\)\s*\?\s*\"zoneblk\"", gen_src2))
check("zonecore 도 zone 팔([0,7])을 쓴다",
      occursin("k in (:zoneblk, :zonecore) && return _zone_arms()", gen_src2))
check("harm 축 열(zone_root_cover)이 덤프에 실린다", occursin("zone_root_cover = zroot", gen_src2))
py_src2 = read(joinpath(@__DIR__, "..", "e1_analyze.py"), String)
check("featurize 가 zone_root_cover 를 읽는다", occursin("X[\"zone_root_cover\"]", py_src2))

println()
if FAILED[] == 0
    println("ALL PASS — RelocateBuild 배선 정상")
else
    println("$(FAILED[]) CHECK(S) FAILED")
    exit(1)
end
