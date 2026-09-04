# 호출 가능한 세계 인터페이스 — 설계 (2026-09-03)

> 선행 설계: `docs/superpowers/specs/2026-09-03-generated-primitive-synthesis-design.md` (결정 D1–D8).
> 이 문서는 그 설계를 **되돌리지 않는다** — 그것이 세운 사슬이 실제로 끝까지 도달하도록 남은 구멍을 메운다.
> 이 문서의 결정은 **D9 부터** 이어 붙인다.

**Goal:** OOD 사건 하나에서 LLM 이 **등록되고 · 인자를 받고 · 예외 없이 돌아 · 세계를 실제로 바꾸는**
Julia 함수 하나를 낸다. 이 설계가 전부 구현되기 전에는 그것이 **구조적으로 불가능**하다는 것이
아래 §1 의 실측이다.

---

## 0. 판정 — "tool 을 냈다" 의 정의

사다리 다섯 칸. 각 칸은 **기록의 한 필드**로 판정하고, 아래 칸이 초록이 아니면 위 칸은 `nothing`
("못 쟀다")이지 `false` 가 아니다.

| 칸 | 판정 필드 | 오늘 (run 1·2·3) |
|---|---|---|
| **L0** 모델이 코드를 쓰려 했다 | `wrote == true` | ✅ 2/3 (run 1 은 응답 잘림) |
| **L1** 우리 규약을 통과해 등록됐다 | `registered == true` | 🔴 **0/3** |
| **L2** 우리 인자 채널이 값을 날라 호출이 예외 없이 끝났다 | `args_from == :calls` ∧ `steps[1].status !== nothing` | 🔴 **0/3** (L1 미달로 도달 못 함) |
| **L3** body 가 기존 함수를 최소 하나 불렀다 | 정적 호출 대상 ∩ 인터페이스 ≠ ∅ (**D15 의 AST 순회가 이미 만드는 값이다** — 따로 파서를 짓지 않는다) | 🔴 **0/2** (쓴 두 body 다 0) |
| **L4** 세계가 실제로 바뀌었다 | 집행 전후 세계 다이제스트 차분 ≠ 0 | ⚫ **계측 수단이 없다** (사전등록 결정 1) |

이 설계가 목표하는 것은 **L1–L4 전부**다. L3 은 A안이 필요조건이지 충분조건이 아니다(§11).

---

## 1. 진단 — 실측

### 1.1 세 유료 런이 죽은 자리

| 런 | 죽은 자리 | 사유 | 누구의 결함인가 |
|---|---|---|---|
| 1 | agent-3 응답 | `AdapterParseError` (8필드 중 4) | 우리 — 예산 |
| 2 | Julia 경계 | `impl_not_a_function` (마크다운 펜스) | 우리 — 타입 계약 |
| 3 | 규약 검사 | `impl_not_single_expression:2` | 모델 — 최상위 헬퍼 |

### 1.2 🔴 run 2·3 은 **같은 실패**다 — 우연이 아니다

| | run 2 | run 3 |
|---|---|---|
| 둘째 최상위 정의 | `find_suitable_robot(available_robots, soc, speed, slack)` | `find_suitable_robot(task, available_robots, criteria)` |
| 그 안의 주석 | `# Placeholder logic to find a suitable robot` | `# Placeholder function to find a suitable robot based on criteria` |
| agent-2 의 mechanism | "prioritizing tasks based on **urgency** or redistributing to robots with **higher SOC and speed**" | "redistributes them based on the **specified criteria** (e.g. load balancing, priority, proximity)" |

두 런 다 agent-2 가 **선택 규칙**을 기전으로 지정했고, 인터페이스에 선택자가 없어서
agent-3 이 그것을 직접 썼다. **이름도 같고 주석의 단어도 같다.**

이것은 규약 위반이 아니라 **모델이 자기에게 없는 원시의 이름을 부른 것**이다 — 예전 구조에서
`missing_primitive` 필드가 받던 그 신호다. D5 가 인벤토리를 지우면서 `WriteToolImpl` 에서 그
출력 필드가 사라졌고(기록의 `missing_primitive`·`reach` 가 두 런 다 `""` 인 이유: 시그니처가
그것을 선언하지 않아 `getattr` 기본값으로 떨어진다), **할 말이 있는데 채널이 없으니 코드로 쓴다.**

### 1.3 "프롬프트를 강화한다" 의 기대값은 0에 가깝다

