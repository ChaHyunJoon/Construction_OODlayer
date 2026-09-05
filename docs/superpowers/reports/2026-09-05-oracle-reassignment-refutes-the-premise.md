# 오라클 실험: "올바른 재배정" 이 `min_soc` 을 올리는가 — **아니오**

2026-09-05. 커밋 `b99c2ce3`(우회·픽스처). 산출물은 `results/oracle-fixture-bsoc085.log` 외.
🔴 이 문서가 정본이다 — `.superpowers/sdd/` 는 gitignore 라 거기 보고서는 사라진다.

## 0. 왜 이 실험을 했나

유료 LLM 런 **다섯**이 전부 body 가 세계에 닿기 **전에** 죽었다(식별자 환각 네 겹).
그래서 이 레포는 **"body 가 끝까지 돌면 무슨 일이 일어나는가" 를 한 번도 관측한 적이 없었다.**
실험 전체가 "낮은 SoC 로봇의 일을 덜어 주면 최종 `min_soc` 이 올라간다" 는 전제 위에 서 있는데,
그 전제가 참인지 아무도 안 쟀다. LLM 을 빼고 **손으로 쓴 이상적 body** 로 먼저 답했다.

## 1. 답 — 🔴 아니오. 그리고 반올림 오차가 아니라 **build 가 교착된다**

| 축 | 대조 (tool 없음) | 처치 (`OracleReassign!`) |
|---|---|---|
| 완주 | **PROJECT COMPLETE** | 🔴 **PROJECT INCOMPLETE** (`No progress for 3000 iterations`) |
| `t` / `n_closed` | 1024 / 287 | 🔴 **7599 / 230** |
| **`min_soc`** | 0.14903023505908294 | 🔴 **0.14738418656567573** (−0.00164603) |
| `energy_J[R1]` (대상) | 8029.653710929057 | 🔴 **21658.93523708728** (2.70×) |
| `total_energy_J` | 82386.00929140419 | 🔴 **227495.7777924389** (2.76×) |
| `soc_spread` | 0.850969764940917 | 0.8526158134343242 |

**척도 무관 헤드라인** `N = 1 − ΔE_처치/ΔE_대조` (사건 후 `energy_J[대상]` 증분):
`t=151` 기준 **N = −2.1307** · `t=101` 기준 **N = −1.9947**. 성공 방향은 `N > 0` 이었다.

🔴 **사전등록한 상승 폭은 `0.14903 → 0.14980` 이었다. 실측 하락 폭이 그 밴드의 ~2배다.**
"최악이라도 개선이 없을 뿐" 이라는 사건 설계의 가정이 **거짓**이다 — 개입에는 밴드가
모형화하지 않은 큰 하방이 있다.

## 2. 🔴 사상 처음으로 L4 가 0 이 아니다

`world_delta_body` (다섯 축, `body_scope=body_only(probed)` — 하네스가 손대기 **전** 창):

```
closed=0  active=0  n_edges=-2  n_binding_changed=8  n_weights_changed=0
```

**이 레포에서 주조 body 가 세계를 바꾼 것이 관측된 첫 판이다.** 봉투(`world_delta`,
body+재풀이)는 `n_edges=0 n_binding_changed=5`.

## 3. MILP 가 일을 되돌려줬나 — **아니다. 기전은 작동한다**

- `release_pending_assignments!(env, inv; agent = string(ood_event_target()))` 가 간선 **2개** 제거.
- 좁힘이 광고대로 작동: `n_candidate_edges=19` (전체 release 는 ~364 후보로 60초를 태우고도
  최적성 증명 실패). `resolve=resolved`, `TIME_LIMIT` 없음.
- 재풀이가 슬롯 **9개** 재배정. 흐트러진 binding **8** 중 **5** 가 사건 전과 **다른 로봇**에 묶였다.
  되돌려줬다면 봉투가 `n_binding_changed=0` 이었을 것이다.
- **물리적 직접 확인** (`t=251`, 에너지가 처음 갈라지는 프레임):

