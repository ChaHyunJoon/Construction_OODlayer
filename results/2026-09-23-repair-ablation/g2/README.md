# G2 — 존 복구 base ablation 음성 대조 (2026-09-23)

무료, 서비스 없음. 기존 translate-호출 오라클 픽스처(`tools/fixtures/oracle_zone_clear.json`,
`OracleZoneClear!` — `restage_all_blocked!` 로 먼저 시도하고 안 되면 `translate_whole_build!`
로 에스컬레이션)를 `REPAIR_ABLATION=none/translate/all` 세 팔에서 canonical 정책·
`DEMO_ROUTER=0`으로 돌렸다. 모델은 tractor.mpd, `DEMO_ZONE=1 DEMO_ZONE_SEED=1 DEMO_SEED=1`.

드라이버: `run_g2.sh`. 로그는 `log/{none,translate,all}.log`(디스크에만, 커밋 안 함).

## 결과

### none (기준)
```
[score] complete=true closed=287 n_zones=1 n_blocked=0 n_nav_goals=18 n_engulfed=0 n_agent_trapped=0 project_blocked=false
[ablation] level=none armed=true denied=0 exempt=4 ladder_zone_skipped=0 ladder_zone_fired=0 detail=exempt:monitor_record=1,exempt:policy_payload=2,exempt:reference_label=1
```
완주(closed=287/305), 9/22 S1 오라클 완주 방향과 일치(memory: zone 오라클 COMPLETE 287/305 —
숫자까지 같다). `denied=0`은 옳다(none 은 차단 목록이 비어 있다).

### translate
```
[score] complete=false closed=147 n_zones=1 n_blocked=2 n_nav_goals=85 n_engulfed=2 n_agent_trapped=0 project_blocked=true
[ablation] level=translate armed=true denied=0 exempt=4 ladder_zone_skipped=0 ladder_zone_fired=0 detail=exempt:monitor_record=1,exempt:policy_payload=2,exempt:reference_label=1
```
```
reject:ablated_primitive:translate_whole_build!
```

### all
```
[score] complete=false closed=147 n_zones=1 n_blocked=2 n_nav_goals=85 n_engulfed=2 n_agent_trapped=0 project_blocked=true
[ablation] level=all armed=true denied=0 exempt=4 ladder_zone_skipped=0 ladder_zone_fired=0 detail=exempt:monitor_record=1,exempt:policy_payload=2,exempt:reference_label=1
```
```
reject:ablated_primitive:restage_all_blocked!
reject:ablated_primitive:translate_whole_build!
reject:ablated_primitive:translate_whole_build!
```

## 어느 층에서 막혔는가 — **등록 층**(registration), 실행 층은 한 번도 안 닿았다

두 ablation 팔 다 `reject:ablated_primitive:...`(`minted_registration.jl` 의 텍스트 스캔,
`check_impl_conventions` 마지막 검사, ablated_names(REPAIR_ABLATION[]) 를 코드 AST 에서
찾는다 — `ablated_symbols_in`)가 나왔고, **`AblatedPrimitiveError`(실행 가드,
`repair_ablation.jl` 의 `_ablation_gate`)는 세 팔 어디에서도 안 나왔다** —
`[ablation]` 줄의 `denied=0`이 그 증거다(`denied`는 `_ablation_gate`가 던질 때만 오른다;
등록 거부는 이 카운터를 안 건드린다). 즉 픽스처의 impl_code 가 금지 이름을
**리터럴로** 담고 있어서 등록 검사가 실행 전에 항상 먼저 잡는다 — 브리프가 예상한 대로
("픽스처 경로가 등록 검사를 안 거치면 실행 층에서 막혀야 한다"의 반대 경우, 즉 등록 검사를
거치므로 등록 층에서 막힌다).

세부 시퀀스(로그로 재구성):
- **translate**: 1차 등록 시도가 `translate_whole_build!` 리터럴 때문에 거부 →
  프레임워크가 되먹임 재작성 1회를 쓴다(그 사유로 재작성된 코드에서 금지 심볼이 빠진 것으로
  보인다: `restage_all_blocked!`만 남는 버전) → 그 버전은 등록 성공(`registered=true`)하지만
  `restage_all_blocked!` 단독으로는 이 존을 못 비운다(`:restaged_all` 이 아님) → 에스컬레이션할
  `translate_whole_build!` 는 이미 빠졌으므로 본체가 `status=escalation_failed` 로 끝난다.
  결과: closed=54(이 결정 시점) → 이후 진행되던 다른 작업도 포함해 closed=147 에서 정지
  (`No progress for 3000 iterations. Terminating.`).
- **all**: 1차 거부는 `restage_all_blocked!`(전체 존재 자체가 금지) → 되먹임 재작성 1회 →
  재작성본에도 `translate_whole_build!` 가 남아 있어 2차도 거부 → 되먹임 예산 소진,
  `verdict=reject registered=false` → `[minted] NOT handled → 기본 복구 사슬로 폴백` →
  같은 closed=147 에서 정지.

둘 다 **차단이 확인됐다**(reject:ablated_primitive 가 나왔다) — STOP 조건(둘 다 안 나옴)은
해당 없음.