규약 4("최상위 정의 하나")는 agent-3 이 보는 프롬프트에서 **네 번** 말해진다(실측):

1. `world_interface.py::_RULES` 규약 1 — "Exactly one top-level definition"
2. 같은 블록 규약 4 — "Exactly one TOP-LEVEL definition … Helper closures defined INSIDE your function body are fine."
3. `WriteToolImpl` docstring — "WRITE THE JULIA IMPLEMENTATION … as a **single function**"
4. `impl_code` OutputField desc — "exactly one `function …` **and nothing else**" ← **출력 슬롯 바로 옆**

네 번째는 모델이 그 필드를 채우는 바로 그 자리에 붙어 있다. "안 봤다 / 묻혔다" 가설은 여기서
죽는다(참고 수치: 블록 전체 13,556자 253줄 중 규약은 앞 820자 = 6.05%, 0–9줄). **모델은 읽고 어겼다** —
안 어기면 body 를 아예 못 내기 때문이다.

### 1.4 🔴 "규약 4 를 완화한다" 는 그대로는 안전하지 않다

`register_minted_primitive!` 는 `Core.eval(@__MODULE__, Meta.parseall(code))` 로 **`code` 안의
모든 최상위 정의를 통째로** 평가한다. 그런데 규약 5 의 충돌 검사(`already_minted` / `shown` /
`withheld` / `imported`)는 `name` 인자 **하나에만** 돈다. 규약 4 를 풀면 `find_suitable_robot` 이
충돌 검사를 **한 번도 안 받고** `ConstructionBots` 에 영구히 심긴다(Julia 는 메서드 정의를 못 지운다).
그것이 규약 5 가 막으라고 존재하는 사고 그 자체다.

### 1.5 🔴 인터페이스가 깊이 1 에서 멈춘다

`tools/gen_world_interface.jl` 의 루프는 `PlannerEnv` 한 뿌리를 **1단계만** 전개한다.
산출물에 필드까지 실린 타입은 4개, **이름만** 등장하는 타입이 9개다.

모델이 정확히 쓴 것은 전부 정의된 타입이고, 지어낸 것은 전부 침묵한 타입이다 — 예외가 없다:

| 모델이 쓴 것 | 그 타입이 인터페이스에 | |
|---|---|---|
| `env.sched` · `sched.nodes` · `sched.vtx_map` · `env.agent_policies` | 정의됨 | 정확 |
| `node.assigned_robot` | `ScheduleNode` — 없음 (실제 필드는 `(id, node, spec)`) | 지어냄 |
| `robot.charge` · `.capacity` · `.current_load` · `.position` | `agent_policies::Dict` — 값 타입 없음 | 지어냄 |

### 1.6 🔴 그리고 이 사건의 상태량은 **`env` 안에 아예 없다**

battery OOD 의 SoC 는 `PlannerEnv` 의 필드가 아니라 **모듈 전역**
`BATTERY_FLEET::Ref{Union{Nothing,BatteryFleet}}`(`src/navigator/battery.jl:111`)에 산다.
`BatteryFleet.soc::Dict{Any,Float64}` 가 로봇별 잔량이다.

인터페이스의 battery 관련 메서드는 12개인데 **SoC 를 읽는 것은 하나도 없다**
(`battery_report` 는 export 되지 않아 208개에 없다). 그래서:

> **§1.5 의 여섯 항목을 전부 고쳐도 모델은 `robot.charge` 를 또 지어낸다.**
> 타입 폐포는 `env` 를 따라가는데, 이 사건이 필요로 하는 값이 `env` 에 없기 때문이다.

이것이 이 문서가 선행 계획서의 여섯 항목에 **더하는** 가장 중요한 사실이다.

### 1.7 인자 채널은 실측으로 막혀 있다 (사진의 5번, 그러나 사유가 다르다)

`PARAM_JSON_TYPES` 에 이미 `"array" => AbstractVector`·`"object" => AbstractDict` 가 있어
`_param_type_reject` 는 배열을 **통과**시킨다. 그런데도 호출이 죽는다. 프로브 실측:

```
bind ok kwtypes  => task_ids::JSON3.Array{String, …}
CALL 🔴 THREW    => TypeError: in keyword argument task_ids,
                    expected Vector{String}, got a value of type JSON3.Array{String, …}
nested CALL 🔴   => TypeError: in keyword argument opts,
                    expected Dict{String, Any}, got a value of type JSON3.Object{…}
```

