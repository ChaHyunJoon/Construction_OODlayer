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
