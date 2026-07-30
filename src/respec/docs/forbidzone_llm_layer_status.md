# ForbidZone LLM 레이어 (STEP 5) — 구현·검증 상태 / 핸드오프

자동 작업 세션 산출물. ForbidZone OOD 를 **자연어 → LLM 분류·grounding → 타입 DSL → verify →
기하 복구** 로 흘리는 레이어를 Stage 1~3 구현. 상위 설계는 같은 폴더의 plan(대화) 참조.

## TL;DR

- **Stage 1 (Julia bridge + verifier)** — 구현·로드·단위테스트 **9/10** (핵심 전부 green).
- **Stage 2 (mock full-loop e2e)** — **PASS**. 문서상 "⑦ enabled full-loop e2e: never run"이던 걸
  ForbidZone 경로로 **처음 enabled-loop 으로 통과**: NL→push_ood!→respec_step!→mock LLM→ForbidZone
  →verify_zone→restage_all→whole-build(Δ=10.78)→완주, zone 재진입 0(대피 transient만).
- **Stage 3 (Python 실 LLM)** — schema/prompt/server 편집 + **deps 설치 완료**(anthropic/fastapi/
  uvicorn → venv hjcrl) + **런타임 import & Pydantic ForbidZone 검증 & 프롬프트 통과**. 남은 건
  *실 Claude 호출 1건*뿐 — 그건 키가 자동 세션 프로세스에 안 보여 불가, turn-key 로 준비됨(아래).

## 역할 (요약)

LLM = **분류기 + grounder**: NL 이벤트가 (a) 로봇고장→ForbidAgent (b) 공간 no-go→**ForbidZone**
(c) 시간창→ForbidWindow 중 무엇인지 고르고, 모호한 표현을 정확한 id/zone키로 매핑. **좌표·이동량·
feasibility 는 안 만짐** — 그건 기하(restage/whole-build)와 verifier 가 쥠. "LLM 불신·기하 우선" 유지.

## 흐름

```
add_restriction_zone!(:zone,…) + NL emit → push_ood! → respec_step! → maybe_respecify!
  → llm_to_proposal(NL,env)  [요청: open_ids/agents/nodes/+ZONES]
       LLM: 분류=ForbidZone, ground(assembly,zone) → RespecProposal([ForbidZone(asm,:zone)])
  → verify_zone(static 닫힌노드 + zone-키 존재)  [Reject→fallback]
  → restage_all_blocked! → (residual) translate_whole_build!  → :admitted / :noop / :fallback
```

## 변경 파일

**Julia**
- `src/respec/llm_bridge.jl` — `_parse_proposal` 에 `ForbidZone` 분기; 요청 body 에 `"zones"`;
  신규 `open_zone_descriptors(env)`(활성 zone: key/center/radius/covers/covers_root).
- `src/respec/verifier.jl` — `referenced_ids(::ForbidZone)`; 신규 `verify_zone(proposal,env)`
  (static 닫힌노드 + 모든 ForbidZone.zone 키가 RESTRICTION_ZONES 에 존재하는지).
- `src/respec/replan.jl` — `_is_zone_respec` dispatch 앞에 `verify_zone` 게이트(Reject→fallback).
- (기존) ForbidZone DSL `spec_dsl.jl`, dispatch·restage·translate_whole_build! 는 이미 완비.

**Python (`src/respec/llm_service/`)**
- `schema.py` — `ForbidZone` Pydantic + ConstraintSpec union + tool enum/properties(zone,assembly).
- `propose.py` — 프롬프트에 ACTIVE NO-GO ZONES 섹션; "zone→ForbidWindow" 오유도를
  "spatial→ForbidZone / temporal→ForbidWindow / fault→ForbidAgent" 분류 가이드로 교정; `zones` 전달.
- `server.py` — `ZoneRef` 모델 + `ProposeRequest.zones` + propose() 에 전달.