원인 둘, 둘 다 사진에 없다:
1. `bind_primitive_args` 가 **JSON3 의 지연 뷰 객체를 그대로 넘긴다** — 네이티브 컨테이너로
   실체화하지 않는다.
2. 🔴 **Julia 의 키워드 인자는 `convert` 가 아니라 타입 단언이다.** 위치인자와 달리 자동 변환이
   없다. 그러므로 변환은 **우리 몫**이고, 안 하면 `enact_minted!` 의 바깥 `try` 가 그것을
   `partial=true` 로 적어 손도 안 댄 세계가 `handled=true` 로 폴백을 삼킨다.

### 1.8 미정 이름·미정 필드는 `Core.eval` 을 통과한다

프로브 실측:

```
P2 register (미정의 함수 호출 body)  => nothing        # eval 통과
P2 CALL                              => UndefVarError: `find_suitable_robot_xyz` not defined
P3 register (없는 필드 접근 body)    => nothing        # eval 통과
```

즉 오늘의 사슬에서 §1.5 의 지어냄은 **등록을 통과해 집행 중에** 터진다. 그때는 이미 세계가
반쯤 편집됐을 수 있고, 되먹임 문장도 "필드가 없다" 가 아니라 raw 예외다.

---

## 2. 사슬의 일곱 칸

```
 ① agent-1 관측 ─→ ② agent-2 명세 ─→ ③ agent-3 Julia 작성
                                          │
        ┌─────────────────────────────────┘
        ↓
 ④ 파이썬 정규화 ─→ ⑤ Julia 규약 검사 ─→ ⑥ Core.eval + 등록 ─→ ⑦ 인자 바인딩 + 호출 + 세계
```

| 칸 | 오늘의 결함 | 고치는 결정 |
|---|---|---|
| ② | 기전을 과잉 명세해 없는 선택자를 요구한다 | (D13 의 되먹임으로 계측; 프롬프트는 안 바꾼다 — D19) |
| ③ | 깊이 1 인터페이스 · 무타입 컨테이너 · `env` 밖 상태 없음 · 못 찾겠다고 말할 채널 없음 | **D9 · D10 · D11 · D12 · D13** |
| ⑤ | 지어낸 이름·필드를 안 잡는다 | **D15** (규약 4 는 **유지** — D14) |
| ⑥ | — (건강함) | — |
| ⑦ | JSON3 뷰가 그대로 흐르고 kwarg 는 변환이 없다 · 실패해도 되먹임이 없다 · 세계 변화를 안 잰다 | **D16 · D17 · D18** |

---

## 3. 결정

| # | 결정 |
|---|---|
| **D9** | 타입 전개는 **고정점**이다(마법의 깊이 숫자 없음). 씨앗 = `PlannerEnv` **∪ `PlannerEnv` 를 인자로 받는 모든 메서드의 인자 타입**. 필터는 **CB 소유 타입만** — 그대로 유지 |
| **D10** | 무타입 컨테이너는 **선언을 좁혀서** 정보를 만든다. 런타임 표본 추출은 **하지 않는다** |
| **D11** | 함수 목록을 **호출 가능 / 재료가 없음**으로 가르고, 호출 가능한 것은 인자마다 **`env` 로부터의 도달 경로**를 붙인다 |
| **D12** | `env` **밖의 세계 상태**(앰비언트)를 인터페이스에 싣는다. 첫 대상은 battery SoC |
| **D13** | `WriteToolImpl` 에 `needs` 출력 필드를 되돌린다 — 인벤토리가 아니라 **계측 채널**이다 |
| **D14** | 규약 4 는 **그대로 둔다** (§1.4) |
| **D15** | 지어낸 이름·필드는 **`Core.eval` 전에** 정적으로 거절한다 |
| **D16** | 경계는 JSON3 뷰를 **모델이 선언한 Julia 타입으로 변환**한다. 실패는 예외가 아니라 거절이다 |
| **D17** | 등록/바인딩 거절 사유를 agent-3 에게 **한 번** 되먹인다 (`/rewrite`, 재시도 상한 1) |
| **D18** | 집행 **전후**로 세계 다이제스트를 찍고 차분을 기록한다 |
| **D19** | `_RULES` 의 문구와 agent-2 프롬프트는 **안 바꾼다** — D6 측정의 대조군이다 |

