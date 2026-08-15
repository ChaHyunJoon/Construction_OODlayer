# oracle · canonical 실행 lane 신설 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 7개 OOD failure case 각각에 대해 `canonical` · `surrogate` · `LLM(dspy)` · `oracle` 네 컨트롤러의 **실제 시뮬레이션 결과**(빌드 진행도 · 완주까지 걸린 시간 · 배터리 효율)를 같은 스트림·같은 분모로 비교할 수 있게 만든다.

**Architecture:** 지금 실행 가능한 lane 은 `noop`/`surrogate`/`dspy` 셋뿐이다. (1) `canonical` 은 `policy.jl` 이 이미 지원하는데 스윕(`run_4pol.sh`)이 정책 목록에서 뺐을 뿐이므로 스윕 인자만 고치면 된다. (2) `oracle` 은 실행 분기 자체가 없다 — `reference_policy.py` 의 기준 행동 a\* 를 **결정 시점의 공개 상태로** 계산하는 Julia 쌍둥이 `oracle_macro(env, truth)` 를 `policy.jl` 에 새로 넣어 실행 가능한 5번째 lane 으로 만든다. 그 다음 두 lane 을 기존 `results_4pol/` 에 **덧붙여** 돌리고(파일 dedup 키가 `(case, ood_seed, policy)` 라 기존 3 lane 은 건드리지 않는다), 리포트 조립기가 5행 표를 내게 고친다.

**Tech Stack:** Julia 1.10 (`julia +lts --project=.`) · Python 3 (`/home/chahj578/Construction_OODlayer/.venv/bin/python`) · bash · DSPy 서비스(uvicorn, `DSPY_URL`)

---

## Global Constraints

프로젝트 전역 규칙. **모든 태스크의 요구사항에 암묵적으로 포함된다.**

- Julia 는 반드시 `julia +lts --project=.` — `Manifest.toml` 이 1.10.11 에 핀돼 있다.
- Python 은 반드시 `/home/chahj578/Construction_OODlayer/.venv/bin/python` (`run_4pol.sh` 의 `$PY` 와 같은 것).
- **비교 런은 순차 실행.** 다른 julia 프로세스와 동시에 돌리면 HiGHS 가 다른 스케줄을 내 비교가 무효가 되고, 프로세스당 ~2.5GB 라 OOM 이 난다 (`md/README.md` 함정 30). `run_4pol.sh` 의 게이트 P5 가 이걸 막는다 — 우회하지 말 것.
- 행동 어휘의 단일 진실원은 `wm4spacecraft_manufacturing/action_registry.json`. 매크로 이름을 코드에 리터럴로 복붙하지 말 것. 단 **이 계획이 추가하는 `oracle_macro` 는 예외** — `reference_policy.py` 의 규칙을 1:1 로 옮기는 것이므로 그 파일과 같은 문자열을 쓴다(그 사실을 주석에 적는다). 검증은 Task 7 의 교차검사가 한다.
- 스윕 설정은 기존 행과 **한 글자도 바꾸지 않는다**: `model=tractor.mpd` · `robots=10` · `world_seed=1` · `ood_seed=1,2,3,4,5` · `events=4` · `spares=3` · `sev_frac=0.5` · `bsoc=0.9` · `router=0` · `LLM_NL_MODE=observation` · `DEMO_OOD_STREAM3=1`. 이 중 하나라도 다르면 새 lane 이 다른 세계에서 측정돼 같은 표에 넣을 수 없다.
- 7 case (실행 순서 그대로): `battery, fault, all, fault_battery, fault_zone, battery_zone, zone`. `zonecore` 는 **넣지 않는다** — `run_demo.jl:433` 이 `DEMO_OOD_STREAM3=1` 에서 `:zonecore` 를 `:zone` 으로 바꾸므로 `zone` 과 같은 실험이다.
- `results_4pol/*.jsonl` 는 append-only. `llm_ood_eval.py:load_rows` 가 `(case, ood_seed, policy)` 로 dedup 하므로 새 정책을 덧붙여도 기존 행은 안전하다. **기존 파일을 지우거나 덮어쓰지 말 것.**
- `artifacts_4pol/` 는 언제든 재생성 가능한 산출물이다. `baseline_n5/` 는 **이번 변경 이전의 동결본**이므로 절대 건드리지 않는다.
- 결측은 0 도 빈칸도 아니다 — `미측정` 으로 명시한다 (`build_final_table.py` 상단 ★ 규칙).

---

## File Structure

**수정:**

| 파일 | 책임 | 이 계획에서 하는 일 |
|---|---|---|
| `tools/monitor/policy.jl` | 결정 정책 레이어 (run_demo/render_demo 공용) | `oracle_macro` 신설 + `decide_all` 에 `pol["oracle"]` 배선 |
| `wm4spacecraft_manufacturing/llm_ood_eval.py` | 판 실행기 + 리포트 | `oracle` 정책 인지, 표 순서 |
| `wm4spacecraft_manufacturing/run_4pol.sh` | 무인 스윕 바깥루프 | `--policies` 인자, 정책별 행 수 세기 |
| `wm4spacecraft_manufacturing/build_final_table.py` | FINAL.md 조립 + 짝검정 | 천장행/oracle행 분리, `PAIRS` 기계화 |
| `wm4spacecraft_manufacturing/build_md_report.py` | REPORT.md 조립 | 헤드라인 표 산문 |
| `wm4spacecraft_manufacturing/shadow_score.py` | 상태조건부 결정 shadow | oracle 판 제외 옵션 |

**신설:**

| 파일 | 책임 |
|---|---|
| `tools/test_policy_oracle.jl` | `oracle_macro` 의 세 축 규칙 자기점검 (서비스·렌더 없이) |
| `wm4spacecraft_manufacturing/test_oracle_lane.py` | **교차언어 계약**: 스윕 산출물에서 oracle lane 의 결정정확도가 1.0 인지 검사 = Julia 쌍둥이가 Python a\* 와 같은지 |

---

## Task 1: Julia 쪽 기준행동 `oracle_macro`

**Files:**
- Modify: `tools/monitor/policy.jl:12` (ENV 독스트링), `tools/monitor/policy.jl:451` 뒤에 함수 삽입
- Test: `tools/test_policy_oracle.jl` (신규)

**Interfaces:**
- Consumes: `valid_macros(env, truth)` · `_agent_pending(env, agent)` · `canonical_macro(env, truth)` — 전부 `policy.jl` 안에 이미 있다. `CB.zone_diagnosis(env, zonekey)` (NamedTuple, 필드 `exists`/`n_nav_goals`/`n_nav_blocked`/`root_covered`).
- Produces: `oracle_macro(env, truth) -> String` — 매크로 이름 하나. Task 2 가 쓴다.

**배경 — 왜 Julia 로 다시 쓰는가.** `reference_policy.py` 의 a\* 는 지금 **사후 채점기**다: 판이 끝난 뒤 `decisions[]` 를 읽어 "골랐어야 할 팔"을 말한다. 실행 lane 이 되려면 같은 판단을 **결정 순간에** 내려야 하고, 그 시점 상태는 Julia 쪽에만 있다. 그래서 규칙을 옮겨 적되, 두 구현이 갈리지 않는다는 것은 Task 7 이 실측으로 검사한다(같은 사건에서 Julia 가 고른 팔 == Python 이 채점한 a\*).

**a\* 규칙 (출처: `wm4spacecraft_manufacturing/reference_policy.py`):**

| 축 | 조건 | a\* |
|---|---|---|
| battery | `soc <= 0.2` (깊은 방전) | `SwapBattery`, 메뉴에 없으면 `Replace` |
| battery | 그 외 | `NOOP` |
| fault | `agent_pending > 0` | `Replace` |
| fault | `agent_pending == 0` | `NOOP` |
| zone | `n_nav_blocked > 0` **그리고** `root_covered == 0` | `RelocateBuild`, 메뉴에 없으면 `ForbidZone` |
| zone | 그 외 | `NOOP` |
| reform | 실측 격자 없음 → a\* 미정의 | `canonical` 에 위임 |

