# CUSUM → ADWIN 교체 작업 결과 (2026-07-21)

E3/E4의 drift 감지기를 CUSUM에서 ADWIN(ADWIN2, river)으로 바꾸려는 작업에서, 단순 교체보다 훨씬
중요한 두 가지를 발견했다. 결론부터: **감지기(CUSUM↔ADWIN)보다 "무엇을 감지기에 먹이는가(신호)"가
더 중요하며, 현재 E3/E4가 쓰는 value-residual은 이 과제의 drift 신호가 아니다.**

---

## 환경 (river 설치 "에러")
- `pip install river`가 scipy를 1.15.3으로 올려 gensim(<1.14 요구)과 pip **의존성 경고**를 냈다.
- 실제로는 **런타임 breakage 아님**: `gensim.matutils`·`gensim.corpora.Dictionary`·`gensim.models` 모두
  scipy 1.15.3에서 정상 import/동작 확인. river ADWIN·sklearn 1.6.0도 정상. → **경고는 cosmetic.**
- river(>=1.14.1)와 gensim(<1.14.0)의 scipy 핀은 **동시 만족 불가**하지만, 런타임엔 둘 다 1.15.3에서 작동.
  scipy를 건드리지 않았다(working state 보존). ADWIN은 순수 파이썬이라 scipy와 무관.

## 무엇을 바꿨나
- `drift_detectors.py` (신규): `CusumDetector`, `AdwinDetector`(river ADWIN2 래퍼), `make_novelty`(covariate 신호).
- `e3_drift.py`: ACTIVE 정책을 (감지기, 신호) pluggable로 리팩터. **default 'active'를 CUSUM/novelty로 승격**
  (2026-07-21; value-residual 오지정 수정). 옛 CUSUM/resid는 `E3b` 비교 블록에 'old default'로 보존.
- `e4_ablation.py`: `run_cell`에 `make_detector`/`signal_fn` 옵션 추가; **cell D를 CUSUM/novelty로 승격**.
  옛 CUSUM/resid는 `E4b`에 'old default'로 보존. 셀 A/B/C는 불변.
- `compare_detectors.py` (신규): short/long 스트림 × {CUSUM,ADWIN} × {resid,novelty} 전체 그리드 비교.
- `RESULTS.md`: E3/E4 공식 수치를 새 default로 갱신(변경 note 포함).

### DEFAULT 승격 결과 (option a, 2026-07-21)
| | 옛 default (CUSUM/resid) | **새 default (CUSUM/novelty)** |
|---|---|---|
| E3 active: post-drift / calls / spurious | 0.111 / 57 / 3 | 0.222 / **41(−28%)** / **0** |
| E4 cell D: post-drift / calls | 0.111 / 41 | 0.222 / **33** |

- 트레이드오프: 짧은 스트림에선 transient regret이 약간↑(0.111→0.222, 감지 1스텝 느림) 대신 **spurious 0 + calls↓**.
  옛 값이 낮았던 건 residual의 우연한 조기 발화가 모델을 신선하게 유지한 부작용이었다(원리적으로 맞지 않음).
- **감지기는 CUSUM 유지**(ADWIN은 짧은 스트림서 발화 불가). ADWIN의 이점은 긴 스트림에서 발현(아래 표).

---

## 발견 1 — value-residual은 drift 신호가 아니다
E3의 ACTIVE 감지기는 top-1 예측 잔차 `|pred - true_closed|`를 감시한다. 그런데 실제 잔차 스트림(boot 모델):

```
phase A (fault, t0..15):  84, 0.2, 26, 28, 13, 36, 40, 32, 15, 43, 59, 23, 84, 8, 28, 42   (평균 ~36)
phase B (zone, t16..24):  8, 12, 6, 41, 26, 8, 8, 13, 8                                     (평균 ~14)
```

- **drift 이후 잔차가 오히려 더 작다.** 이유: surrogate는 좋은 RANKER지만 값(closed) 회귀는 노이즈가 커서,
  잔차가 drift가 아니라 회귀오차에 지배된다(phase A는 regret 0인데도 잔차가 최대 84).
- 그래서 CUSUM(slack=8, thresh=60)은 **t=0부터 발화**(84>68) → phase A 내내 spurious 발화.
  E3의 "복구 1스텝"은 정밀 감지가 아니라 **verify-all escalation 안전망**이 만든 결과였다.