---

## 4. D9 — 타입 폐포 (측정된 설계)

### 4.1 왜 고정점인가

깊이 상한은 지킬 근거가 없는 숫자다. CB-only 필터가 있으면 전개는 **저절로 수렴한다**(실측):

| 씨앗 · 필터 | 타입 수 | 렌더 줄수 | `PlannerEnv` 를 받는 23개 메서드 중 호출가능 |
|---|---|---|---|
| 오늘 (깊이 1) | 4 | 25 | 7 (변이 **5**) |
| A: `PlannerEnv` 필드만, 고정점 | 49 | ~143 | 13 (변이 7) |
| **B: A + env-메서드 인자 타입 (= D9)** | **66** | **~206** | **23 (변이 16)** |
| 🔴 서드파티 타입 허용 (깊이 2) | 1,302 | ~5,661 | — |
| 🔴 서드파티 타입 허용 (깊이 3) | **25,160** | ~33,947 | — |

⚠️ 세 줄 다 **같은 추정량**으로 쟀다: 인자가 폐포 안 · Base 스칼라 · `Any` 중 하나면 채워진다고
센다(`Any` 를 관대하게 세므로 **상한**이다). 단위는 **메서드**이지 이름이 아니다 —
오늘의 변이 5개는 이름 4개(`preprocess_env!` · `step_environment!`×2 ·
`update_parent_build_status!` · `update_planning_cache!`)이고, 전부 "환경을 한 스텝 굴린다"
부류라 **사건에 대응하는 행동이 하나도 없다**. B 가 여는 11개는 이름 둘 —
`apply_cmd!`(7) 과 `close_node!`(4) — 이고, 그 둘이 **스케줄 노드를 실제로 여닫고 명령을 먹이는**
유일한 공개 경로다. 늘어난 것은 숫자가 아니라 **부류**다.

**CB-only 필터는 절대 풀지 않는다.** 마지막 두 줄이 그 이유다 — 현행 생성기 주석이 그것을
"모델이 해시테이블을 직접 주무르라는 초대장" 이라고 적은 것은 옳고, 수치로도 폭발한다.

씨앗을 env-메서드 인자 타입까지 넓히는 것이 B 다. 그 17개 타입이 `apply_cmd!` 계열
전체(`Twist` · `CloseBuildStep` · `OpenBuildStep` · `DepositCargo` · `FormTransportUnit` ·
`LiftIntoPlace` · `RobotGo` · `TransportUnitGo`)를 연다. **변이 메서드가 5 → 16 이 되고, 그 11개는 전부 `apply_cmd!`·`close_node!` — 오늘의 다섯에는 없는 부류다.**

### 4.2 구현이 반드시 다뤄야 하는 모양 넷 (전부 실측)

1. **추상 타입은 필드가 없다.** `SceneTreeEdge` 에 `fieldnames` 를 부르면
   `ArgumentError: type does not have a definite number of fields` 를 **던진다** — 오늘의
   생성기를 그대로 전이적으로 돌리면 여기서 죽는다. 추상 타입은 필드 대신 `subtypes` 를 싣는다
   (`InteractiveUtils` 가 필요하다 — 생성기에 `using` 을 더한다).
2. **`UnionAll` 은 벗긴다.** `ScheduleNode{I,V}` · `Ball2` 등.
3. **`Union` 은 `nameof` 가 없다.** `apply_cmd!(node::Union{TransportUnitGo, RobotGo}, …)` 의
   렌더가 여기서 던진다 — 갈래를 따로 처리한다.
4. **타입 매개변수를 따라간다.** `Dict{AbstractID, Ball2}` 는 `AbstractID` 와 `Ball2` 를 낳는다.
   `TypeVar` 는 상한(`ub`)으로 내려간다.

### 4.3 결정성

전개는 `fieldtypes` · `subtypes` · 타입 매개변수 순회뿐이다 — **타입 추론이 안 낀다.**
그래서 게이트 (2)(새 서브프로세스 재생성물과 커밋본의 바이트 비교)가 그대로 산다.
🔴 `subtypes` 의 반환 순서는 계약이 아니므로 **이름으로 정렬**한다 —
`method_entries()` 의 `alg=MergeSort` 와 같은 논거다.

---

## 5. D10 — 무타입 컨테이너

`PlannerEnv` 의 두 필드는 선언 타입이 맨 `Dict` 라 정보가 0이다. 런타임 값은:

| 필드 | 선언 (`src/route_planning.jl:115-116`) | 실제 |
|---|---|---|
| `agent_policies` | `Dict` | `Dict{AbstractID, VelocityController}` (`src/full_demo.jl:817`) |
| `agent_parent_build_step_active` | `Dict` | `Dict{AbstractID, Bool}` (`src/route_planning.jl:128`) |

**런타임 표본 추출은 하지 않는다.** 그러려면 생성기가 살아 있는 `PlannerEnv` 를 지어야 하고,
그 순간 산출물이 세계 하나의 우연에 의존하며 바이트 게이트가 흔들린다.

**대신 선언을 좁힌다.** 그것이 정보를 만드는 유일하게 안정적인 자리다:

```julia
agent_policies::Dict{AbstractID,VelocityController} = Dict{AbstractID,VelocityController}()
agent_parent_build_step_active::Dict{AbstractID,Bool} = Dict{AbstractID,Bool}()
```

그러면 D9 의 폐포가 `VelocityController` 를 **저절로** 따라간다(오늘은 어떤 깊이로도 도달 못 한다).

⚠️ **이 좁힘은 시뮬레이터 코드를 바꾼다.** 소비자는 세 파일뿐이고(`full_demo.jl` 이 쓰고,
`potential_fields.jl`·`route_planning.jl` 이 읽는다) 다른 값 타입을 넣는 자리는 없다 —
그래도 이것은 **전체 Julia 스위트로 확인해야 하는 변경**이다. 어긋나면 조용히가 아니라
시험 시각에 빨갛게 실패한다.

🔴 그리고 이 좁힘이 밝히는 사실 하나: `VelocityController` 의 필드는
`nominal_policy` · `dispersion_policy` **둘뿐**이다. `charge` 도 `capacity` 도 `current_load` 도
**없다.** 모델이 그것을 지어낸 이유는 §1.6 이고, 고치는 것은 D12 다.

---

## 6. D11 — 도달 경로와 호출 가능성

### 6.1 산출물에 세 번째 블록 `access` 를 더한다

폐포의 각 타입에 대해 `env` 로부터 그 값을 얻는 **경로**를 적는다. 필드 그래프의 순수
순회이므로 결정적이다:

```
ScheduleNode        env.sched.nodes[i]
AbstractID          env.sched.vtx_ids[i]  ·  keys(env.agent_policies)
VelocityController  values(env.agent_policies)
PathSpec            env.sched.nodes[i].spec
SceneNode           env.scene_tree.nodes[i]
```

### 6.2 함수 목록을 가른다

렌더를 두 표제로 나눈다:

```
FUNCTIONS YOU CAN CALL NOW (every argument is obtainable from env)
- close_node!  (node::ScheduleNode, env::PlannerEnv)
      node  <-  env.sched.nodes[i]
- swap_battery! (env::PlannerEnv, role::AbstractID; verbose)
      role  <-  env.sched.vtx_ids[i]

FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET
- <이름> (…)      missing: <타입>
```

판정: `env` 를 제외한 모든 인자 타입이 (a) 폐포 안 (b) Base 스칼라(`Real`·`AbstractString`·
`Symbol`·`Bool`·`Char`·`Nothing`) (c) `Any`/무주석 중 하나.

🔴 **이것이 §1.2 의 실패를 정면으로 겨냥한다.** 모델은 "선택자가 없다" 고 판단해 placeholder 를
썼는데, 그 판단은 208줄짜리 평평한 이름 목록에서 내린 것이다. 인자마다 경로가 붙으면
"부를 수 있는 것"이 **호출부째로** 손에 들어온다.

⚠️ **D6 은 안 흔들린다.** 감춘 다섯(`release_pending_assignments!` 외)은 `names(CB)` 에 없으므로
양쪽 표제 어디에도 안 나온다. 가르는 것은 렌더이지 모집단이 아니다.

---

## 7. D12 — `env` 밖의 세계 상태

인터페이스가 오늘 답하는 질문은 "`env` 란 무엇인가" 다. 그러나 세계는 `env` **더하기 모듈 전역**이다.
battery 레인의 상태량 전부가 그 전역에 있다(§1.6).

**설계:** 생성기에 **앰비언트 루트 목록**을 둔다 — 각 항목은 `(이름, 읽기 접근자, 타입)`.
첫 항목:

```
AMBIENT WORLD STATE (not on env; read it with the accessor shown)
- battery fleet    battery_report()  ::  (min_soc, mean_soc, soc_spread, n_depleted,
                                          soc::Dict{Any,Float64}, total_energy_J)
```

필요한 생산 변경은 **`battery_report` 를 export 하는 한 줄**이다. 그러면 `names(CB)` 에 들어와
208개 표면에 자동으로 실린다.

🔴 **이것은 D6 위반이 아니다.** D6 이 감추는 것은 **능력**(세계를 바꾸는 비공개 impl)이고,
`battery_report` 는 **순수 읽기**다. 모델에게 "무엇을 할 수 있는지"를 알려 주지 않고
"세계가 어떤 상태인지"만 알려 준다 — 감춘 다섯은 그대로 감춰진다.

⚠️ 앰비언트 루트를 **손으로 나열한다**는 점이 이 결정의 유일한 비용이다. 그래서 목록은
게이트가 지킨다: `test/world_interface_current.jl` 에 "앰비언트 목록의 모든 접근자가
`names(CB)` 에 있다" 는 시험을 더한다(없으면 산출물이 부를 수 없는 이름을 광고한다).

---

## 8. D13 — `needs` 채널

`WriteToolImpl` 에 출력 필드 하나:

```python
needs: str = dspy.OutputField(desc=
    "a capability your body required that you could not find in the world interface; "
    "empty string if none")
```

- 모델에게 **코드 말고 말할 자리**를 준다 — §1.2 의 placeholder 는 이 자리에 갈 문장이었다.
- 우리에게는 **A안이 실제로 구멍을 메웠는지**의 런별 측정이 된다.
- 🔴 이것은 인벤토리의 부활이 **아니다**. 인벤토리는 모델이 **고르는** 목록이었고, `needs` 는
  모델이 **없다고 신고하는** 문자열이다. 반대 방향이다.

⚠️ 출력 필드가 하나 늘면 응답이 길어진다 — run 1 이 잘려 죽은 그 축이다. `needs` 는
`impl_code` **뒤**가 아니라 스칼라 넷과 같은 앞쪽에 둔다(짧고, 잘림에서 먼저 완성돼야 한다).

---

## 9. D15 · D16 — 경계 둘

### 9.1 D15: eval 전 정적 검사

`check_impl_conventions` 에 검사 하나를 더한다. body 의 AST 를 걸어 **필드 접근**(`a.b`)과
**호출 대상**(`f(...)`)을 모으고 대조한다:

- 호출 대상이 `isdefined(CB, f)` 도 `Base` 도 아니고 body 안 지역 정의도 아니면
  → `reject:impl_unknown_call:find_suitable_robot`
- 필드 접근의 수신자 타입을 **정적으로 알 수 있을 때만** 대조한다 — 즉 `env.<f>` 와 폐포가
  그 타입을 아는 경로에 한한다 →
  `reject:impl_unknown_field:ScheduleNode.assigned_robot — fields are (id, node, spec)`

🔴 **필드 검사는 보수적이어야 한다.** Julia 는 동적이라 임의 표현식의 타입을 안 다. 모르면
**통과**시킨다 — 거짓 거절은 모델의 옳은 코드를 막는데, 그것은 이 레인이 재려는 것을 파괴한다.

이 검사의 값은 §1.8 이다: 오늘은 지어냄이 **집행 중에** 터지는데, 그것을 **등록 전 거절**로
바꾸면 세계를 안 건드리고 D17 이 되먹일 문장이 생긴다.

### 9.2 D16: 인자 채널

`check_impl_conventions` 는 이미 kwarg AST 를 걷는다(`Expr(:kw, Expr(:(::), :task_ids,
:(Array{String,1})), default)`).

🔴 **그런데 그 함수는 `Union{Nothing,String}` 을 반환한다 — 타입을 실어 보낼 자리가 없다.**
반환 타입을 바꾸면 호출자 전부와 시험 열몇이 따라 바뀐다. 그러므로 **추출은 별도 순수 함수**
`impl_param_types(code) -> Dict{String,Any}` 로 짓고, `register_minted_primitive!` 이
규약 검사 **통과 뒤 · `Core.eval` 전에** 한 번 부른다(F7 의 "검증은 eval 앞" 불변식 안쪽이다).
값은 등록 행의 `param_types` 열이 된다. 주석 없는 kwarg 는 이 dict 에 **키가 없다**
(`nothing` 을 값으로 넣지 않는다 — 삼상 규약).