reform 위임이 왜 옳은가: `reference_policy.reference_action` 은 reform 사건에 `None` 을 돌려주고 그 사건은 **채점에서 빠진다**(unscored). 그런데 실행 lane 은 무언가를 해야 한다. 없는 정답을 지어내는 대신 기준선(canonical)이 하는 일을 그대로 하고, 그 사실을 rationale 에 남긴다. 필수 상태 필드가 결측일 때도 같다 — Python 이 unscored 로 빼는 자리와 Julia 가 canonical 로 떨어지는 자리가 정확히 일치하므로 Task 7 의 교차검사가 성립한다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`tools/test_policy_oracle.jl` 생성. `tools/test_policy_zone.jl` 의 부트스트랩(빠른 기하 env 구성)을 그대로 따르되 검사 대상만 바꾼다.

```julia
# tools/test_policy_oracle.jl
# =============================================================================
# `policy.jl` 의 oracle lane 자기점검 (2026-08-11).
#
# 왜 이 파일이 필요한가
# ---------------------
# oracle lane 은 `wm4spacecraft_manufacturing/reference_policy.py` 의 기준 행동 a* 를 **결정
# 시점에** 다시 계산한다. 두 구현이 갈리면 표의 `oracle` 행은 "a* 를 집행했다"는 이름을 달고
# 다른 것을 집행하게 된다 -- 그 어긋남은 에러 없이 결과로만 샌다. 여기서는 서비스도 렌더도 없이
# 세 축의 분기를 초 단위로 대조한다. (실판에서의 교차검사는 test_oracle_lane.py 가 한다.)
#
# 실행:  julia +lts --project=. tools/test_policy_oracle.jl
# =============================================================================
using ConstructionBots
import HiGHS, Logging, Graphs
const CB = ConstructionBots

npass = 0; nfail = 0
function check(name, ok, detail = "")
    global npass, nfail
    ok ? (npass += 1) : (nfail += 1)
    println("  [", ok ? "PASS" : "FAIL", "] ", name, isempty(detail) ? "" : "  -- " * detail)
end

CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
ENV["DEMO_ROUTER"] = "0"
include(joinpath(@__DIR__, "monitor", "policy.jl"))

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
                                          "output_flag" => false, "presolve" => "on")

println(">>> building fast geometry env (tractor, rvo off)...")
pp = CB.get_project_params(4)
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end

println("\n== 1. battery 축 -- 깊은 방전(SoC<=0.2)만 개입, 그 외는 NOOP ==")
# 배터리 레이어가 없으면 valid_macros 가 SwapBattery 를 빼므로 두 갈래를 다 확인한다.
have_fleet = (try CB.BATTERY_FLEET[] !== nothing catch; false end)
println("    BATTERY_FLEET 설치됨 = $(have_fleet)")
t_deep = CB.BatteryTruth(CB.RobotID(1), 0.02)
t_mild = CB.BatteryTruth(CB.RobotID(1), 0.50)
m_deep = oracle_macro(env, t_deep)
check("깊은 방전 -> 충전을 되살리는 팔",
      m_deep == (have_fleet ? "SwapBattery" : "Replace"), "got=$(m_deep)")
check("경미한 저하 -> NOOP", oracle_macro(env, t_mild) == "NOOP",
      "got=$(oracle_macro(env, t_mild))")
check("경계값 SoC=0.2 는 '깊은 방전' 쪽(<=)",
      oracle_macro(env, CB.BatteryTruth(CB.RobotID(1), 0.2)) != "NOOP")

println("\n== 2. fault 축 -- 일을 지고 있었는가로 갈린다 ==")
# _agent_pending 은 env 의 스케줄을 읽는다. 시뮬 전 env 라 로봇 1은 아직 운반 투입 작업을 진다.
pend1 = _agent_pending(env, CB.RobotID(1))
println("    RobotID(1) agent_pending = $(pend1)")
check("사전조건: 시뮬 전 env 에서 로봇 1은 일감을 지고 있다", pend1 > 0)
check("일감 있는 로봇 고장 -> Replace",
      oracle_macro(env, CB.FaultTruth(CB.RobotID(1), [0.0, 0.0])) == "Replace",
      "got=$(oracle_macro(env, CB.FaultTruth(CB.RobotID(1), [0.0, 0.0])))")

println("\n== 3. zone 축 -- 막힘>0 '그리고' root 하역목표 0 일 때만 개입 ==")
gs = CB.root_deposit_goals(env)
zc = isempty(gs) ? [1.5, 0.96] : sum(gs) ./ length(gs)
CB.clear_restriction_zones!()
CB.add_restriction_zone!(:faraway, [500.0, 500.0], 1.0)   # 아무것도 안 덮는 구역
t_far = CB.ZoneTruth(:faraway, [500.0, 500.0], 1.0, nothing)
zdg_far = CB.zone_diagnosis(env, :faraway)
println("    :faraway -> nav_blocked=$(zdg_far.n_nav_blocked) root_covered=$(zdg_far.root_covered)")
check("아무것도 막지 않는 구역 -> NOOP", oracle_macro(env, t_far) == "NOOP",
      "got=$(oracle_macro(env, t_far))")

println("\n== 4. reform 축 -- 실측 격자가 없으므로 canonical 에 위임 ==")
t_reform = CB.ReformTruth()
check("reform -> canonical 과 같은 답",
      oracle_macro(env, t_reform) == canonical_macro(env, t_reform),
      "oracle=$(oracle_macro(env, t_reform)) canonical=$(canonical_macro(env, t_reform))")

println("\n== 5. 고른 팔은 언제나 그 사건의 메뉴 안에 있다 ==")
for (nm, t) in (("battery-deep", t_deep), ("battery-mild", t_mild),
                ("fault", CB.FaultTruth(CB.RobotID(1), [0.0, 0.0])), ("zone-far", t_far))
    local vm = valid_macros(env, t)
    local m = oracle_macro(env, t)
    check("$(nm): 고른 팔이 메뉴 안", isempty(vm) || m in vm, "chose=$(m) menu=$(vm)")
end

CB.clear_restriction_zones!()
println("\n==== policy oracle lane: $(npass) passed, $(nfail) failed ====")
println(nfail == 0 ? "ALL GREEN" : "SOME FAILED")
exit(nfail == 0 ? 0 : 1)
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. tools/test_policy_oracle.jl`
Expected: FAIL — `UndefVarError: oracle_macro not defined` (env 를 짓는 데 1~2분 걸린 뒤 나온다)

- [ ] **Step 3: `oracle_macro` 를 구현한다**

`tools/monitor/policy.jl` 의 `canonical_macro(env, truth)` 정의가 끝나는 줄(451, `end`) **바로 뒤**, `# ---- 통제 실험용 강제 매크로 ----` 주석(453) **앞**에 삽입한다.

```julia

# ---- oracle lane: 기준 행동 a* 의 실행판 (2026-08-11) -----------------------------------
# `wm4spacecraft_manufacturing/reference_policy.py` 의 a* 규칙을 **결정 시점**에 계산한 것.
# 저쪽은 판이 끝난 뒤 decisions[] 를 읽는 사후 채점기라 실행 lane 이 될 수 없다. 두 구현이 갈리면
# 표의 `oracle` 행이 "a* 를 집행했다"는 이름으로 다른 것을 집행하게 되므로, 매크로 이름 문자열은
# 일부러 reference_policy.py 와 **같은 리터럴**을 쓴다(레지스트리 경유 금지 -- 경유하면 두 파일이
# 다른 이름 체계를 쓰게 된다). 두 구현의 일치는 실판에서 test_oracle_lane.py 가 검사한다.
#
# 값이 결측이면 canonical 로 떨어진다. reference_policy 는 같은 자리에서 a*=None(unscored)을
# 내므로, "Julia 가 위임한 사건" 과 "Python 이 채점에서 뺀 사건" 이 정확히 겹친다 -- 그래야
# test_oracle_lane.py 의 "채점된 사건에서 oracle 정확도 100%" 계약이 성립한다.
const ORACLE_BATTERY_DEEP_SOC = 0.2      # = reference_policy.BATTERY_DEEP_SOC

function oracle_macro(env, truth)
    vm = valid_macros(env, truth)
    if truth isa CB.BatteryTruth
        local soc = try Float64(truth.soc_after) catch; nothing end
        soc === nothing && return canonical_macro(env, truth)
        # 깊은 방전 = 개입하지 않으면 그 로봇은 죽는다. 충전을 되살리는 두 팔은 결과가 같으므로
        # (battgrid 실측: 둘 다 closed 291) 싼 쪽 SwapBattery(0.2) < Replace(1.0) 이 정답이다.
        soc <= ORACLE_BATTERY_DEEP_SOC && return ("SwapBattery" in vm ? "SwapBattery" : "Replace")
        return "NOOP"                    # 경미한 저하: 어느 팔이든 완주하므로 공짜인 것이 이긴다
    elseif truth isa CB.FaultTruth
        local pend = try _agent_pending(env, truth.robot) catch; -1 end
        pend < 0 && return canonical_macro(env, truth)
        # firegrid 실측은 완전 분리다(24/24, 18/18): "고장났으니 교체" 가 아니라 **일을 지고
        # 있었는가** 가 가른다.
        return pend > 0 ? "Replace" : "NOOP"
    elseif truth isa CB.ZoneTruth
        local zdg = try CB.zone_diagnosis(env, truth.zone) catch; nothing end
        (zdg === nothing || !zdg.exists || zdg.n_nav_goals < 0) &&
            return canonical_macro(env, truth)
        # 막힌 것이 **항법 목표**이고 root 하역목표는 안 걸렸을 때만 전역 이동이 값을 한다
        # (zcausal_reform STEP 10: blk 279 완주 vs NOOP 254 정지 / cov 는 반대로 뒤집힌다).
        # 막힘>0 하나만 보는 규칙은 2사건 중 1개만 맞는다.
        (zdg.n_nav_blocked > 0 && zdg.root_covered == 0) &&
            return ("RelocateBuild" in vm ? "RelocateBuild" : "ForbidZone")
        return "NOOP"
    end
    # reform: 실측 격자가 없어 a* 가 미정의다(reference_policy 는 unscored 로 뺀다). 없는 정답을
    # 지어내는 대신 기준선이 하는 일을 그대로 한다.
    return canonical_macro(env, truth)
end
```