**드라이버/테스트 (`tools/`)**
- `test_forbidzone_parse.jl` — LLM-free 단위(파서·verify_zone·open_zone_descriptors). 9/10.
- `mock_respec_e2e.jl` — LLM-free full-loop e2e(로컬 mock /propose → respec_step! → 복구 → 완주).
- `demo_respec_forbidzone_anim.jl` — MeshCat 시각 demo. `USE_MOCK=1`(기본, 키 불필요) / `USE_MOCK=0`(실 LLM).
- `test_llm_classification.jl` — 실 LLM 분류 정확도(zone/fault/window 3종).

## 검증 상태 (이 세션)

- 단위 `test_forbidzone_parse.jl`: **9/10**. 실패 1 = `[5] 미지 assembly id throw` — 안 throw됨.
  내가 안 건드린 `_default_id_resolver` 거동이고, **ForbidZone 은 assembly 를 dispatch 가 안 쓰므로 안전 무관**
  (실제 게이트는 verify_zone 의 zone-키 존재, 통과). 검토 권장(ForbidWindow/Agent 에도 영향이면 별도 이슈).
- Stage 2 `mock_respec_e2e.jl`: **PASS** (closed→완주, evac transient만). 이 통합이 실 LLM 경로에도
  영향을 주던 버그 2개를 노출·수정:
  1. **precompile-baked const**: `_RESPEC_SERVICE_URL`(const)가 precompile 때 8000으로 굳어 런타임
     `ENV["RESPEC_SERVICE_URL"]` override 무시 → `_respec_service_url()` 함수로 변경(호출 시 ENV 읽음).
  2. **grounding 불일치**: `open_zone_descriptors`의 `covers`가 raw AssemblyID 라 `_default_id_resolver`
     가 못 풂 → AssemblyComplete **노드 id 문자열**(open_node_descriptors 와 동일)로 변경.
- 시각 demo(mock): `demo_respec_forbidzone_anim.jl USE_MOCK=1` → `results/tractor/.../visualization.html`.

## 실 LLM(Stage 3) 실행 — turn-key (당신 키 세션에서)

자동 세션에선 **API 키가 안 보였습니다**(당신 대화형 PowerShell 세션 한정, 새 프로세스 미상속).
**deps 는 설치 완료**(`anthropic fastapi uvicorn` → venv hjcrl) + Python 서비스 import/검증 통과라,
당신 키 세션에서 아래 한 줄로 바로 띄워집니다.

**가장 쉬운 길 (한 줄)** — 키 있는 PowerShell, repo 루트에서:
```powershell
.\tools\run_real_llm_demo.ps1   # 서비스 기동→health 대기→실 LLM 시각 demo→정리
```

또는 수동으로:
```powershell
# 1) 서비스 (키 있는 셸)
cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl\src\respec\llm_service
uvicorn server:app --host 127.0.0.1 --port 8000

# 2) 분류 정확도 (다른 셸, 키 있어도 없어도 무방 — Julia는 서비스만 호출)
cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
julia +lts --project=. tools/test_llm_classification.jl

# 3) 실 LLM 시각 demo
$env:USE_MOCK="0"; julia +lts --project=. tools/demo_respec_forbidzone_anim.jl
```
주의: uvicorn 은 venv hjcrl 의 python 이어야 함(설치한 곳). 서비스 셸에 ANTHROPIC_API_KEY 필요.

## 남은 일 / 검토

1. test[5] `_default_id_resolver` 미지 id throw 안 함 — 확인(다른 제약엔 영향?).
2. 실 LLM 분류 정확도 측정(위 2) + 오분류 시 prompt 튜닝.
3. verify_zone 을 "복구 feasibility 드라이런"까지 강화할지(현재는 dispatch try-and-fallback 에 위임).
4. relocation hint(의미적 이전 방향) — 인터페이스만, tractor 에선 효과 제한적(root staging 이 footprint 덮음).

관련 메모리: 기하 복구 = [[constructionbots-wholebuild-phaseB]], OOD 생성 = [[constructionbots-ood-generation-design]].
</content>