`bind_primitive_args` 는 그 값이 `Type` 일 때만 변환한다:

```julia
converted = try _convert_arg(T, v) catch; return "reject:param_convert:$(k):expected $(T), got $(typeof(v))" end
```

이것이 §1.7 의 두 원인을 한꺼번에 닫는다 — JSON3 뷰는 실체화되고(`convert(Vector{String},
JSON3.Array{String})` 은 통과한다), 안 되는 경우는 예외가 아니라 거절이 된다.

⚠️ 타입 주석이 없는 kwarg 는 `param_types` 에 키가 없고 **오늘 그대로** 흐른다 — 넓히지 않는다.
⚠️ `T` 는 모델이 쓴 **AST 조각**이지 `Type` 이 아니다. `Core.eval` 로 타입으로 바꿔야 하는데,
그 eval 은 임의 코드를 돌릴 수 있다 — `Meta.parseall` 결과가 타입 표현식의 모양
(`Symbol` · `Expr(:curly, …)` · 수신자까지 모양인 점 접근)인지 먼저 검사한다.
🔴 **모양이 아니면 그 키를 버리지 않는다 — 주석의 원문(`String`)을 그 자리에 기록한다.**
그래서 `param_types` 의 값은 **삼상**이다: 키 없음(주석이 없다) · `Type`(읽었다) ·
`String`(주석은 있는데 못 읽었다). 버리면 "주석 없음" 과 같아져 JSON3 뷰가 그대로 흘러
호출이 `TypeError` 로 죽는데, 그것은 거절이 아니라 **예외**라 위의 "예외가 아니라 거절"을
정면으로 깬다. 대신 `bind_primitive_args` 가 `T isa Type` 로 셋을 가르고, 그 kwarg 에
**값이 실제로 올 때만** `reject:param_annotation_unreadable:` 를 낸다(값이 안 오면 callee
기본값으로 그대로 집행된다 — 파서의 한계로 정상 코드를 막지 않는다).
🔴 그리고 이 모양 검사는 **샌드박스가 아니라 좁힘이다**: Julia 는 kwarg 타입 주석을 메서드
정의 시점에 평가하므로 같은 주석이 아래 본래의 `Core.eval` 에서 어차피 돈다. 이 검사가
막는 것은 `impl_param_types` 의 **조용한** eval(사유를 안 남긴다)뿐이다.
진실원: `test/minted_registration.jl` testset (29)(30) · `test/minted_end_to_end.jl` (13).

---

## 10. D17 · D18 — 되먹임과 계측

### 10.1 D17: `/rewrite`

`impl_rejected_why` 는 오늘 `tools/monitor/enact.jl` 안에만 있고 **파이썬으로 돌아가는 길이 없다.**
그래서 이것은 엔드포인트 하나가 아니라 **채널 하나**다:

1. 파이썬: `POST /rewrite {impl_code, impl_rejected_why, spec, world_interface}` → agent-3 한 번 더 →
   새 `impl_code`/`params`/`calls`. F2 의 `wrote is False` 되먹임과 같은 관용을 쓴다.
2. Julia: `enact_minted_decision!` 이 등록/바인딩 거절을 받으면 `DSPY_URL * "/rewrite"` 로
   한 번 왕복하고 **재등록을 한 번만** 시도한다.

🔴 재시도 상한은 **1**이다. 무한 루프는 유료 호출을 무한히 태운다.
⚠️ 사건당 유료 호출이 최대 +1 이다. 사전등록 문서의 비용 문단을 이 값으로 갱신한다.
⚠️ **D6 의 뜻이 "1발"에서 "재시도 포함"으로 바뀐다.** 판정 기준을 바꾸는 것이므로 런 **전에**
사전등록에 적는다.

### 10.2 D18: 세계 다이제스트

사전등록 결정 1(R11)이 적은 그대로, 오늘의 계측으로는 세계가 바뀌었는지 못 잰다 —
`handled` 는 구성상 ~100%, `applied` 는 항상 `nothing`, `world_maybe_dirty` 는 무조건 `true`,
`steps.status` 는 자기신고다.

집행 **전후**로 값싼 다이제스트를 찍는다. 재료는 전부 이미 있다:

| 성분 | 출처 |
|---|---|
| `closed` | `length(env.cache.closed_set)` |
| `active` | `length(env.active_build_steps)` |
| `binding` | `assignment_binding(env.sched)` (`src/respec/common_resolve.jl:68` — 배정을 읽는 **단 하나의** 구현) |
| `n_edges` | `Graphs.ne(env.sched.graph)` |

차분을 `world_delta` 로 기록한다. ⚠️ `assignment_binding` 은 스스로 **하한**이라고 적는다
(팀이 맡은 정점은 정렬 첫째만 담는다) — 0 이 아니면 확실히 바뀐 것이고, 0 이라고 안 바뀐 것은
아니다. 기록도 그렇게 읽어야 한다.

---

## 11. 비-목표 (YAGNI)

- **`primitive_registry` 를 되살리지 않는다.** D5 가 지운 것은 지운 채로 둔다. `needs`(D13)는
  모델이 고르는 목록이 아니라 신고하는 문자열이다.
- **반환 타입 추론(`Base.return_types`)을 안 한다.** "누가 `Twist` 를 만드나" 까지 잇는 길이지만,
  추론 결과는 Julia 판마다 흔들릴 수 있어 바이트 게이트가 이유 없이 빨개진다. D9 의 씨앗 확장이
  같은 문제의 대부분(23/23)을 결정적으로 푼다.
- **예제 body 를 프롬프트에 안 넣는다.** L3 이 이 설계 뒤에도 0 이면 그때 검토한다(§12).
- **규약 4 를 안 푼다** (§1.4).
- **`_RULES`·agent-2 프롬프트 문구를 안 바꾼다** (D19).
- **값 스키마의 범위 검사**(`minimum`/`enum`/`items`)는 여전히 parked (R46).

---

## 12. 위험

| # | 위험 | 오늘 아는 것 |
|---|---|---|
| R-A | **L3 이 여전히 0 일 수 있다.** D9·D11 은 필요조건이지 충분조건이 아니다 — 모델이 부를 수 있게 됐다고 부르는 것은 아니다 | 유일한 답은 측정이다. `needs`(D13)가 다음 런에서 그 이유를 말하게 한다 |
| R-B | 블록이 커진다: 13.6KB → 약 20KB (타입 25줄→206줄, 함수 목록에 경로 주석) | `MAX_TOKENS` 는 출력 예산이라 무관하다. 입력 비용은 사건당 한 번 |
| R-C | D10 의 선언 좁힘이 스위트를 깬다 | 소비자 세 파일뿐. 전체 Julia 스위트(약 20분)로 확인한다 |
| R-D | D15 의 필드 검사가 옳은 코드를 거절한다 | 보수적 규칙(모르면 통과) + 음성 대조 시험 필수 |
| R-E | D17 이 D6 의 판정 기준을 바꾼다 | 런 전에 사전등록에 적는다 |
| R-F | 앰비언트 목록(D12)이 손으로 유지된다 → 낡는다 | 게이트가 "접근자가 `names(CB)` 에 있다"를 지킨다 |
| R-G | 이 문서의 결정 열하나가 전부 들어와도 **세계를 유의미하게 바꾸는** tool 인지는 별개다 | L4 는 "다이제스트가 변했다" 까지만 잰다. 그것이 좋은 결정인지는 이 레인의 물음이 아니다 |

---

## 13. 근거

- 기록 · `results/synth_lane_records{,.run1-truncated,.run2-rejected}.jsonl` · `results/task11-run{,2,3}.log`
- 사전등록 · `docs/superpowers/reports/2026-09-03-task11-measurement-preregistration.md`
- 선행 설계 · `docs/superpowers/specs/2026-09-03-generated-primitive-synthesis-design.md` (D1–D8)
- 코드 · `tools/gen_world_interface.jl` · `src/respec/llm_service/world_interface.py` ·
  `src/respec/llm_service/synthesize.py` · `src/respec/minted_registration.jl` ·
  `src/respec/minted_tool.jl` · `src/respec/common_resolve.jl` · `tools/monitor/enact.jl` ·
  `src/route_planning.jl` · `src/navigator/battery.jl`
- 이 문서의 모든 수치는 **이 세션에서 직접 측정**했다(폐포 크기 · 호출가능 메서드 수 ·
  경계 프로브 P1–P3 · 블록 길이). 어느 것도 선행 문서에서 인용하지 않았다.