## 발견 2 — ADWIN은 짧은 스트림에서 원리적으로 발화 불가
- kind_zoneblk(완벽한 0→1 계단)조차 25스텝(post-drift 9개)에선 ADWIN이 발화 못 한다.
- 이유(수식): 16-vs-9 분할에서 Bernstein ε_cut ≈ 2.07 > 신호 최대치 1.0. δ를 키워도 ε_cut>1.
  **ADWIN의 엄밀한 FP 보장이 요구하는 표본 최소치를 25스텝이 못 채운다.** 튜닝 실패가 아니라 근본 한계.
- river 기본값(clock=32, grace=10)은 수천 스텝용 → 짧은 스트림엔 clock=1, 작은 grace 필수(그래도 부족).

## 해결 — covariate-shift novelty 신호
실제 drift는 OOD 종류(fault→zone) 변화 = **covariate shift**. 상태 feature가 bootstrap 분포에서
얼마나 벗어났는지(RMS z-거리, ±8 클리핑)를 재는 novelty가 이를 깨끗이 잡는다(phase A ~1.1, phase B ~4.5).

---

## 결과 표

### SHORT stream (실제 E3, 25스텝, drift@16, post-drift 9) — ACTIVE 정책
| detector / signal | post-drift regret | recover | planner calls | fires | spurious |
|---|---|---|---|---|---|
| CUSUM / resid (legacy) | 0.111 | 1 | 57 | 4 | **3** |
| CUSUM / novelty | 0.222 | 2 | **41** | 2 | **0** |
| ADWIN / novelty | 1.000 | n/a | 25 | 0 | 0 |

- 레거시 CUSUM/resid: 4발화 중 **3발화가 spurious**(pre-drift). 57 calls 중 상당수가 헛escalation.
- CUSUM/novelty: spurious 0, calls 41(−28%), regret은 약간↑(감지 1스텝 느림). **신호 교체만으로 개선.**
- ADWIN/novelty: 짧은 스트림이라 발화 못 함 → frozen처럼 붕괴(post 1.0). = 발견 2.

### LONG stream (리샘플 120스텝, drift@60, 5시드 평균) — ACTIVE 정책 (compare_detectors.py)
| detector / signal | post-drift regret | recover | planner calls | fires | spurious | delay |
|---|---|---|---|---|---|---|
| CUSUM / resid (legacy) | 0.037 | 2.4 | 188.8 | 8.6 | **7.8** | 1.75 |
| CUSUM / novelty | **0.033** | 2.0 | 240.0 | 15.0 | 0.0 | **1.0** |
| **ADWIN / novelty** | 0.117 | 7.0 | **128.0** | 1.0 | **0.0** | 6.0 |
| **Conformal / novelty** | 0.057 | 3.4 | 206.4 | 10.8 | 3.2 | 2.4 |

(ADWIN/resid는 그리드에서 제외 — 잔차 신호로는 ADWIN도 거의 실패: 앞선 실행서 delay 19.4, regret 0.34.)

관찰(긴 스트림에서 비교가 공정해짐):
- **CUSUM/resid(레거시)**: regret은 낮으나 **spurious 7.8회**, 189 calls. 잔차 신호의 오탐 꼬리.
- **CUSUM/novelty**: regret 최저(0.033)·감지 최속(1)이지만, 지속되는 높은 novelty에 **15회 재발화** → 계속
  재학습 → **calls 최다(240)**. "수준(level) 임계"라 변화가 끝나도 계속 터진다.
- **ADWIN/novelty**: **1회만 발화**(변화점 감지 본연) → **calls 최소(128) + spurious 0**. FP 보장의 대가로
  감지가 느리고(delay 6) regret은 중간(0.117). 즉 **가장 적은 헛재학습으로 가장 싼 compute.**
- **Conformal/novelty**: ADWIN과 CUSUM의 **중간** — delay 2.4(빠름)·regret 0.057(좋음)·α 보장, 그러나
  고정 calibration의 novelty가 level 신호라 **재발화 10.8** + 작은 calibration으로 **spurious 3.2** → calls 206.