- [ ] **Step 4: 테스트 통과를 확인한다**

Run: `julia +lts --project=. tools/test_policy_oracle.jl`
Expected: `ALL GREEN`, exit 0

- [ ] **Step 5: 커밋**

```bash
git add tools/monitor/policy.jl tools/test_policy_oracle.jl
git commit -m "feat(policy): oracle_macro -- reference_policy.py 의 a* 를 결정시점에 계산"
```

---

## Task 2: `decide_all` 에 oracle lane 배선

**Files:**
- Modify: `tools/monitor/policy.jl:12` · `tools/monitor/policy.jl:484-493`
- Test: `tools/test_policy_oracle.jl` (Task 1 의 파일에 절 추가)

**Interfaces:**
- Consumes: `oracle_macro(env, truth)` (Task 1)
- Produces: `decide_all(...).policies["oracle"]` — `Dict("chosen"=>String, "ranking"=>Vector{String}, "margin"=>nothing, "rationale"=>String, "label"=>"oracle", "available"=>true)`. `DEMO_POLICY=oracle` 로 돌리면 `enacted == "oracle"`.

**왜 이렇게 배선하는가.** `decide_all` 은 매 사건마다 모든 정책의 답을 `pol` 에 채워 두고, 실제 실행은 `POLICY`(=`DEMO_POLICY`)가 고른 하나만 한다(`policy.jl:520`). 그래서 `pol["oracle"]` 을 채우기만 하면 `DEMO_POLICY=oracle` 이 바로 동작한다. 단 **후보표·verdict 의 "다른 정책은 뭐라 했나" 목록에는 oracle 을 넣지 않는다**(`policy.jl:645/660/662` 의 `("canonical","surrogate","dspy")` 튜플 3곳은 그대로 둔다) — 넣으면 canonical/surrogate/dspy 판의 화면과 스트림에 정답이 상시 노출돼, 사람이 보는 기록이 "정답을 알고 있었는데 틀렸다"로 읽힌다. oracle 은 비교 대상이지 참고 표시가 아니다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`tools/test_policy_oracle.jl` 의 `CB.clear_restriction_zones!()` (마지막 요약 출력 직전) **앞**에 절을 추가한다.

```julia
println("\n== 6. decide_all 배선 -- pol[\"oracle\"] 이 채워지고 표시 튜플엔 안 샌다 ==")
# 서비스가 없어도 돌아야 한다: DEMO_ALL_POLICIES=0 이면 dspy/surrogate 를 아예 안 부른다.
withenv("DEMO_ALL_POLICIES" => "0") do
    local d = decide_all(env, t_deep; nl = "")
    check("policies 에 oracle 키가 있다", haskey(d.policies, "oracle"))
    check("oracle 은 언제나 available", get(get(d.policies, "oracle", Dict()), "available", false))
    check("oracle 의 chosen == oracle_macro",
          get(get(d.policies, "oracle", Dict()), "chosen", "") == oracle_macro(env, t_deep))
    # 정답 누출 검사: 후보표/verdict 어디에도 oracle 이라는 출처가 찍히면 안 된다.
    check("후보표 by 필드에 oracle 이 없다",
          all(c -> !occursin("oracle", String(get(c, "by", ""))), d.candidates),
          "cands=$(d.candidates)")
    check("verdict 에 oracle 이 없다", !occursin("oracle", lowercase(d.verdict)),
          "verdict=$(d.verdict)")
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. tools/test_policy_oracle.jl`
Expected: FAIL — `policies 에 oracle 키가 있다` 부터 실패

- [ ] **Step 3: 배선을 구현한다**

(a) `tools/monitor/policy.jl:484-487` 의 `pol["noop"]` 블록 **바로 뒤**에 삽입:

```julia
    # a* 집행 lane (2026-08-11). "천장을 정말 달릴 수 있었나"를 재는 다섯 번째 주자다.
    # 주의: 이 lane 의 **결정정확도는 정의상 100%** 라 정보가 없다 -- 정보가 있는 것은 그 결정을
    # 실제로 집행했을 때의 완주율·빌드시간·에너지다. 리포트가 그렇게 읽히게 적어야 한다.
    pol["oracle"] = Dict("chosen" => oracle_macro(env, truth), "ranking" => String[],
                         "margin" => nothing,
                         "rationale" => "reference action a* (measured grids; see reference_policy.py)",
                         "label" => "oracle", "available" => true)
    pol["oracle"]["ranking"] = [pol["oracle"]["chosen"]]
```

(b) `tools/monitor/policy.jl:491` 의 서비스 생략 조건에 `"oracle"` 을 더한다 — oracle 은 canonical 과 마찬가지로 DSPy 서비스가 없어도 결정을 낼 수 있어야 한다:

```julia
    j = (POLICY in ("canonical", "noop", "oracle") && !get(rt, "enabled", false) &&
         get(ENV, "DEMO_ALL_POLICIES", "1") == "0") ?
        nothing : service_decide(env, truth; nl = nl, descriptors = desc)
```

(c) `tools/monitor/policy.jl:12` 의 ENV 독스트링을 고친다:

```julia
# ENV: DEMO_POLICY(canonical|noop|oracle|surrogate|dspy) · DSPY_URL · DEMO_ALL_POLICIES(0 이면 비교값 수집 생략)
```

같은 파일 6-8행의 정책 목록 주석에도 한 줄 더한다:

```julia
#   oracle    : reference_policy.py 의 기준행동 a* 를 결정시점에 재계산해 집행(비교용 상한 lane)
```

- [ ] **Step 4: 테스트 통과를 확인한다**

Run: `julia +lts --project=. tools/test_policy_oracle.jl`
Expected: `ALL GREEN`, exit 0

- [ ] **Step 5: 기존 정책 배선이 안 깨졌는지 확인한다**

Run: `julia +lts --project=. tools/test_policy_zone.jl`
Expected: `ALL GREEN` (Task 1·2 는 zone 어휘를 안 건드렸으므로 그대로여야 한다)

- [ ] **Step 6: 커밋**

```bash
git add tools/monitor/policy.jl tools/test_policy_oracle.jl
git commit -m "feat(policy): DEMO_POLICY=oracle 실행 lane 배선 (후보표엔 노출 안 함)"
```

---

## Task 3: `llm_ood_eval.py` 가 oracle/canonical 을 1등 시민으로 다루게

**Files:**
- Modify: `wm4spacecraft_manufacturing/llm_ood_eval.py:80-84` · `:425-426` · `:490`
- Test: 기존 파일에 인라인 검사 없음 → Task 4 의 스모크가 겸한다