| 로봇 | 대조 | 처치 | Δ |
|---|---|---|---|
| **R1** (OOD 대상) | 2398.9429 | 2394.2400 | **−4.7029 J** |
| **R10** | 2132.7589 | 2144.9524 | **+12.1935 J** |

일이 진짜로 옮겨갔다. ⟹ **실험이 기대던 기전은 작동한다. 다만 값이 안 맞는다** —
R10 이 R1 이 아낀 것의 **2.6배**를 냈고, 그것도 교착 **전**에.

## 4. 왜 죽었나

- `n_closed` 가 사건 다음 프레임부터 갈린다: `t=351` 203 vs 199 · `t=601` 234 vs 219 ·
  `t=1001` 283 vs **219**. 처치는 `t=4601` 에 230 까지 기어가고 **그 뒤 전혀 진전이 없다.**
- 최종 프레임: 로봇 **6대가 `CARRY`/`TransportUnitGo` 에 얼어붙음**, R1 은 `TRANSIT`/`RobotGo`,
  `n_active=17`, `recovery=[]`, `handoffs=[]`. 전원의 `energy_J` 가 정확히 **2.5 J/step**
  (= 유휴 바닥 100W × 1/40s)로만 오른다. **아무도 안 움직인다 — 느린 진전이 아니라 경성 교착이다.**
- 헤드라인 수치는 전부 여기서 나온다: R1 의 21.7 kJ 중 **~13.6 kJ 가 교착된 세계에서의 방전**이고,
  `min_soc` 이 떨어지는 것은 그 로봇이 **6575 스텝을 더 앉아서 방전**했기 때문이다
  (mild 라 `SwapBattery` 팔이 메뉴에 없다).
- ⚠️ 교착의 **원인** 자체는 아직 가설이다: `reset_slot_to_invalid!` 로 비운 슬롯의 낡은 id 전파.
  `release_pending_assignments!` 의 `KNOWN-OPEN` 문단이 그 실패 부류를 적지만 `faulted=` 경로에
  대한 것이고, 여기서 쓴 것은 `agent=` 경로다. **측정 안 했다.**

## 5. 🔴 귀속 대조 — 하네스는 무죄다

두 번째 픽스처 `OracleNoRelease!`: **같은 레인 · 같은 `surface="sched"` · 같은 등록 ·
같은 규약 검사 · 같은 `calls` 바인딩 · 같은 `invokelatest` · 같은 `reset_cache_resume!` ·
같은 MILP 재풀이 — 간선만 0개 푼다.**

결과: `PROJECT COMPLETE!`, 그리고 스트림이 **대조와 21프레임 전부 모든 물리 축에서 비트 동일**
(`min_soc`·`energy_J[R1]`·`total_energy_J`·`t`·`n_closed` 전부 일치). 다른 것은
`respec`/`respec_history`(tool 자신의 기록)뿐이다.

⟹ **등록 · 집행 봉투 · `handled=true` 가 기본 복구 사슬을 건너뛰는 것 · 캐시 재개 · 하네스
MILP 재풀이 — 전부 무죄.** 교착의 원인은 정확히 하나다: **풀린 간선 2개와 그로부터 MILP 가
만든 재배정.**

## 6. 귀결 — 병목은 LLM 이 아니다

🔴 **오라클이 이미 이상적인 tool 을 썼다. LLM 을 고쳐서는 이 결과를 못 바꾼다.**
남은 질문은 "모델이 잘하는가" 가 아니라 **"이 세계에서 mild battery 를 완화하는 개입이
존재하는가"** 다.

그리고 방법론적 결함 하나가 드러났다:
🔴 **사전등록한 헤드라인 `min_soc` 은 `PROJECT INCOMPLETE` 에서 빨개질 수 없다.**
build 가 교착으로 죽었는데 지표는 "조금 낮아짐" 이라고만 말한다.
⟹ **완주는 가드레일이 아니라 차단 게이트로 올려야 한다**: 미완주면 그 판의 에너지 수치는
비교 대상이 아니다(유휴 방전이 지배한다).

