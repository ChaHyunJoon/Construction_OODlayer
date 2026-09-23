# 시뮬레이터 폴더 구조

이 저장소는 ConstructionBots 시뮬레이터와 OOD 복구 정책을 구현한다.
별도 World Model 프로젝트는 없다. `wm4spacecraft_manufacturing/`는 과거 실험의
이름이 남은 폴더였으며, 2026-09-23에 아래 위치로 통합했다.

| 현재 위치 | 역할 | 이전 위치 |
|---|---|---|
| `src/decision/core/` | Julia/Python 행동 레지스트리, 목적함수, 상태 피처, 기준 정책, 시뮬레이터 API 명세 | `core/`, `oracle/action_registry.jl` |
| `src/decision/surrogate/` | surrogate 정책 구현, 학습·평가·export, 배포 모델 및 검증 | `surrogate/` |
| `src/decision/novelty/` | 분포 이탈 감지 라이브러리와 교정값·교정 도구 | `novelty/` |
| `tools/oracle/` | 시뮬레이터를 실행해 행동별 라벨을 만드는 도구 | `oracle/`의 Julia shim·generator |
| `tools/smdp/` | SMDP 데이터 검증·통계 게이트와 관련 Python 테스트 | `smdp/` |
| `tools/sweep/`, `tools/reporting/` | 재사용 가능한 평가 실행기·집계 도구 | `sweep/`, `reporting/` |
| `data/oracle/` | surrogate 학습 및 novelty 교정에 실제 사용하는 JSONL 입력 두 개 | `oracle/out/` |

표의 이전 위치는 모두 옛 `wm4spacecraft_manufacturing/` 아래 상대경로다.
`src/respec/`, `src/navigator/`, `src/smdp/`, `tools/monitor/`는 기존 역할을 유지한다.
`world_interface.json`은 LLM이 호출할 수 있는 **시뮬레이터 API 명세**이며,
학습된 World Model이 아니다. 기존 novelty 라이브러리를 보존한 것이 현재 라우터가
그 라이브러리로 레인을 선택한다는 뜻도 아니다.

## 실행과 데이터 경로

저장소 루트에서 기존 `tools/monitor/run_demo.jl`, `render_demo.jl`을 실행한다.
실행기·서비스·테스트의 기본 경로는 새 구조를 사용한다. 옛 폴더나 호환 심볼릭 링크는 없다.

- 서비스 구현 위치: `src/respec/llm_service/`.
- 정책 구현 경로를 외부에서 지정할 때: `DECISION_DIR=/absolute/path/to/src/decision`.
  기존 `WM_DIR` 환경변수는 호환 별칭으로만 지원한다. 기존 값이 옛 폴더를 가리키면 갱신해야 한다.
- 공유 Python 경로 도우미: `src/decision/core/simulator_paths.py`.
- 데이터 경로 정의: `src/decision/core/oracle_datasets.py`. 기본 경로는 작업 디렉터리와
  무관하게 저장소 루트의 `data/oracle/`로 해석된다.
- 재사용 가능한 스윕·보고 도구의 상대 출력 경로 기준은 저장소 루트다.
- `data/oracle/`의 기존 행, 배포 모델 및 교정값은 재학습·재생성하지 않았다.
  데이터 안의 과거 생성 경로는 provenance이므로 그대로 보존한다.

## 제거한 항목

- `oracle/run_relabel_20260816.sh`: 은퇴한 조합 행동을 켜는 날짜 고정 실험 스크립트.
- `reporting/fill_results_doc.py`: 이미 없어진 결과 문서·DP 자료에 의존하는 문서 채우기 도구.
- `_gen_v3-4arms/surrogate_linear.pre-v4-3arms.json`: 이전 행동 어휘의 모델 백업.
- 옛 폴더의 Python/pytest 캐시와 전용 `.gitignore`.

현재 코드·테스트에서 쓰는 데이터와 정책 구현은 보존했다. 기존에 이미 삭제되어 있던
파일을 복원하거나 이번 정리 대상으로 다시 집계하지 않았다. 과거 결과·설계 문서의
옛 경로는 당시 기록이므로 남아 있을 수 있다. 현재 경로는 이 문서를 기준으로 한다.

## 검증

- 이동 전·후 Python 테스트: 각각 826 passed, 5 skipped.
- Julia `test/smdp_stamp_smoke.jl`, `test/battery_menu_lanes_agree.jl` 통과.
- 시뮬레이터 전역 상태 스캔 결과와 RHS 분류는 이동 전 사본과 동일.
- 이동 전·후 소스로 생성한 인터페이스 JSON은 동일.
- 별도 작업 디렉터리에서 정책 export·평가 및 보고 도구 9개의 `--help` 로딩 확인,
  관련 shell 실행기 5개의 구문 검사 통과.
- 실행 중이던 DSPy 서비스를 같은 설정으로 재시작했다. `/health` 정상,
  현재 소스 지문 일치, surrogate 학습 데이터·지원 행동·목적함수 해시 동일을 확인했다.

기존 한계: `world_interface_current.jl`의 저장된 JSON과 현행 소스 불일치,
`smdp_global_inventory.jl`의 미분류 전역은 이동 전부터 존재한다. 이번 작업은
해당 시뮬레이터 계약을 바꾸지 않는다. novelty 교정 exporter는 설치된 NumPy의
`ndarray.ptp` 제거와 맞지 않아 별도 수정이 필요하다.