## DEMO_SYNTH_FIXTURE 는 canonical(DEMO_ROUTER=0) 경로에서 실제로 집행된다 — 무효화 아님

`none` 팔의 로그에 배너와 집행 증거가 그대로 있다:
```
🔴🔴🔴 [synth-fixture] ORACLE BYPASS ACTIVE — 이 판의 합성 레인은 모델이 쓴 것이 아니다
...
[minted] lane=present tool=OracleZoneClear verdict=admit ... registered=true ...
  steps=[OracleZoneClear!:translated]
```
즉 `synth_fixture_lane`(`policy.jl`)이 `decide_all` 안에서 라우터 여부와 무관하게 매 결정마다
불리고(`render_demo.jl` 은 `decision.synth_lane` 을 그대로 `enact_minted_decision!` 에 넘긴다 —
`tools/monitor/render_demo.jl:936`), canonical 정책(`DEMO_ROUTER=0 DEMO_POLICY=canonical`)에서도
픽스처가 모델 출력 자리를 대신 채워 등록→집행을 그대로 지난다. 코드 확인(policy.jl:1955-2011,
2606-2615)과 실측(위 배너+`[minted]`+완주 287/305) 둘 다 일치 — 음성 대조는 유효하다.

## 🔴 PIN / set_env 실측 — Task 12–13 에 결정적

`campaign.py init` 을 스크래치 GRID_OUT 에 두 번 돌려 확인했다(런 launch 없음 — `cmd_init` 은
`campaign.json` 만 쓴다, `tools/monitor/grid/campaign.py:296-330`):

- `REPAIR_ABLATION` 이 **환경에 없을 때** init → `set_env.REPAIR_ABLATION = "none"`
  (Task 8 이 넣은 `CONFIG_ENV_PINNED_DEFAULTS["REPAIR_ABLATION"]="none"`, `policy.jl:985`).
- `REPAIR_ABLATION=all` 을 **init 호출 전에 export** → `set_env.REPAIR_ABLATION = "all"`
  (raw env → `CONFIG_ENV_RESULT` 멤버라 그대로 실린다, `policy.jl:924`).

브리프의 PIN 문자열(9/23 sol campaign `results/2026-09-23-router-sol-tractor/campaign.json`의
`set_env`에서 DSPY_URL만 뺀 것, `code_rev=e326b43d`)에는 **REPAIR_ABLATION 이 없다** — 그 campaign
은 Task 8(REPAIR_ABLATION 추가, 커밋 `28a0b929`·`f59fa7e9`) **이전** 코드로 초기화됐기 때문이다
(당시 `policy.jl` 에 그 줄 자체가 없었다). 오늘 같은 lanes/cases로 `init` 하면 `set_env` 에
`REPAIR_ABLATION=none`(핀 기본값)이 **추가로** 들어간다 — PIN 은 그 한 줄만큼 낡았다.
G2 자체는 영향 없다: `run_g2.sh`는 `campaign.py`를 거치지 않고 `julia render_demo.jl`을
직접 부르며 같은 `env` 호출 안에서 `REPAIR_ABLATION=$lvl`을 명시하므로 아무것도 그것을 지우지
않는다.

🔴 **Task 12–13 을 위한 결정적 발견**: `run_one.sh`/`render_one.sh` 는 실제 env 조립을
`campaign.py run-one` (`cmd_run_one` → `run_env()`, `campaign.py:105-120`) 에 전부 위임한다.
`run_env()` 는 **`CONFIG_ENV_RESULT`∪`CELL_AXIS`∪`OBSERVATIONAL` 이름(및 그 접두사)을 부모
env 에서 통째로 지우고 `camp["set_env"]`(= `campaign.py init` 시점에 얼린 값)만 다시 넣는다.**
`REPAIR_ABLATION` 은 Task 8 이 `CONFIG_ENV_RESULT` 에 넣었으므로 이 삭제 대상이다.

⟹ **`run_one.sh`/`render_one.sh` 호출 시점(또는 그 셸의 환경)에 `REPAIR_ABLATION=all` 을 export
해도 완전히 무시된다** — `run_env()` 가 지우고 `campaign.json` 의 `set_env`(= init 시점 값)로
덮어쓴다. `translate`/`all` 격자를 돌리려면 **`campaign.py init` 을 부르기 전에** 셸에서
`REPAIR_ABLATION=<level>` 을 export 해야 그 값이 raw env → `set_env` 로 얼어 들어간다.
init 이후에 바꾸려면 새 GRID_OUT 으로 다시 init 해야 한다(같은 grid 디렉터리에 이미 있는
`campaign.json` 은 `code_rev`/`config_digest` 가 다르면 재사용을 거부한다).
실측: 위 두 스크래치 init 호출로 이 메커니즘을 직접 확인함(REPAIR_ABLATION 미설정 → `none`,
export 후 → `all`, 둘 다 스크래치 GRID_OUT 이라 어떤 런도 launch 되지 않았다).

## 파일

- `run_g2.sh` — 드라이버(커밋됨)
- `log/{none,translate,all}.log` — 전체 stdout/stderr(디스크에만, `results/*` gitignore)
- `anim/`, `streams/` — render_demo.jl 부산물(디스크에만)
