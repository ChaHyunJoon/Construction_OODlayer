# =============================================================================
# 손으로 씨 뿌리는 원시 표 — **시험 픽스처**. (2026-09-03, Task 10)
#
# 🔴 이것은 되살린 레지스트리가 **아니다.** 삭제된 것은
#    `wm4spacecraft_manufacturing/core/primitive_registry.json`(파일에서 읽던 고정 19-원시
#    알파벳)과 그것을 읽던 `PRIMITIVE_TABLE`/`_reset_primitive_table!`/
#    `_primitive_registry_path` 다(설계 §7, Task 2). 오늘 원시는 **런에서 생성되고**
#    `register_minted_primitive!` 가 런-스코프 표(`minted_table()`)에 심는다.
#
# 🔴 그런데 집행부(`src/respec/minted_tool.jl`)의 **생산 코드**는 여전히 손으로 쓴 원시
#    이름들로 색인된 표 다섯을 들고 있다 — `SILENT_SUCCESS_STATUSES` ·
#    `WORLD_UNCHANGED_STATUSES` · `PRIMITIVE_RESUMES_CACHE` · `COUNT_RETURN_PRIMITIVES` ·
#    `EDGELIST_RETURN_PRIMITIVES`. 그 표들이 재는 것(어느 status 가 조용한 성공인가, 어느
#    것이 세계를 만졌는가, 어느 것이 캐시 재개를 요구하는가)은 알파벳과 무관한 **집행
#    기계의 성질**이고, 그것을 태우려면 그 이름들이 표에 있어야 한다. 그래서 시험이
#    직접 씨를 뿌린다 — `src/respec/minted_registration.jl` 이 이 관용구를 명시적으로
#    예상하고 있고(`"generated"` 필드의 주석: "알려진 원시 여덟도 (시험·프로브가) 손으로
#    씨 뿌려 같은 표에 들어온다"), `test/minted_registration.jl` (2)(10) 이 같은 모양을 쓴다.
#
# 🔴 **`register_minted_primitive!` 를 쓰면 안 된다.** 그 함수는 행에 `"generated" => true`
#    를 찍고, `_step_applied`/`_step_touched_world` 가 그 표시를 읽어 삼상을 다르게 낸다
#    (생성 원시는 status 어휘를 아는 표가 없으므로 `applied = nothing`). 그러면 위의 표
#    다섯을 재려던 시험이 **자기 픽스처 때문에** 다른 갈래를 태우게 된다. 손으로 심는
#    행에는 그 표시가 없고, 그것이 `test/minted_registration.jl` (10) 의 음성 대조다.
#
# 🔴 행의 내용은 은퇴한 레지스트리에서 **그대로** 가져왔다(`git show 16faa75c^:
#    wm4spacecraft_manufacturing/core/primitive_registry.json`). 지어낸 값이 아니다 —
#    `harness_args`·`params` 가 `bind_primitive_args` 의 갈래를 정하므로, 여기서 값을
#    손보면 시험이 프로덕션이 아니라 픽스처를 재게 된다.
#
# ⚠️ 진실원 문제: 이 표는 이제 아무것도 복제하지 않는다(원본이 삭제됐다). 세 시험 파일이
#    같은 행을 각자 베끼는 것을 막으려고 한 자리에 둔 것이고, 그 셋이 유일한 소비처다.
#
# 🔴 **알려진 결합 하나 — 프로세스 전역 상태를 통한 파일 간 결합** (2026-09-03 fix round 2,
#    리뷰가 지적, 재설계하지 않기로 함).
#    아래 `check_minted_fixture()` 는 세 파일에서 **모듈 최상위**(씨뿌리기 직후, `@testset`
#    밖)에서 불리고, 표의 이름 집합에 **정확한 등호**를 요구하며 어긋나면 `error` 로 던진다.
#    `minted_table()` 은 프로세스 전역이고 `test/runtests.jl` 은 모든 시험을 한 프로세스에
#    넣으므로, **앞으로 이 셋보다 먼저 도는 어떤 시험이 주조 행 하나를 남기고 나가면 이 세
#    파일이 include 시점에 통째로 죽는다.**
#    · 오늘은 안 난다(실측: 이 지점에서 표가 비어 있다 — `seed_minted_fixture!` 가 먼저
#      `reset_minted_table!()` 을 부르므로 앞선 잔여물은 지워진다).
#    · 나도 **귀속 가능**하다: 사유가 남은 행 이름과 빠진 행 이름을 그대로 싣는다.
#    · 🔴 그럼에도 이것은 이 레포가 문서화한 실패 모양과 **같은 자리**다 —
#      `test/service_decide_ships_agents.jl` 이 `SPARE_POOLS[:east]` 를 안 치우고 나가서
#      **단독 실행은 초록, `Pkg.test()` 안에서만 빨간** 시험을 만든 사건(CLAUDE.md Gotchas).
#      느슨하게(부분집합으로) 바꾸면 이 검사가 재려던 것(표면이 조용히 넓어진다)을 못 잡으므로
#      등호를 유지한다. 대신 이 문단이 다음 사람에게 진단을 준다.
# =============================================================================