**Interfaces:**
- Consumes: `DEMO_POLICY=oracle` 를 받는 `policy.jl` (Task 2)
- Produces: `python llm_ood_eval.py run --policies canonical,oracle ...` 이 도는 것. 리포트 표의 정책 행 순서 `noop → canonical → surrogate → dspy → oracle`.

- [ ] **Step 1: 라우터 안전장치에 oracle 을 더한다**

`llm_ood_eval.py:80-84` 의 검사를 고친다. `noop` 과 같은 이유다 — `oracle` 은 라우터가 고를 수 있는 target 이 아니고(`ROUTER_ENGAGED_TARGETS = {"surrogate","dspy"}`), a\* 를 집행하는 대조 lane 이라 라우팅과 양립하지 않는다.

```python
    policies = [s.strip() for s in args.policies.split(",") if s.strip()]
    unroutable = [p for p in policies if p in ("noop", "oracle")]
    if unroutable:
        return ("--router %s 와 --policies 의 %s 는 같이 쓸 수 없다 "
                "(policy.jl:332 가 POLICY==noop 에서 라우팅을 끄고, oracle 은 라우터가 고를 수 "
                "있는 target 이 아니다 -- 둘 다 통제 대조 lane 이다)"
                % (args.router, "/".join(unroutable)))
    return None
```

같은 함수의 독스트링에서 `noop` 만 언급한 항목을 다음으로 바꾼다:

```
    - `--policies` 에 noop/oracle 이 섞여 있으면: 둘 다 통제 실험의 대조 lane 이라 라우터
      옵트인과 양립 불가. noop 은 policy.jl:332 가 라우팅 자체를 끄고, oracle 은 a* 를 집행하는
      상한 lane 이라 "낯설면 LLM" 같은 라우팅 대상이 아니다.
```

- [ ] **Step 2: 리포트 표 순서를 고친다**

`llm_ood_eval.py:425-426`:

```python
        _ORDER = ("noop", "canonical", "surrogate", "dspy", "oracle")
        order = [p for p in _ORDER if p in res] + [p for p in res if p not in _ORDER]
```

- [ ] **Step 3: `--policies` 기본값을 실제로 도는 집합으로 고친다**

`llm_ood_eval.py:490`:

```python
    r.add_argument("--policies", default="noop,canonical,surrogate,dspy,oracle")
```

- [ ] **Step 4: 인자 파싱과 라우터 게이트가 도는지 확인한다** (시뮬 없음)

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python llm_ood_eval.py run \
    --router 1 --policies canonical,oracle --seeds 1 --case fault
