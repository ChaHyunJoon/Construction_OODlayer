# Shadow Score -- STEP A (새 시뮬 0회, 동일 사건·동일 분모)

입력: 15 rows / 95 decisions. 공유 분모 N = 59 (kind 는 알지만 필수 상태 필드가 없거나 ReformTruth 처럼 실측 격자가 없어 unscored 로 빠진 사건은 제외).

## 산출 1 -- producer 4개 (동일 사건·동일 분모 N=59)

| producer | n | 옳은 결정 (95% CI) |
|---|---|---|
| `rule` | 59 | 0.0% (0/59) [0.00, 0.06] |
| `surrogate` | 59 | 100.0% (59/59) [0.94, 1.00] |
| `llm` | 59 | 62.7% (37/59) [0.50, 0.74] |
| `macro (실제 enacted)` | 59 | 54.2% (32/59) [0.42, 0.66] |

| producer | Battery | Fault | Zone |
|---|---|---|---|
| `rule` | n/a | n/a | 0.0% (0/59) |
| `surrogate` | n/a | n/a | 100.0% (59/59) |
| `llm` | n/a | n/a | 62.7% (37/59) |
| `macro (실제 enacted)` | n/a | n/a | 54.2% (32/59) |

## 산출 2 -- B1 kind->macro 룩업표 (leave-one-out, 자기 자신 제외)

| kind | n | 옳음 | rate |
|---|---|---|---|
| Battery | 0 | 0 | n/a |
| Fault | 0 | 0 | n/a |
| Zone | 59 | 59 | 100.0% (59/59) |
| **합계** | **59** | **59** | **100.0% (59/59)** |

## 산출 3 -- B2 random-over-valid (해석적 기댓값, 몬테카를로 아님)

| kind | n | 기댓값 합 | rate |
|---|---|---|---|
| Battery | 0 | 0.00 | 0.0% |
| Fault | 0 | 0.00 | 0.0% |
| Zone | 59 | 29.50 | 50.0% |
| **합계** | **59** | **29.50** | **50.0%** |

Fault 는 `valid` 가 기록되지 않아(정책 서버가 fault 에는 legal-macro 메뉴를 안 실어 보냄, `policy.jl:248` 의 kind 분기가 battery/zone 만 채운다) B2 기여가 언제나 0 이다 -- 이건 이 스크립트의 버그가 아니라 원본 로그의 공백이다. Zone 은 `valid=[NOOP, RelocateBuild]` 이므로 기댓값 50%가 바닥선 -- surrogate 의 zone 7/7 은 이 50% 에 견줘 읽어야 한다.

## 산출 4 -- novelty 게이트 사후 재생

router flag (판 단위, DEMO_ROUTER): {'0': 15}

router_p: n=95, mean=0.089, range=[0.051, 0.398]

"라우터가 켜졌다면 LLM 으로 올라갔을 결정" 비율 (router_novel==True, 사후 재생): 0.0% (0/95)

## 해석 한계

> 실행된 정책이 이후 세계를 갈라놓으므로 shadow 채점은 "이 상태에서 정책 X 는 a\* 를 골랐겠는가"
> (상태 조건부 결정 충실도)이지 **결과 비교가 아니다.** 완주·시간·에너지를 shadow 로 말하면 안 된다.