#: 은퇴한 알파벳의 행 전부. `git show 16faa75c^:wm4spacecraft_manufacturing/core/
#: primitive_registry.json` 에서 **기계로 옮겼다**(손으로 옮기지 않았다 — 첫 시도에서
#: `min_ready` 의 `integer` 를 `number` 로, `release_pending_assignments` 의
#: `["string","null"]` 을 `"string"` 으로 잘못 적었고 (14) 절이 그것을 바로 잡아냈다).
#: 뺀 것은 `description` 하나뿐이다: 그 필드는 **프롬프트 텍스트**였고 프롬프트가 없어졌으며,
#: 줄리아 쪽 소비처가 0개다(`_param_type_reject` 는 `type` 만 읽는다).
const MINTED_FIXTURE_ROWS = Dict{String,Any}(
    "release_pending_assignments" => Dict{String,Any}(
        "impl" => "release_pending_assignments!",
        "surface" => "sched",
        "harness_args" => ["env", "invariant"],
        "params" => Dict{String,Any}(
            "faulted" => Dict{String,Any}(
                "type" => ["string", "null"]
            ),
            "agent" => Dict{String,Any}(
                "type" => ["string", "null"]
            )
        ),
        "reversible" => false
    ),
    "reset_slot_to_invalid" => Dict{String,Any}(
        "impl" => "reset_slot_to_invalid!",
        "surface" => "sched",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "slot_v" => Dict{String,Any}(
                "type" => "integer"
            )
        ),
        "reversible" => true
    ),
    "rethread_robot_ids" => Dict{String,Any}(
        "impl" => "rethread_robot_ids!",
        "surface" => "sched",
        "harness_args" => ["sched", "scene_tree"],
        "params" => Dict{String,Any}(),
        "reversible" => true
    ),
    "reform_stuck_teams" => Dict{String,Any}(
        "impl" => "reform_stuck_teams!",
        "surface" => "physical",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "min_ready" => Dict{String,Any}(
                "type" => "integer",
                "default" => 1
            ),
            "snap_all" => Dict{String,Any}(
                "type" => "boolean",
                "default" => false
            )
        ),
        "reversible" => false
    ),
    "recover_stalled_teams" => Dict{String,Any}(
        "impl" => "recover_stalled_teams!",
        "surface" => "physical",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(),
        "reversible" => false
    ),
    "force_advance_stuck_carrier" => Dict{String,Any}(
        "impl" => "force_advance_stuck_carrier!",
        "surface" => "physical",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "tol" => Dict{String,Any}(
                "type" => "number",
                "default" => 0.05
            )
        ),
        "reversible" => false
    ),
    "resolve_schedule_wedge" => Dict{String,Any}(
        "impl" => "resolve_schedule_wedge!",
        "surface" => "sched",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(),
        "reversible" => false
    ),
    "deprioritize_agent" => Dict{String,Any}(
        "impl" => "deprioritize_agent!",
        "surface" => "env_param",
        "harness_args" => [],
        "params" => Dict{String,Any}(
            "agent" => Dict{String,Any}(
                "type" => "string"
            ),
            "factor" => Dict{String,Any}(
                "type" => "number",
                "minimum" => 1.0,
                "maximum" => 1000.0
            )
        ),
        "reversible" => false
    ),
    "restage_assembly" => Dict{String,Any}(
        "impl" => "restage_assembly!",
        "surface" => "scene_tree",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "assembly_id" => Dict{String,Any}(
                "type" => "string"
            ),
            "zone_keys" => Dict{String,Any}(
                "type" => "array",
                "items" => Dict{String,Any}(
                    "type" => "string"
                )
            )
        ),
        "reversible" => true
    ),
    "restage_all_blocked" => Dict{String,Any}(
        "impl" => "restage_all_blocked!",
        "surface" => "scene_tree",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "zone_keys" => Dict{String,Any}(
                "type" => "array",
                "items" => Dict{String,Any}(
                    "type" => "string"
                )
            )
        ),
        "reversible" => true
    ),
    "translate_whole_build" => Dict{String,Any}(
        "impl" => "translate_whole_build!",
        "surface" => "scene_tree",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "zone_keys" => Dict{String,Any}(
                "type" => "array",
                "items" => Dict{String,Any}(
                    "type" => "string"
                )
            )
        ),
        "reversible" => true
    ),
    "apply_uniform_translation" => Dict{String,Any}(
        "impl" => "_apply_uniform_translation!",
        "surface" => "scene_tree",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "delta" => Dict{String,Any}(
                "type" => "array",
                "items" => Dict{String,Any}(
                    "type" => "number"
                ),
                "minItems" => 2,
                "maxItems" => 2
            )
        ),
        "reversible" => true
    ),
    "swap_battery" => Dict{String,Any}(
        "impl" => "swap_battery!",
        "surface" => "physical",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "agent" => Dict{String,Any}(
                "type" => "string"
            )
        ),
        "reversible" => false
    ),
    "dispatch_battery_courier" => Dict{String,Any}(
        "impl" => "dispatch_battery_courier!",
        "surface" => "physical",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "target" => Dict{String,Any}(
                "type" => "string"
            )
        ),
        "reversible" => true
    ),
    "replace_robot" => Dict{String,Any}(
        "impl" => "replace_robot!",
        "surface" => "sched",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "faulted" => Dict{String,Any}(
                "type" => "string"
            ),
            "spare" => Dict{String,Any}(
                "type" => "string"
            )
        ),
        "reversible" => false
    ),
    "hot_swap_robot" => Dict{String,Any}(
        "impl" => "hot_swap_robot!",
        "surface" => "scene_tree",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "faulted" => Dict{String,Any}(
                "type" => "string"
            ),
            "mode" => Dict{String,Any}(
                "type" => "string",
                "enum" => ["via_depot", "in_place"],
                "default" => "via_depot"
            )
        ),
        "reversible" => false
    ),
    "pop_spare" => Dict{String,Any}(
        "impl" => "pop_spare!",
        "surface" => "physical",
        "harness_args" => [],
        "params" => Dict{String,Any}(
            "pool" => Dict{String,Any}(
                "type" => "string"
            )
        ),
        "reversible" => false
    ),
    "compile_constraint" => Dict{String,Any}(
        "impl" => "compile_constraint!",
        "surface" => "milp",
        "harness_args" => ["model", "t0", "tF", "Xa", "sched"],
        "params" => Dict{String,Any}(
            "constraint_type" => Dict{String,Any}(
                "type" => "string",
                "enum" => ["ForbidWindow", "ForbidAgent", "LinearConstraint", "Disjunction"]
            )
        ),
        "reversible" => true
    ),
    "forbid_heavy_cargo" => Dict{String,Any}(
        "impl" => "forbid_heavy_cargo!",
        "surface" => "milp",
        "harness_args" => ["env"],
        "params" => Dict{String,Any}(
            "agent" => Dict{String,Any}(
                "type" => "string"
            ),
            "n" => Dict{String,Any}(
                "type" => "integer",
                "minimum" => 1,
                "maximum" => 3
            )
        ),
        "reversible" => false
    ),
)