```
Expected: `ERROR: --router 1 와 --policies 의 oracle 는 같이 쓸 수 없다 ...` 로 즉시 종료(exit 1). 시뮬은 한 판도 돌지 않는다.

- [ ] **Step 5: 커밋**

```bash
git add wm4spacecraft_manufacturing/llm_ood_eval.py
git commit -m "feat(eval): oracle/canonical lane 인지 -- 라우터 배제, 표 순서, 기본 정책집합"
```

---

## Task 4: `run_4pol.sh` 가 정책 부분집합을 덧붙여 돌 수 있게

**Files:**
- Modify: `wm4spacecraft_manufacturing/run_4pol.sh:34` · `:63` · `:80-87` · `:196` · `:199-206`

**Interfaces:**
- Consumes: Task 3 의 `llm_ood_eval.py`
- Produces: `bash run_4pol.sh --resume --policies canonical,oracle --deadline-seconds N` 이 기존 `results_4pol/*.jsonl` 에 두 lane 만 **덧붙인다**.

**왜 필요한가.** 지금 스크립트는 정책 목록이 `POLICIES="noop,surrogate,dspy"` 로 박혀 있고, `EXPECTED_ROWS` 와 `EST_COST` 가 `N_SEEDS * 3` 을 리터럴로 쓰며, `count_rows` 는 파일 전체 줄 수를 센다. 이대로 5정책으로 바꾸면 `--resume` 이 기존 15행을 25행 미만으로 보고 **case 전체(125판)를 다시 돌린다** — 이미 있는 3 lane 을 헛되이 재실행하고, 새 스트림이 옛 행을 dedup 으로 덮어써 지금까지의 측정과 갈린다. 그래서 "요청한 정책의 행만 센다" 로 바꾼다.

- [ ] **Step 1: `--policies` 인자와 검증을 더한다**

`run_4pol.sh:34` 의 `POLICIES="noop,surrogate,dspy"` 를 그대로 **기본값**으로 두고, 인자 루프(37-53행)에 분기를 추가한다:

```bash
        --policies)
            POLICIES="$2"; shift 2 ;;
```

인자 루프가 끝난 직후(`IFS=',' read -r -a SEED_ARR <<< "$SEEDS"` 앞)에 검증을 넣는다:

```bash
# ---- 정책 목록 검증. 오타는 julia 가 조용히 canonical 로 폴백시키므로 여기서 잡아야 한다
# (policy.jl:523 -- 모르는 POLICY 는 pol 에 없어서 canonical 로 떨어지고, 그 판은 이름만 다른
# canonical 판이 된다. 에러 없이 결과로만 새는 종류의 실패다).
IFS=',' read -r -a POLICY_ARR <<< "$POLICIES"
N_POLICIES=${#POLICY_ARR[@]}
for p in "${POLICY_ARR[@]}"; do
    case "$p" in
        noop|canonical|surrogate|dspy|oracle) ;;
        *) echo "[error] 알 수 없는 정책: $p (noop|canonical|surrogate|dspy|oracle)" >&2; exit 1 ;;
    esac
done
```

- [ ] **Step 2: 행 수 기대값을 정책 수로 계산한다**

`run_4pol.sh:63` 의

```bash
EXPECTED_ROWS=$(( N_SEEDS * 3 ))
```
를

```bash
EXPECTED_ROWS=$(( N_SEEDS * N_POLICIES ))
```
로 바꾼다. (`N_POLICIES` 는 Step 1 에서 정의되며 이 줄보다 앞이어야 한다 — 검증 블록을 `IFS=',' read ... SEED_ARR` **앞**에 두면 순서가 맞는다.)

`run_4pol.sh:196` 의

```bash
    EST_COST=$(( UNIT_PRICE * N_SEEDS * 3 ))
```
를

```bash
    EST_COST=$(( UNIT_PRICE * N_SEEDS * N_POLICIES ))
```
로 바꾼다.

- [ ] **Step 3: 행 세기를 정책별로 바꾼다**

`run_4pol.sh:80-87` 의 `count_rows` 를 통째로 교체한다:

```bash
# 요청한 정책의 행만 센다. 파일 전체 줄 수를 세면 정책 부분집합을 덧붙이는 두 번째 패스에서
# --resume 이 "이미 다 있다"고 잘못 판단하거나(옛 3 lane 15행 >= 새 기대값 10행) 반대로 case
# 전체를 재실행한다. 어느 쪽이든 조용히 틀린다.
count_rows() {
    local f="$1"
    [ -f "$f" ] || { echo 0; return; }
    "$PY" - "$f" "$POLICIES" <<'PYEOF'
import json, sys
path, pols = sys.argv[1], set(s.strip() for s in sys.argv[2].split(",") if s.strip())
seen = set()
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("policy") in pols:
            # llm_ood_eval.load_rows 와 같은 dedup 키. 재실행분을 두 번 세면 안 된다.
            seen.add((r.get("case"), r.get("ood_seed"), r.get("policy")))
print(len(seen))
PYEOF
}
```

- [ ] **Step 4: 재개 주석을 사실에 맞게 고친다**

`run_4pol.sh:199-200` 의 주석을 바꾼다:

```bash
    # R4 -- resume: 요청한 정책의 행이 이미 n_seeds x n_policies 개면 다시 돌리지 않는다.
    # 데드라인보다 먼저 본다(재개된 case 는 남은 시간과 무관하게 재개다).
```

- [ ] **Step 5: 스모크 — 한 case · 한 시드 · 두 lane 만 실제로 돌려 본다**

먼저 DSPy 서비스가 떠 있어야 한다(게이트 P1/P2). 서비스 기동은 `md/RESULTS_LLM7H.md` §4 의 절차를 따른다. 그 다음:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
bash run_4pol.sh --resume --policies canonical,oracle --seeds 1 --cases fault \
     --deadline-seconds 1800
```
Expected: 게이트 P1~P6 전부 OK → `=== [fault] 시작 ===` → `STATUS 4pol fault ok rows=2` → `ALL non-skipped cases ok.` (exit 0). 2판(canonical/oracle × seed 1) 만 돈다.

- [ ] **Step 6: 기존 3 lane 이 무사한지 확인한다**

```bash
/home/chahj578/Construction_OODlayer/.venv/bin/python - <<'PY'
import json, collections
rows = [json.loads(l) for l in open("results_4pol/fault.jsonl")]
d = {}
for r in rows:
    d[(r["case"], r["ood_seed"], r["policy"])] = r
print(collections.Counter(k[2] for k in d))
print("noop/s1 closed =", d[("fault", 1, "noop")]["closed"], "(기대 176)")
PY
```
Expected: `noop`, `surrogate`, `dspy` 각 5개 + `canonical`, `oracle` 각 1개. `noop/s1 closed = 176` — 기존 행이 그대로다.

- [ ] **Step 7: 커밋**

```bash
git add wm4spacecraft_manufacturing/run_4pol.sh
git commit -m "feat(sweep): run_4pol.sh --policies -- 정책 부분집합을 기존 결과에 덧붙여 실행"
```

---

## Task 5: oracle lane 교차언어 계약 테스트

**Files:**
- Create: `wm4spacecraft_manufacturing/test_oracle_lane.py`

**Interfaces:**
- Consumes: `results_4pol/{case}.jsonl` (Task 4 의 스모크가 만든 `fault.jsonl` 로 먼저 검증) · `reference_policy.score`
- Produces: `python test_oracle_lane.py [results_dir]` → exit 0/1. Task 8 이 스윕 후 다시 부른다.

**이 테스트가 유일하게 잡는 것.** Julia 의 `oracle_macro` 와 Python 의 `reference_policy.reference_action` 이 갈리면 아무 에러도 안 난다 — 표의 `oracle` 행이 조용히 다른 정책이 된다. 채점된 사건에서 oracle lane 의 결정정확도는 **정의상 정확히 1.0** 이어야 하고, 1.0 이 아니면 그 차이가 곧 두 구현의 불일치다. (그래서 이 행의 "옳은 결정" 열은 성능 지표가 아니라 **자기검사 계기판**이다 — 리포트에도 그렇게 적는다.)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

```python
#!/usr/bin/env python3
"""test_oracle_lane.py -- oracle lane 의 교차언어 계약.

`tools/monitor/policy.jl:oracle_macro` (Julia, 결정 시점) 와 `reference_policy.reference_action`
(Python, 사후 채점) 은 같은 규칙의 두 구현이다. 갈리면 에러 없이 **결과로만** 샌다: 표의
`oracle` 행이 "a* 를 집행했다"는 이름을 달고 다른 것을 집행하게 된다.

계약: 채점된(a* 가 정의된) 사건에서 oracle lane 이 고른 매크로는 **언제나** a* 와 같다.
불일치가 하나라도 있으면 그 사건을 전부 출력하고 실패한다 -- 어느 축의 어느 분기가 갈렸는지
바로 보이게.

  python test_oracle_lane.py [results_dir]     # 기본 results_4pol
"""
import json
import sys
from pathlib import Path

import reference_policy

HERE = Path(__file__).resolve().parent


def load_boards(results_dir: Path):
    """(case, ood_seed, policy) dedup. llm_ood_eval.load_rows 와 같은 규칙."""
    dedup = {}
    for path in sorted(results_dir.glob("*.jsonl")):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                dedup[(r.get("case"), r.get("ood_seed"), r.get("policy"))] = r
    return dedup


def main(argv):
    results_dir = Path(argv[1]) if len(argv) > 1 else (HERE / "results_4pol")
    if not results_dir.is_dir():
        print("FAIL  결과 디렉터리가 없다: %s" % results_dir)
        return 1
    boards = load_boards(results_dir)
    oracle = {k: v for k, v in boards.items() if k[2] == "oracle"}
    if not oracle:
        print("FAIL  oracle 판이 하나도 없다 (%s) -- 스윕을 먼저 돌릴 것" % results_dir)
        return 1

    n_scored = n_correct = 0
    mismatches = []
    for (case, seed, _pol), row in sorted(oracle.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        decisions = row.get("decisions") or []
        _s, _c, rows = reference_policy.score(decisions)
        for ev, r in zip(decisions, rows):
            if r["correct"] is None:
                continue                      # a* 미정의 = 계약 밖(Julia 는 canonical 로 위임)
            n_scored += 1
            if r["correct"]:
                n_correct += 1
            else:
                mismatches.append(dict(case=case, seed=seed, truth=r["truth"], at=r["at"],
                                       julia=r["chosen"], python=r["reference"],
                                       basis=r["basis"], note=r["note"],
                                       valid=ev.get("valid"), soc=ev.get("soc"),
                                       agent_pending=ev.get("agent_pending"),
                                       zone_primitives=ev.get("zone_primitives")))

    print("oracle 판 %d개 · 채점된 결정 %d건 · 일치 %d건" % (len(oracle), n_scored, n_correct))
    if n_scored == 0:
        print("FAIL  채점된 결정이 0건이다 -- 계약을 검사할 수 없다(전부 unscored?)")
        return 1
    if mismatches:
        print("FAIL  Julia oracle_macro 와 Python reference_action 이 %d건 갈렸다:" % len(mismatches))
        for m in mismatches:
            print("  %s/s%s @closed=%s  %s: julia=%s python=%s"
                  % (m["case"], m["seed"], m["at"], m["truth"], m["julia"], m["python"]))
            print("      basis=%s note=%s" % (m["basis"], m["note"]))
            print("      valid=%s soc=%s agent_pending=%s zone=%s"
                  % (m["valid"], m["soc"], m["agent_pending"], m["zone_primitives"]))
        return 1
    print("PASS  oracle lane 은 채점된 모든 사건에서 a* 를 집행했다 (%d/%d)" % (n_correct, n_scored))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 2: Task 4 의 스모크 산출물로 돌린다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_oracle_lane.py
```
Expected: `PASS  oracle lane 은 채점된 모든 사건에서 a* 를 집행했다 (n/n)`, exit 0.

**FAIL 이 나면 여기서 멈춘다.** 출력에 어느 축의 어느 분기가 갈렸는지 다 찍혀 있다 — Task 1 의 `oracle_macro` 를 고치고 Task 4 Step 5 의 스모크부터 다시 돈다. 이 계약이 깨진 채로 3.9시간짜리 스윕에 들어가면 안 된다.

- [ ] **Step 3: 커밋**

```bash
git add wm4spacecraft_manufacturing/test_oracle_lane.py
git commit -m "test(oracle): Julia oracle_macro 와 Python reference_action 의 교차언어 계약"
```

---

## Task 6: 리포트 조립기 — 천장행과 oracle lane 을 분리

**Files:**
- Modify: `wm4spacecraft_manufacturing/build_final_table.py:15-17` · `:52-53` · `:196` · `:253-255` · `:480-485` · `:509-542` · `:645` · `:773`
- Modify: `wm4spacecraft_manufacturing/build_md_report.py:500-508`
- Modify: `wm4spacecraft_manufacturing/shadow_score.py` (제외 옵션)

**Interfaces:**
- Consumes: `results_4pol/{case}.jsonl` 의 `policy in {noop, canonical, surrogate, dspy, oracle}`
- Produces: `artifacts_4pol/{case}.{md,json}` · `FINAL.md` · `REPORT.md` — case 블록마다 6행 표(천장 · oracle · canonical · surrogate · noop · llm).

**핵심 충돌.** 지금 리포트에서 `oracle` 이라는 **행 이름은 격자 천장**(실행 안 된 참조선)을 가리킨다. 여기에 실행 lane `oracle` 이 들어오면 같은 이름이 두 가지를 뜻하게 된다. 그래서 천장 행의 키를 `ceiling` 으로 바꾸고 `oracle` 을 실행 lane 에 넘긴다. 둘은 **다른 물음의 답**이라 둘 다 필요하다:

- `ceiling` = "격자에서 a\* 를 실행한 arm 들의 실측 완주율·makespan" (축 단위, `oracle/out` 라벨 격자, 혼합 case 는 N/A, J/closed 없음)
- `oracle` = "이 스트림에서 a\* 를 집행하면 어떻게 되는가" (case 단위, 완주율·시간·에너지 전부 있음)

- [ ] **Step 1: 행 순서와 라벨을 고친다**

`build_final_table.py:52-53` 을 교체:

```python
# 스윕에서 실제로 돌 수 있는 정책들. 표 순서이자 짝검정 족(family)의 정의이기도 하다.
POLICY_ORDER = ["noop", "canonical", "surrogate", "dspy", "oracle"]

# 최종표 행 순서. 첫 행 `ceiling` 은 정책이 아니라 격자 실측 참조선이므로 정책 키가 None 이다.
# (2026-08-11) 예전에는 이 참조선의 행 이름이 `oracle` 이었다. `oracle` 이 실행 가능한 lane 이
# 된 지금 같은 이름을 두 뜻으로 쓰면 표가 거짓말을 한다 -- 참조선은 `ceiling` 으로 개명했다.
ROW_ORDER = [("ceiling", None), ("oracle", "oracle"), ("canonical", "canonical"),
             ("surrogate", "surrogate"), ("noop", "noop"), ("llm", "dspy")]
```

`build_final_table.py:537-542` 의 `ROW_LABEL_TEXT` 를 교체:

```python
ROW_LABEL_TEXT = {
    "ceiling": "`a*` 천장 (비실행 · 격자 실측)",
    "oracle": "`oracle` (a\\* 집행 lane)",
    "canonical": "`canonical` (규칙)",
    "surrogate": "`surrogate`",
    "noop": "`noop` (바닥선)",
    "llm": "`llm` (dspy)",
}
```

`build_final_table.py:510` 의 분기 조건을 바꾼다:

```python
def render_row_cells(row_label, case, json_data, ceilings):
    if row_label == "ceiling":
```

(같은 함수의 나머지는 그대로 둔다 — `dict(ROW_ORDER)[row_label]` 은 `ceiling` 이 위에서 먼저 반환되므로 `None` 을 만나지 않는다.)

- [ ] **Step 2: 두 종류의 `oracle` 을 구분하는 주석/산문으로 고친다**

`build_final_table.py:480-485` 의 `ORACLE_NOTE` 를 교체:

```python
ORACLE_NOTE = (
    "> 표에는 `oracle` 이 두 번 나오는데 **다른 물음의 답**이다. **`a*` 천장** 행은 실행되지 "
    "않은 참조선이다 -- `oracle/out` 의 라벨 격자에서 a\\* arm 의 완주율·makespan 을 축(battery/"
    "fault/zone) 단위로 직접 읽은 값이고, 종류가 섞인 case 에는 해당 격자가 아예 없다. "
    "**`oracle` (a\\* 집행 lane)** 행은 2026-08-11 에 신설된 다섯 번째 실행 주자다 -- 같은 "
    "스트림 위에서 매 사건마다 a\\* 를 실제로 집행한 판이라 완주율·빌드시간·에너지가 나머지 "
    "네 lane 과 같은 분모다.\n"
    ">\n"
    "> `oracle` 행의 \"옳은 결정\" 열은 **정의상 100%** 이므로 성능 주장이 아니다 -- 그 열은 "
    "`tools/monitor/policy.jl:oracle_macro`(Julia)와 `reference_policy.py`(Python)가 "
    "일치하는지 보는 자기검사 계기판이다(계약: `test_oracle_lane.py`). 정보가 있는 것은 "
    "그 결정을 집행했을 때의 **완주율·빌드시간·J/closed** 다."
)
```

`build_final_table.py:15-17` 의 파일 상단 ★ 항목을 교체:

```
★ `oracle` 은 두 가지를 뜻하므로 표에서 이름을 나눠 쓴다: **`a*` 천장**(비실행 참조선, 격자
   실측)과 **`oracle` lane**(2026-08-11 신설, 실제로 a* 를 집행한 판). 후자의 "옳은 결정"은
   정의상 100% 라 성능 주장이 아니다 -- 정보는 완주율/시간/에너지 열에 있다.
```

`build_final_table.py:645` 근처의 산문을 교체:

```python
    lines.append("실행 가능한 lane 은 `noop` / `canonical` / `surrogate` / `dspy`(=`llm`) / "
                 "`oracle` 다섯이다(이번 스윕이 실제로 돌린 정책 집합과 같다). 그 위의 "
                 "`a*` 천장 행만 비실행 참조선으로, 매 블록에서 격자 실측에서 따로 계산된다.")
```

`build_md_report.py:508-513` 의 같은 산문을 교체(REPORT.md §2):

```python
    L.append("실행 가능한 lane 은 `noop` / `canonical` / `surrogate` / `dspy`(=`llm`) / `oracle` "
             "다섯이고, 표의 `a*` 천장 행만 비실행 참조선이다. 승자를 굵게 표시하지 않는다 -- "
             "완주율·결정정확도·빌드시간·에너지가 서로 다른 방향을 가리키는 case 가 실재하기 "
             "때문이다(아래 §5 zonecore 상세 참조).")
```

`build_md_report.py:499` 의 제목도 행 수에 맞춘다:

```python
    L.append("## 2. 헤드라인 표 -- 7 case x 6 행")
```

- [ ] **Step 3: 짝검정 족을 기계적으로 만든다**

`build_final_table.py:196` 을 교체:

```python
# 짝검정 족 = 실행 가능한 다섯 lane 의 **모든** 짝(10쌍). 손으로 고른 부분집합을 쓰면 어느 짝을
# 왜 뺐는지가 곧 사후 선택이 된다. 시드 5개에서는 어차피 부호검정 최소 양측 p=0.062 라 유의해질
# 수 없으므로(§7 한계), 이 표는 기술통계이고 족 크기는 Holm 이 알아서 흡수한다.
PAIRS = [(a, b) for i, a in enumerate(POLICY_ORDER) for b in POLICY_ORDER[i + 1:]]
```

`build_final_table.py:208` 의 독스트링과 `:253-255`, `:773` 의 "21 검정" 리터럴을 계산값으로 바꾼다:

```python
def paired_tests(rows):
    """case 하나의 판들에 대해 PAIRS 의 각 정책쌍 x E1/E3/E4 검정. 반환 {"a__b": {...}}."""
```

```python
    """모든 case 의 paired_tests 가 다 모인 뒤(2-pass 의 2단계)에만 부를 것 -- Holm 은 case 하나가
    아니라 endpoint 족(case 수 x 정책쌍 수) 전체에 적용된다. E1/E3/E4 는 서로 다른 물음이라
    **족을 절대 섞지 않는다**(endpoint 별로 따로 보정). 조정된 값을 모든 case JSON에 같은
```

```python
    # task 6, 2-pass: 모든 case 의 paired_tests 가 다 모인 지금에야 Holm 을 족 전체에 적용
```

- [ ] **Step 4: shadow 에서 oracle 판을 뺀다**

`shadow_score.py` 의 `load_rows_and_decisions` 는 주어진 파일의 **모든** 판을 읽는다. oracle 판이 섞이면 `macro (실제 enacted)` producer 행이 정의상 100% 인 판들로 부풀어 다른 정책의 실제 집행 충실도와 뒤섞인다. 인자 파서에 옵션을 더하고(기본값은 oracle 제외) 필터를 건다.

`load_rows_and_decisions` 시그니처와 본문을 고친다:

```python
def load_rows_and_decisions(paths, exclude_policies=()):
    """...(기존 독스트링 유지)...

    `exclude_policies` 에 든 정책의 판은 통째로 뺀다. 기본은 `oracle` -- 그 lane 의 enacted
    매크로는 정의상 a* 라, 넣으면 `macro (실제 enacted)` 행이 "정책들이 실제로 얼마나 옳게
    집행했나"가 아니라 "표본에 oracle 판이 몇 %인가"를 재게 된다.
    """
```

행을 추가하는 지점(`rows.append(r)` 앞)에 필터를 넣는다:

```python
                    if r.get("policy") in exclude_policies:
                        continue
                    rows.append(r)
```

`main`/인자 파서에:

```python
    ap.add_argument("--exclude-policies", default="oracle",
                    help="이 정책의 판은 shadow 채점에서 제외한다(쉼표 구분). 기본 oracle -- "
                         "그 lane 은 정의상 a* 를 집행하므로 enacted 행을 왜곡한다. "
                         "빈 문자열이면 아무것도 빼지 않는다.")
```

호출부에서:

```python
    exclude = tuple(s.strip() for s in args.exclude_policies.split(",") if s.strip())
    rows, decisions = load_rows_and_decisions(paths, exclude_policies=exclude)
```

그리고 `build_report` 의 입력 요약 줄에 제외 사실을 남긴다(§4 를 인용하는 REPORT.md 가 이 문장을 그대로 가져간다):

```python
         "입력: %d rows / %d decisions%s. 공유 분모 N = %d (kind 는 알지만 필수 상태 필드가 없거나 "
         "ReformTruth 처럼 실측 격자가 없어 unscored 로 빠진 사건은 제외)."
         % (len(rows), len(decisions),
            (" (정책 %s 판 제외)" % ", ".join(exclude)) if exclude else "", N), "",
```

(`build_report` 가 `exclude` 를 인자로 받도록 시그니처를 `build_report(rows, decisions, exclude=())` 로 넓히고 호출부에서 넘긴다.)

- [ ] **Step 5: 기존 데이터로 조립기가 도는지 확인한다** (아직 5 lane 데이터는 없다)

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
OUT=/tmp/claude-1035/-home-chahj578-Construction-OODlayer/ba0de352-4f6a-43ef-becb-f1b32aa330d2/scratchpad/art_dryrun
mkdir -p "$OUT"
/home/chahj578/Construction_OODlayer/.venv/bin/python build_final_table.py \
    --results-dir results_4pol --out-dir "$OUT"
/home/chahj578/Construction_OODlayer/.venv/bin/python build_md_report.py \
    --results-dir results_4pol --out-dir "$OUT" --oracle-dir oracle/out
grep -n "천장\|oracle\|canonical" "$OUT/FINAL.md" | head -20
```
Expected: 두 명령 모두 exit 0. `FINAL.md` 의 case 블록에 6행이 나오고, `canonical`/`oracle` 행은 아직 데이터가 없는 case 에서 `정책 없음 (case 데이터에 \`canonical\` 미포함)` 로 **명시**된다(빈칸도 0 도 아니다). `fault` case 는 Task 4 스모크로 seed 1 만 있으므로 `1/1` 로 나온다.

- [ ] **Step 6: 표본크기 회귀 테스트를 돌린다**

```bash
/home/chahj578/Construction_OODlayer/.venv/bin/python test_report_sample_size.py
/home/chahj578/Construction_OODlayer/.venv/bin/python test_stats_paired.py
```
Expected: 둘 다 통과(exit 0). `test_report_sample_size.py` 는 `build_final_table.py` 소스를 직접 grep 하므로, Step 2·3 에서 옛 표본크기 문구(`21 검정`, `시드 5개` 등)를 리터럴로 남기면 여기서 걸린다.

- [ ] **Step 7: 커밋**

```bash
git add wm4spacecraft_manufacturing/build_final_table.py \
        wm4spacecraft_manufacturing/build_md_report.py \
        wm4spacecraft_manufacturing/shadow_score.py
git commit -m "feat(report): a* 천장행과 oracle 실행 lane 분리, 짝검정 족 기계화"
```

---

## Task 7: 스윕 실행 — 7 case × 5 seed × {canonical, oracle} = 70 판

**Files:** 코드 변경 없음. 산출물: `results_4pol/*.jsonl` (덧붙임) · `_night/status_4pol.jsonl` · `_night/logs/4pol_*.log`

**Interfaces:**
- Consumes: Task 1~5 의 모든 변경
- Produces: 7 case 각각의 `results_4pol/{case}.jsonl` 에 `policy in {canonical, oracle}` 인 행 10개씩 추가 (case 당 총 25행)

**비용.** `run_4pol.sh` 의 재보정된 판당 단가(bash 실측 × 1.15) 합계 = `all 245 + fault_battery 215 + fault_zone 205 + zone 190 + battery_zone 190 + fault 180 + battery 165` = 1390 s. × 5 seed × 2 정책 = **13,900 s ≈ 3.9 시간**. 이 단가는 `noop`(스텝 상한까지 stall 하는 가장 느린 lane)이 섞인 3정책 평균에서 나온 값이라 보수적이다 — canonical/oracle 은 완주하므로 실제로는 더 짧을 가능성이 높다. 데드라인은 여유를 둬 **6시간(21600s)** 으로 준다.

- [ ] **Step 1: DSPy 서비스를 띄우고 포트를 확인한다**

`md/RESULTS_LLM7H.md` §4 의 기동 명령을 따른다. **문서에 적힌 포트 숫자를 믿지 말고 실제로 뜬 uvicorn 포트에 맞춘다** (레포에 6종이 흩어져 있다 — CLAUDE.md Gotchas). 기본은 `http://127.0.0.1:8090`.

```bash
curl -s http://127.0.0.1:8090/health
```
Expected: JSON, `program` 필드가 `__seed_only__` 계열. `dspy_real_program_gpt4o.json` 이면 **중단** — 그건 battery 전용 어휘라 zone 을 재면 어휘 밖 사건을 재게 된다.

- [ ] **Step 2: 다른 julia 가 안 도는지 확인한다**

```bash
pgrep -x -u "$(id -u)" julia && echo "STOP: julia 가 돌고 있다" || echo "OK"
```
Expected: `OK`. (도는 게 있으면 끝날 때까지 기다린다 — 게이트 P5 가 어차피 막지만, 여기서 먼저 확인하는 게 3.9시간을 아낀다.)

- [ ] **Step 3: 스윕을 백그라운드로 건다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
nohup bash run_4pol.sh --resume --policies canonical,oracle \
      --seeds 1,2,3,4,5 \
      --cases battery,fault,all,fault_battery,fault_zone,battery_zone,zone \
      --deadline-seconds 21600 \
      > _night/logs/run_4pol_lanes2.log 2>&1 &
echo "pid=$!"
```

**주의:** `--cases` 에 `zonecore` 를 넣지 말 것(Global Constraints 참조). Task 4 스모크로 `fault` 의 seed 1 은 이미 있으므로 그 2판은 다시 돈다(dedup 이 덮어쓴다) — 같은 설정·같은 스트림이라 문제없다.

- [ ] **Step 4: 진행 상황을 확인한다** (case 하나가 끝날 때마다 한 줄씩 늘어난다)

```bash
tail -5 wm4spacecraft_manufacturing/_night/status_4pol.jsonl
tail -20 wm4spacecraft_manufacturing/_night/logs/run_4pol_lanes2.log
```
Expected: `{"case":"battery","status":"ok","rows":10,...,"policies":"canonical,oracle"}` 형태로 7줄이 차례로 쌓인다. `rows` 는 **요청한 두 정책의 행 수**(10)이지 파일 전체 줄 수(25)가 아니다 — Task 4 Step 3 의 정책별 세기가 그렇게 만든다.

- [ ] **Step 5: 완주 확인**

Expected(끝난 뒤): 로그 끝에 `ALL non-skipped cases ok.` 그리고 7 case 전부 `ok`. `skipped`/`fail` 이 있으면 그 case 의 `_night/logs/4pol_{case}.log` 를 보고 원인을 적은 뒤, 남은 case 만 다시 `--resume --policies canonical,oracle --cases <남은것>` 으로 돌린다.

- [ ] **Step 6: 행 수를 검증한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python - <<'PY'
import json, collections, pathlib
CASES = ["battery","fault","all","fault_battery","fault_zone","battery_zone","zone"]
ok = True
for c in CASES:
    p = pathlib.Path("results_4pol/%s.jsonl" % c)
    d = {}
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if line:
            r = json.loads(line)
            d[(r["case"], r["ood_seed"], r["policy"])] = r
    cnt = collections.Counter(k[2] for k in d)
    good = all(cnt.get(p_, 0) == 5 for p_ in ("noop","canonical","surrogate","dspy","oracle"))
    ok &= good
    print("%-14s %s  %s" % (c, dict(sorted(cnt.items())), "OK" if good else "<-- 부족"))
print("ALL OK" if ok else "INCOMPLETE")
PY
```
Expected: 7줄 전부 `{'canonical': 5, 'dspy': 5, 'noop': 5, 'oracle': 5, 'surrogate': 5}  OK` 그리고 마지막 줄 `ALL OK`.

- [ ] **Step 7: 교차언어 계약을 실판 전체에서 확인한다**

```bash
/home/chahj578/Construction_OODlayer/.venv/bin/python test_oracle_lane.py
```
Expected: `PASS  oracle lane 은 채점된 모든 사건에서 a* 를 집행했다 (n/n)` — n 은 수백 건. **FAIL 이면 표를 만들지 말 것**: 그 출력이 Julia/Python 구현이 갈린 정확한 사건 목록이다. Task 1 을 고치고 해당 case 만 재실행한다.

- [ ] **Step 8: 원시 결과를 커밋한다**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/results_4pol/*.jsonl \
        wm4spacecraft_manufacturing/_night/status_4pol.jsonl
git commit -m "data(4pol): canonical/oracle lane 70판 추가 -- 7 case x 5 seed, 5 lane 완성"
```

(`results_4pol/logs/` 는 판당 스트림이라 수십 MB 다 — 커밋하지 않는다. `.gitignore` 에 없으면 `git add` 대상에서 뺀 채로 두고, 필요하면 별도 판단.)

---

## Task 8: 아티팩트 재생성 + 동결

**Files:** 산출물만. `artifacts_4pol/` (재생성) · `baseline_5pol/` (신규 동결)

**Interfaces:**
- Consumes: Task 6 의 조립기 · Task 7 의 `results_4pol/`
- Produces: 7 case × 6행 비교표 — 사용자가 물은 "7 failure case × 4 controller × (진행도/시간/에너지)" 의 최종 산출물

- [ ] **Step 1: case별 md/json 과 FINAL.md 를 만든다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python build_final_table.py \
    --results-dir results_4pol --out-dir artifacts_4pol
```
Expected: exit 0. `artifacts_4pol/{case}.{md,json}` · `shadow_{case}.md` · `shadow.md` · `FINAL.md` 갱신.

- [ ] **Step 2: REPORT.md 를 만든다**

```bash
/home/chahj578/Construction_OODlayer/.venv/bin/python build_md_report.py \
    --results-dir results_4pol --out-dir artifacts_4pol --oracle-dir oracle/out
```
Expected: exit 0.

- [ ] **Step 3: 표가 실제로 6행인지 눈으로 확인한다**

```bash
sed -n '/^### case = `fault`/,/^### case = `all`/p' artifacts_4pol/REPORT.md
```
Expected: 다음 6행이 전부 채워져 있다 —

```
| `a*` 천장 (비실행 · 격자 실측) | 100% (22/22) | 100% (정의상) | 21.8 (완주판 n=22) | — |
| `oracle` (a\* 집행 lane)      | 5/5 | 100% (n/n) | XX.X ± X.X s | XXX.X |
| `canonical` (규칙)            | ?/5 | ...        | ...          | ...   |
| `surrogate`                   | 5/5 | 100% (20/20) | 26.1 ± 3.9 s | 473.9 |
| `noop` (바닥선)               | 0/5 | 0% (0/6)   | —            | 947.4 |
| `llm` (dspy)                  | 5/5 | 100% (20/20) | 26.1 ± 3.9 s | 473.9 |
```

`surrogate`/`noop`/`llm` 행의 숫자가 위와 **달라지면 안 된다** — 달라졌다면 새 스윕이 기존 행을 덮어쓴 것이므로 즉시 멈추고 `git diff` 로 확인한다.

- [ ] **Step 4: 계약 테스트 일괄 확인**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
PY=/home/chahj578/Construction_OODlayer/.venv/bin/python
$PY audit_action_vocab.py && echo "P3 ok"
$PY test_surrogate_support.py && echo "P4 ok"
$PY test_oracle_lane.py && echo "oracle contract ok"
$PY test_report_sample_size.py && echo "sample size ok"
$PY test_stats_paired.py && echo "stats ok"
$PY test_llm7h.py && echo "llm7h ok"
```
Expected: 전부 exit 0.

- [ ] **Step 5: 동결본을 만든다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
rm -rf baseline_5pol && cp -r artifacts_4pol baseline_5pol
/home/chahj578/Construction_OODlayer/.venv/bin/python - <<'PY'
import json, pathlib, subprocess, datetime
out = pathlib.Path("baseline_5pol/PROVENANCE.txt")
commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
lines = ["# baseline_5pol provenance",
         "frozen_at: %s" % datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
         "git_commit: %s" % commit,
         "policies: noop, canonical, surrogate, dspy, oracle",
         "results_rows:"]
for p in sorted(pathlib.Path("results_4pol").glob("*.jsonl")):
    d = set()
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if line:
            r = json.loads(line)
            d.add((r.get("case"), r.get("ood_seed"), r.get("policy")))
    lines.append("  %s: %d" % (p.name, len(d)))
out.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(out.read_text(encoding="utf-8"))
PY
```
Expected: `results_rows` 에 7개 파일이 각 25로 찍힌다 (`zonecore.jsonl` 은 옛 3 lane 15 로 남는다 — 이번 스윕 대상이 아니므로 정상이다).

- [ ] **Step 6: 문서 포인터를 갱신한다**

`wm4spacecraft_manufacturing/md/STATUS.md` 의 "현재 상태 / 재개 지점" 에 다음을 추가한다(기존 내용은 지우지 않는다):

```markdown
## 2026-08-11 — 5 lane 완성 (canonical · oracle 신설)

`tools/monitor/policy.jl` 에 `oracle_macro` 를 넣어 `DEMO_POLICY=oracle` 이 실행 가능해졌다
(`reference_policy.py` 의 a* 를 결정 시점에 재계산). `canonical` 은 원래 실행 가능했으나
`run_4pol.sh` 의 정책 목록에서 빠져 있었을 뿐이다. 7 case × 5 seed × 2 lane = 70 판을
기존 `results_4pol/` 에 덧붙여 돌렸고, 이제 case 당 25판(5 lane × 5 seed)이 있다.

- 현행 비교표: `artifacts_4pol/REPORT.md` §2 (7 case × 6행) · 동결본 `baseline_5pol/`
- `oracle` 행의 "옳은 결정" 열은 **정의상 100%** 다 — 성능이 아니라 Julia/Python 두 구현이
  일치하는지 보는 계기판이다. 계약: `python test_oracle_lane.py`
- `a*` 천장 행(옛 이름 `oracle`)은 여전히 비실행 참조선이고, 혼합종류 case 4개에는 없다.
- `zonecore` 는 이번 스윕에서 제외했다(`run_demo.jl:433` 이 `zone` 으로 바꾸므로 같은 실험).
```

`CLAUDE.md` 의 `## Commands` 절에 계약 명령 한 줄을 더한다:

```bash
python wm4spacecraft_manufacturing/test_oracle_lane.py   # oracle lane 교차언어 계약 (exit 0)
```

- [ ] **Step 7: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/artifacts_4pol wm4spacecraft_manufacturing/baseline_5pol \
        wm4spacecraft_manufacturing/md/STATUS.md .claude/CLAUDE.md
git commit -m "docs(4pol): 5 lane x 7 case 비교표 재생성 + baseline_5pol 동결"
```

---

## 이 계획이 하지 않는 것 (명시적 범위 밖)

- **혼합종류 case 의 `a*` 천장.** `all`/`fault_battery`/`fault_zone`/`battery_zone` 은 단일축 오라클 격자가 없어 천장 행이 `N/A` 로 남는다. 그건 STEP D 로도 못 채우는 결측이다 — 새 `oracle` **실행 lane** 은 이 4 case 에서도 값이 나오므로, 천장이 없는 자리를 lane 이 부분적으로 메운다.
- **zone 축의 n=2 문제.** `reference_policy` 의 zone 규칙 근거는 arm-crossed 사건 2건뿐이고, `build_md_report.py` 가 이미 "root-covered 영역(`cov` 계열)에서 규칙이 틀렸을 수 있으며 이번 스윕에는 그 영역 결정이 0건" 이라고 적어 둔다. `oracle` lane 은 그 규칙을 **그대로** 집행하므로 같은 한계를 물려받는다. 규칙 자체를 고치는 것은 별개 작업이다.
- **시드 확대.** 5 시드에서는 부호검정 최소 양측 p=0.062 라 어떤 짝도 유의해질 수 없다. 이 표는 기술통계다. 20 시드 확대는 `docs/superpowers/plans/2026-08-11-threemetric-4lane-20seed.md` 의 몫이다.
- **`artifacts_llm7h` / `artifacts_night` / `baseline_n5` 정리.** 이 계획은 읽지도 쓰지도 않는다. `baseline_n5` 는 변경 이전 동결본으로서 그대로 둔다.