**한 줄**: novelty 신호 위에서 세 감지기가 갈린다 — CUSUM=빠름/재학습 남발, **ADWIN=한 번·최소비용·오탐0(느림)**,
Conformal=빠름·α보장(재발화·소량 오탐). compute가 비싼(각 ~70s) 이 과제에선 ADWIN/novelty의 **calls 128
(CUSUM/novelty 240 대비 −47%)**이 최저비용, Conformal은 짧은 스트림까지 커버하는 유일한 보장형 감지기다.

---

## 원리적 대안: Conformal test martingale (option b, 3번째 감지기)

`ConformalMartingaleDetector` 추가 — 고정 bootstrap novelty를 calibration으로 한 **online exchangeability 검정**:
conformal p-value(정상이면 Uniform) → mixture-power 베팅 → martingale M(M0=1) 축적 → **M ≥ 1/α 면 발화**.
Ville 부등식으로 **P(정상인데 오발화) ≤ α** 를 anytime-valid 보장. **knob = α 하나**(CUSUM의 slack/thresh 손튜닝 없음).

- **SHORT(25步) ACTIVE**: Conformal/novelty **post-drift 0.000 · recover 1 · 41 calls · spurious 1**(E3);
  E4 cell D도 **0.000 / 33 calls**. → **ADWIN이 발화조차 못 한 짧은 스트림에서 conformal은 발화하고 완벽 복구.**
  증거가 곱셈으로 쌓여(martingale) graceful하게 축적되기 때문. 단 **spurious 1**은 7-point bootstrap
  calibration이 작아 phase-A 오발화 — 보장은 calibration의 대표성만큼만 유효(작은 표본 함정, ADWIN과 공유).
- **LONG(120步, 5시드)**: Conformal/novelty **post-drift 0.057 · delay 2.4 · 206 calls · spurious 3.2** —
  ADWIN(느림·최소비용·오탐0)과 CUSUM(빠름·재발화 많음)의 **중간**. 빠르게 감지하고 α로 오탐을 통제하되,
  고정 calibration의 novelty가 level 신호라 재발화하고(10.8회) 작은 calibration 탓에 소량 spurious.
- 구현 함정(기록): sliding-window calibration은 동일한 post-drift 값(4.52)에 **자기 오염** → p가 0.5로 복귀 →
  발화 실패. **고정 bootstrap calibration**으로 해결. 19-arm mixture는 dilution(log19≈2.9)으로 약함 → 9-arm.

**세 감지기 요약**: CUSUM/novelty=빠름·재발화 많음(손튜닝 임계); ADWIN/novelty=1회·최소 compute·**짧은 스트림 불가**;
Conformal/novelty=**α 보장·손튜닝 없음·짧은 스트림 OK**·소량 spurious(calibration 한계). VLM 검증 스택의
conformal abstention과 수학 기반(교환가능성·Ville)을 공유 → drift 감지와 지각 검증을 하나의 conformal 틀로 통합 가능.

---

## 권고
1. **가장 큰 개선은 감지기 교체가 아니라 신호 교체**: residual → covariate novelty. 세 감지기 모두 정상화.
   → 이미 반영: e3 'active'·e4 cell D의 default를 CUSUM/novelty로 승격(위 표).
2. **감지기 선택은 목적에 따라**:
   - 최소 compute(헛재학습 0)·긴 스트림 → **ADWIN/novelty** (단 짧은 스트림 불가).
   - 최속 감지·최저 regret → **CUSUM/novelty** (재발화로 calls↑, 보장 없음).
   - **손튜닝 없는 통계 보장(α)·짧은 스트림까지 커버** → **Conformal/novelty** (재발화·소량 spurious 감수).
3. graded/장기 OOD 스트림에서 ADWIN·Conformal의 이점이 커진다(짧은 25스텝 toy는 세 감지기 모두를 압박).
4. Conformal은 VLM 검증 스택의 conformal abstention과 수학 기반(교환가능성·Ville)을 공유 → **drift 감지 +
   지각 검증을 하나의 conformal 틀로 통합** 가능(다음 연구 지점).
5. e3/e4/compare_detectors는 pluggable이므로 3감지기 × 2신호를 즉시 실험 가능.

## 재현 커맨드
```
python e3_drift.py oracle/out/e1_dataset.jsonl            # 레거시 + E3b 비교
python e4_ablation.py oracle/out/e1_dataset.jsonl         # 레거시 + E4b 비교
python compare_detectors.py oracle/out/e1_dataset.jsonl --long-len 120 --seeds 5
```