"""
    seed_minted_fixture!(names...) -> Nothing

런-스코프 표를 **비우고** 지정한 이름들만 심는다. 이름을 안 주면 위 행 전부.

🔴 `reset_minted_table!()` 을 먼저 부른다 — 표는 프로세스 전역이고 `test/runtests.jl` 은
모든 시험 파일을 한 프로세스에 넣으므로, 앞 파일이 남긴 행이 뒤 파일의 픽스처가 되면
"단독으로는 초록, 스위트에서는 빨강"(이 레포가 이미 밟은 자리)이 반대 방향으로 난다.
"""
function seed_minted_fixture!(names::AbstractString...)
    ConstructionBots.reset_minted_table!()
    tbl = ConstructionBots.minted_table()
    keys_wanted = isempty(names) ? sort(collect(keys(MINTED_FIXTURE_ROWS))) : collect(names)
    for n in keys_wanted
        haskey(MINTED_FIXTURE_ROWS, n) ||
            error("픽스처에 없는 원시를 심으려 한다: $(n)")
        row = MINTED_FIXTURE_ROWS[n]
        tbl[n] = Dict{String,Any}("name" => n, row...)
    end
    return nothing
end

# =============================================================================
# 🔴 픽스처의 자기검사 (2026-09-03, Task 10 fix round 1 / F2)
#
# **왜 여기 있는가.** 옛 `test/minted_tool_enacts.jl` 명제 (12)(`REGISTRY_SURFACE_TODAY`)가
# 이름→impl 짝과 params 키를 못 박았고, 그 자리의 주석이 막으려던 사건을 **글자 그대로**
# 적어 두었다: "impl 을 다른 함수로 돌리거나 params 에 키를 더하면 스위트 전부 초록인 채로
# 부를 수 있는 표면이 넓어진다". (12) 는 삭제된 레지스트리 JSON 을 재고 있어서 은퇴시켰는데,
# **그 삭제와 같은 커밋이 이 공유 픽스처를 도입했다** — 그래서 오늘 이 표의 한 행이
# `"resolve_schedule_wedge" => impl "recover_stalled_teams!"` 로 조용히 바뀌어도 **시험 파일
# 셋이 동시에 초록**이다. 그 구멍을 여기서 닫는다.
#
# 🔴 재는 것은 JSON 이 아니라 **오늘 표에서 실제로 해석된 callable** 이다 — `resolve_primitive`
#    를 거쳐 `nameof(p.impl)` 을 되읽으므로, 문자열이 CB 의 어느 함수로 풀리는지까지 잰다.
# =============================================================================