⚠️ 대상이 **미래 간선을 2개밖에 안 갖고 있다**는 것도 사건 설계의 문제다 — 덜어 줄 것이 그것뿐인데
덜어내는 대가가 수송 팀 해체라면 구조적으로 순손실이다.

## 7. 다음 후보 — `forbid_heavy_cargo!`

`release` 는 **진행 중인 수송을 뜯어서** 교착시킨다. 사용자가 원한 것은
*"낮은 SoC 로봇을 가벼운 payload 에 배정"* 이고, 그 원시가 이미 있다:
`forbid_heavy_cargo!(env; agent::AbstractString = "", n::Real = 1)`
(`src/respec/cargo_ban_primitive.jl`). 위치인자가 `env` 하나, kwarg 전부 기본값 ⟹ 주조 규약에
맞고 `InvariantSpec` 도 필요 없다. **미래 배정을 제약**할 뿐 진행 중인 수송을 안 뜯는다.
감춘 다섯 중 하나였다. → 후속 실험.

## 8. 비용 정정

🔴 **"대조 런은 무료" 는 틀렸다.** 8078 은 합성만 꺼져 있고 escalation 경로는 여전히 HTTP 로
dspy 레인을 탄다 — `/health` 의 `billed` 가 런당 1씩 올랐다(런 2건 = gpt-4o `/macro` 2건,
`cache:false`). 인과적으로 무관하지만(`handled=true` 가 `macro_to_proposal` 을 건너뛴다) 공짜가 아니다.

## 9. 우회 장치 — `DEMO_SYNTH_FIXTURE`

`tools/monitor/policy.jl` 의 `SYNTH_FIXTURE_PATH` + `synth_fixture_lane`, `decide_all` 에서 호출.
- **기본 꺼짐** — 빈 환경변수면 `sl` 을 그대로 반환한다(검증됨: 출력 0).
- **조용할 수 없다** — 결정마다 `🔴🔴🔴 ORACLE BYPASS ACTIVE` 6줄 배너(경로 · `sha256[1:16]` ·
  `impl_name` · `body_names` · `surface` · 덮어쓴 키 · 무시한 키)를 찍고 `rt["synth_fixture"]` 로
  결정 행/스트림에도 도장을 남긴다.
- **폴백하지 않는다** — 읽기 실패·비 JSON 이면 `error(...)` 로 런을 죽인다. 조용한 폴백은
  "모델이 아무것도 안 냈다" 와 바이트 구별이 안 된다(이 레포 최악의 실패 모드).
- **어떤 게이트도 안 낮췄다** — 픽스처가 `check_impl_conventions` 를 그대로 통과했다
  (`registered=true`, `impl_rejected_why=n/a`, `args_from=calls`, `n_calls=1`).

---

# 부록 A — 계열 완결: O2·O3 (2026-09-05)

## A.1 세 실험 요약

| 개입 | `n_candidate_edges` | `cargo_ban_rows` | **N** | 완주 | `min_soc` |
|---|---|---|---|---|---|
| 대조 | — | — | — | COMPLETE | 0.14903023 |
| **O1** release 단독 | 19 | (금지 없음) | **−2.1307** | 🔴 INCOMPLETE | 0.14738419 |
| **O2** ban 단독 | **0** | 0 (추정) | **0.0** | COMPLETE | 0.14903023 (동일) |
| **O3** 조합 | 19 | **3** | 🔴 **−3.5152** | 🔴 INCOMPLETE | 🔴 **0.14631460** |

`N = 1 − ΔE_처치/ΔE_대조`, 기준 프레임 `t=151`. `N > 0` 이 성공 방향.

## A.2 O2 — 제약 단독은 붙을 표면이 없다

`forbid_heavy_cargo!` 가 `:banned` 를 냈고 금지가 실제로 기록됐고 MILP 도 실제로 재풀었다.
그런데 스트림이 대조와 **21프레임 비트 동일**이고 `N = 0.0` 정확히다. 로봇별 최종 `energy_J`
차이가 **전원 `+0.000`**.

