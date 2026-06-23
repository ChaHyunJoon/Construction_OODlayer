# ConstructionBots.jl 실행 가이드 (이 PC 기준)

이 PC에서는 설치/빌드가 모두 끝나 있습니다. 아래 내용만 알면 README의 모든 예시를 재현할 수 있습니다.

## 0. 이 PC에 이미 설치/설정된 것
- **Julia 1.10 LTS** (`julia +lts` 로 호출) — 1.12도 있지만 이 프로젝트는 1.10으로 쓰세요.
- 프로젝트 의존성 instantiate 완료, **PyCall**은 conda 환경 `lego_rvo2`(Python 3.7)에 연결됨.
- **RVO2**(`rvo2`) Windows 빌드 + 설치 완료 → Julia에서 `pyimport("rvo2")` 동작.
- **LDraw 부품 라이브러리**: `C:\Users\chahj\Documents\ldraw` 에 배치됨.
- 모델 파일(.mpd/.ldr): repo의 `LDraw_files/` 폴더에 모두 포함.

## 1. 실행 명령 (항상 이 형태)
PowerShell에서:
```powershell
cd c:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
julia +lts --project=. .\run_demo_bigstack.jl
```
- **반드시 `run_demo_bigstack.jl`로 실행하세요** (그냥 `scripts/demos.jl`가 아니라).
  이유: 이 프로젝트는 변환 트리(transform tree)를 매우 깊게 재귀하는데, Windows 기본 스택(~256MB)으로는
  `StackOverflowError`가 납니다. `run_demo_bigstack.jl`은 데모를 **2GB 스택 태스크** 안에서 돌려 이 문제를 피합니다.
- 끝나면 자동으로 브라우저(http://127.0.0.1:8700)에 애니메이션이 열립니다.
  좌측 상단 **Open Controls → Animations → play** 로 조립 과정을 재생합니다.

## 2. README "Hosted Demos" 예시 → 파라미터 매핑
`run_demo_bigstack.jl` 안에서 아래 값들만 바꾸면 README의 각 예시가 됩니다.

| README 예시 | `get_project_params(N)` | `assignment_mode` | `rvo_flag` | `dispersion_flag` | `tangent_bug_flag` | 대략 소요(계산) |
|---|---|---|---|---|---|---|
| **Tractor (Greedy)** | `4` | `:greedy` | `true` | `true` | `true` | 빠름 |
| **Tractor (MILP)** | `4` | `:milp` | `true` | `true` | `true` | 빠름 |
| **AT-TE Walker (MILP+Greedy)** | `9` | `:milp_w_greedy_warm_start` | `true` | `true` | `true` | 중간 |
| **X-Wing (Greedy, RVO/Disp/TB 끔)** | `10` | `:greedy` | `false` | `false` | `false` | 수 분 |
| **Saturn V (Greedy)** | `15` | `:greedy` | `true` | `true` | `true` | 매우 김(수십 분~시간) |

> 참고: `assignment_mode = :milp` / `:milp_w_greedy_warm_start` 는 **HiGHS**(무료 솔버, 이미 설치됨)로 풉니다.
> Gurobi 라이선스는 필요 없습니다. (`milp_optimizer = :highs` 로 두세요.)

## 3. 자주 바꾸는 설정 (`run_demo_bigstack.jl` 상단)
- `project_params = get_project_params(N)` — **모델 선택** (아래 번호표 참고)
- `assignment_mode` — `:greedy` / `:milp` / `:milp_w_greedy_warm_start`
- `rvo_flag`, `dispersion_flag`, `tangent_bug_flag` — 충돌회피/분산/경로 알고리즘 on/off
- `update_anim_at_every_step`
  - `false` (현재): **빠름**. 노드 완료 시점에만 애니 갱신(직선 이동처럼 보임). 동작 확인용 권장.
  - `true`: 매 스텝 기록 → 충돌회피가 부드럽게 보이지만 **매우 느림**.
- `open_animation_at_end = true` — 끝나면 브라우저 자동 오픈
- `save_animation = true` 로 바꾸면 결과를 **독립 HTML 파일**로 저장 (브라우저 없이 나중에 열람 가능).
  저장 위치: `results/<project_name>/...visualization.html`

## 4. 모델 번호표
| N | 모델 | 부품 x 조립 | 비고 |
|---|---|---|---|
| 1 | colored_8x8 | 33 x 1 | 가장 가벼움(동작 확인 최적) |
| 2 | quad_nested | 85 x 21 | |
| 3 | heavily_nested | 1757 x 508 | 무거움(~62분) |
| 4 | tractor | 20 x 8 | README 기본 |
| 5 | tie_fighter | 44 x 4 | |
| 6 | x_wing_mini | 61 x 12 | |
| 7 | imperial_shuttle | 84 x 5 | |
| 8 | x_wing_tie_mini | 105 x 17 | |
| 9 | at_te_walker | 100 x 22 | README 예시 |
| 10 | x_wing | 309 x 28 | README 예시(~3분) |
| 11 | passenger_plane | 326 x 28 | |
| 12 | imperial_star_destroyer | 418 x 11 | |
| 13 | kings_castle | 761 x 70 | 무거움(~21분) |
| 14 | at_at | 1105 x 2 | |
| 15 | saturn_v | 1845 x 306 | README 예시(매우 무거움 ~163분) |

## 5. 빠른 동작 확인 추천 순서
1. `get_project_params(1)` (colored_8x8) 로 한 번 — 제일 빨리 끝나서 파이프라인 확인용.
2. `get_project_params(4)` (tractor) — README 기본.
3. 그다음 5(tie_fighter)/6(x_wing_mini) 등 보기 좋은 것들로.

## 6. 문제 해결
- **빈 화면(줌만 됨)**: 시뮬레이션이 아직 안 끝났거나 실행이 죽은 것. 완료 후 페이지 새로고침.
- **포트 8700 already in use**: 이전 julia 프로세스가 살아있음.
  `Stop-Process -Name julia -Force` 후 다시 실행.
- **StackOverflowError**: `demos.jl`을 직접 돌린 경우. `run_demo_bigstack.jl`로 실행하세요.
  더 큰 모델에서 또 나면 스크립트의 `2_000_000_000`(2GB)을 `4_000_000_000`으로 키우세요.
- **rvo2 관련 에러**: `conda run -n lego_rvo2 python -c "import rvo2"` 로 먼저 확인.