#: 이름 → (impl 함수 이름, params 키 집합). 옛 (12) 의 `REGISTRY_SURFACE_TODAY` 를 그대로 옮겼다.
const FIXTURE_SURFACE = Dict{String,Tuple{String,Vector{String}}}(
    "apply_uniform_translation"   => ("_apply_uniform_translation!", ["delta"]),
    "compile_constraint"          => ("compile_constraint!", ["constraint_type"]),
    "deprioritize_agent"          => ("deprioritize_agent!", ["agent", "factor"]),
    "dispatch_battery_courier"    => ("dispatch_battery_courier!", ["target"]),
    "forbid_heavy_cargo"          => ("forbid_heavy_cargo!", ["agent", "n"]),
    "force_advance_stuck_carrier" => ("force_advance_stuck_carrier!", ["tol"]),
    "hot_swap_robot"              => ("hot_swap_robot!", ["faulted", "mode"]),
    "pop_spare"                   => ("pop_spare!", ["pool"]),
    "recover_stalled_teams"       => ("recover_stalled_teams!", String[]),
    "reform_stuck_teams"          => ("reform_stuck_teams!", ["min_ready", "snap_all"]),
    "release_pending_assignments" => ("release_pending_assignments!", ["faulted", "agent"]),
    "replace_robot"               => ("replace_robot!", ["faulted", "spare"]),
    "reset_slot_to_invalid"       => ("reset_slot_to_invalid!", ["slot_v"]),
    "resolve_schedule_wedge"      => ("resolve_schedule_wedge!", String[]),
    "restage_all_blocked"         => ("restage_all_blocked!", ["zone_keys"]),
    "restage_assembly"            => ("restage_assembly!", ["assembly_id", "zone_keys"]),
    "rethread_robot_ids"          => ("rethread_robot_ids!", String[]),
    "swap_battery"                => ("swap_battery!", ["agent"]),
    "translate_whole_build"       => ("translate_whole_build!", ["zone_keys"]),
)

"""
    check_minted_fixture()

씨 뿌린 표가 `FIXTURE_SURFACE` 와 어긋나지 않는지 확인하고, 어긋나면 **던진다.**

🔴 `@test` 가 아니라 `error(...)` 인 이유: 이 함수는 시험 파일의 `@testset` **밖**(모듈 최상위,
씨뿌리기 직후)에서 불린다. 픽스처가 오염된 채로 아래 절 수백 개가 도는 것보다, 그 자리에서
크게 죽는 편이 낫다 — 오염된 픽스처는 초록을 만들지 빨강을 만들지 예측할 수 없다.
`test/minted_tool_enacts.jl` 이 이 성질을 `@testset` 안에서도 한 번 더 잰다(음성 대조 포함).
"""
function check_minted_fixture()
    tbl = ConstructionBots.minted_table()
    got  = sort(collect(keys(tbl)))
    want = sort(collect(keys(FIXTURE_SURFACE)))
    got == want || error("픽스처 표의 이름 집합이 FIXTURE_SURFACE 와 다르다: " *
                         "빠짐=$(setdiff(want, got)) 남음=$(setdiff(got, want))")
    for (n, (impl, prms)) in FIXTURE_SURFACE
        p = ConstructionBots.resolve_primitive(n)
        p === nothing && error("픽스처가 $(n) 을 심지 못했다")
        # 🔴 문자열이 아니라 **CB 가 준 callable** 의 이름을 되읽는다.
        String(nameof(p.impl)) == impl ||
            error("이름→impl 짝이 어긋났다: $(n) → $(nameof(p.impl)) (기대 $(impl))")
        # params 키 = LLM 이 이 원시에 넘길 수 있는 손잡이 전부.
        sort(collect(keys(p.params))) == sort(prms) ||
            error("params 키가 어긋났다: $(n) → $(sort(collect(keys(p.params)))) (기대 $(sort(prms)))")
    end
    return nothing
end