원인은 한 숫자다: **`n_candidate_edges=0`**. 재풀이가 만든 MILP 에 배정 결정변수가 **아예 없어서**
`_heavy_cargo_targets` 가 순위 매길 것이 없었고 금지가 **0행**으로 컴파일됐다.
🔴 `:banned` 를 성공으로 읽지 않고 독립 확인했다 — 부담 계층 부재 `@warn` 0건, `ran_milp=true`,
프레임 단위 diff.

⟹ **후보 간선을 만드는 유일한 것이 O2 가 피하려던 바로 그 release 다.**
"미래를 제약한다" 와 "현재를 푼다" 는 대안이 아니라 **짝**이다.

## A.3 O3 — 조합은 살아났고, 그래서 더 나빠졌다

**양쪽 다 발화했다** [측정]: `n_candidate_edges=19` **그리고** `cargo_ban_rows=3`.
이 계열에서 금지가 처음으로 **0이 아닌 행**을 컴파일했다. 기전에 대한 가설은 **정확히 맞았다.**

🔴 **그런데 금지가 붙은 결과가 목적의 정반대였다.** release 단독이 일을 옮겼던 바로 그 프레임
(`t=251`: R1 −4.70 J / R10 +12.19 J)에서, 조합 런은 **대조와 에너지가 동일하다** — R1 이 화물을
그대로 들고 있다. 금지 3행은 MILP 가 R1 에게 **더 가벼운** 일을 주게 만든 것이 아니라
**같은 일을 되돌려주게** 만들었고, release 가 이룬 유일한 성과를 취소했다.
그 뒤 전과 같이 교착했고, 로봇당 ~200 J 의 유휴 방전이 더 얹혀 모든 헤드라인이 단독 개입들보다 나쁘다.

## A.4 🔴 계열의 결론

> **광고된 어휘의 어떤 조합으로도 이 시뮬레이터에서 mild battery 로봇을 구제할 수 없다.**

고칠 대상은 **LLM 도 어휘도 아니고 사건 설계**다. 근거 셋:
1. 오라클이 이미 이상적 도구를 썼다 — 모델 품질은 이 결과를 못 바꾼다.
2. 귀속 대조(`OracleNoRelease!`, 간선 0개, 21프레임 비트 동일)가 하네스를 무죄로 만들었다.
3. 세 개입이 사건의 개입 공간을 사실상 덮는다: 푼다 / 제약한다 / 둘 다.

⚠️ 그리고 사건 자체가 구조적으로 척박하다 — 대상이 **미래 간선을 2개**밖에 안 갖고 있어
덜어 줄 것이 그것뿐인데, 덜어내는 대가가 수송 팀 해체라 **순손실**이다.

## A.5 → zone 으로 간다

| | mild battery | zone |
|---|---|---|
| 기본 결과 | COMPLETE (손상이 없다) | 🔴 **INCOMPLETE, `n_closed=270/305`** [측정] |
| 개입 여지 | 미래 간선 2개 | build 전체가 막혀 있다 |
| 복구 원시 | 광고됨 — **셋 다 실패** | `restage_all_blocked!` · `translate_whole_build!` · `add_restriction_zone!` · `clear_restriction_zones!` 광고됨 |
| 합성 발화 | `expressible=False` ✅ | ✅ 가능 — `valid_macros` 의 zone 분기가 `["NOOP"]` 을 내므로 `dspy_service.py` 의 `if not tools` 가 **단락되지 않는다** |
| 필요성 주장 | 불가(대조도 완주) | **가능** — 대조는 미완주라 `render_demo.jl` 이 발행 자체를 거부한다 |

명령줄 [측정]: `DEMO_MODEL=tractor.mpd DEMO_OOD=none DEMO_ZONE=1 DEMO_CASE_TAG=zone_mild
DEMO_POLICY=dspy DEMO_ANIM=0` — 🔴 `DEMO_OOD=none` 이 **필수**다(`DEMO_OOD=zone*` 은
`case_kinds` 에서 하드에러).

🔴 **zone 에서도 유료 런 전에 오라클을 먼저 돌린다.** 이 규율이 mild 에서 유료 런 세 판을 아꼈다.
