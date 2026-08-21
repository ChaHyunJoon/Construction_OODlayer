# =============================================================================
# llm_bridge.jl  --  thin HTTP client to the separated Python LLM service.
# =============================================================================
#
# The LLM layer is a standalone Python process (src/respec/llm_service/). Julia
# only POSTs {event, open_ids} and receives a validated DSL proposal as JSON.
# The anthropic call, prompt, and tool schema all live in Python; Julia keeps
# ONLY the typed parse below — that, plus verify(), is the safety boundary that
# must stay on the solver side. Python proposes; Julia validates and admits.
#
# Service URL (default http://127.0.0.1:8000) overridable via RESPEC_SERVICE_URL.
# Requires: HTTP, JSON3 (Julia side). No anthropic dependency in Julia anymore.
# -----------------------------------------------------------------------------
# [한국어 설명]
# 이 파일은 별도 파이썬 LLM 서비스(src/respec/llm_service/)로의 얇은 HTTP 클라이언트.
# 프로젝트 역할: 줄리아는 {event, open_ids 등}만 POST 하고, 검증된 DSL 제안을 JSON 으로 받는다.
# anthropic 호출·프롬프트·tool schema 는 전부 파이썬에 있고, 줄리아는 아래의 "타입 있는 파싱"만 담당.
# 이 파싱 + verify() 가 solver 쪽에 남아야 하는 안전 경계 — 파이썬은 제안만, 줄리아가 검증·수용.
# 서비스 주소는 기본 http://127.0.0.1:8000, 환경변수 RESPEC_SERVICE_URL 로 덮어쓸 수 있음.
#
# [문법 참고] (줄리아의 덜 익숙한 기능들)
#   · function f(x::T) — x 가 타입 T 일 때만 적용되는 메서드(다중 디스패치). 같은 이름 여러 정의 가능.
#   · `!` 로 끝나는 함수(push!) — 인자를 직접 수정(in-place)한다는 관례.
#   · :Symbol — 콜론으로 시작하는 값(가벼운 상수 라벨). 문자열과 달리 정체성 비교가 빠름.
#   · `A || B` / `A && B` — 단락 평가. `조건 || return`, `조건 && continue` 같은 관용구로 자주 씀.
#   · `A => B` — Pair(키-값 쌍). Dict("k" => v) 로 딕셔너리를 만든다.
#   · `$(...)` — 문자열 보간(파이썬 f-string 의 {}). `try ... catch; 기본값 end` — 한 줄 예외 처리.
# =============================================================================

# const 은 "이 이름은 한 번 정해지면 안 바뀐다"는 상수 선언(파이썬엔 직접 대응어 없음 — 사실상 전역 상수).
# get(ENV, "키", 기본값) : 딕셔너리 get 과 동일 — 환경변수 ENV 에 그 키가 있으면 그 값을, 없으면 기본값을 돌려줌.
# 즉 "환경변수 RESPEC_SERVICE_URL 이 설정돼 있으면 그걸 쓰고, 없으면 로컬 주소를 기본으로 쓴다".
# 호출 시점에 ENV 를 읽는 함수 — const 로 두면 precompile 때 기본값이 baked 되어 런타임 ENV override 가 무시됨
# (mock 서버 주소 지정 등이 안 먹는 함정). 함수면 매 호출마다 현재 ENV["RESPEC_SERVICE_URL"] 를 반영.
_respec_service_url() = get(ENV, "RESPEC_SERVICE_URL", "http://127.0.0.1:8000")  # 파이썬 LLM 서비스 주소(런타임 ENV 우선)

"""
    respec_service_ready() -> Bool

Ping the Python service's /health. Call this once before a simulation run so a
missing/down service is a clear startup error rather than a per-step fallback.
"""
# 함수 이름 끝의 `()` 안이 비었으니 인자 없는 함수. 반환 타입은 docstring 의 `-> Bool` 표기대로 참/거짓.
function respec_service_ready()
    # try ... catch ... end : 파이썬의 try/except 와 같음 — try 블록에서 에러가 나면 catch 블록으로 넘어감.
    try
        # HTTP.get(주소; 키워드인자...) : 그 주소로 HTTP GET 요청을 보냄. `*` 는 문자열 이어붙이기(파이썬의 + 에 해당).
        # `;` 뒤는 키워드 인자 — readtimeout(응답 대기 최대 3초), retries(재시도 0회).
        resp = HTTP.get(_respec_service_url() * "/health"; readtimeout = 3, retries = 0)
        return resp.status == 200   # HTTP 상태코드가 200(정상)이면 true, 아니면 false 를 돌려줌
    catch                            # 요청 중 어떤 에러든 발생하면(서비스가 꺼져 있는 등)
        return false                 # 서비스 준비 안 됨 → false
    end
end

"""
    llm_to_proposal(event, env; id_resolver) -> RespecProposal

POST the OOD event and the still-mutable node ids to the Python service and parse
the returned DSL JSON into a typed `RespecProposal`. Any failure (service down,
non-200, malformed body, unknown id, bad kind) THROWS — and the caller
(`maybe_respecify!`) treats a throw exactly like a Reject, engaging the safe
fallback. Failing loudly is correct: an unparseable proposal must never reach
the solver.
"""
# 인자 목록에서 `;` 앞은 위치 인자(event, env), 뒤는 키워드 인자(id_resolver) — 호출 시 id_resolver=... 로 줘야 함.
# id_resolver 는 "문자열 id 를 실제 줄리아 id 객체로 되돌리는 함수"를 통째로 인자로 받는 것(함수도 값처럼 전달).
function llm_to_proposal(event, env; id_resolver)
    # Dict(...) : 파이썬 dict. `"키" => 값` 의 `=>` 는 "키-값 쌍"을 만드는 Pair 연산자(파이썬의 `"키": 값` 에 해당).
    body = Dict("event" => String(event),                  # String(event) : event 를 문자열로 변환
                "open_ids" => open_node_id_strings(env),    # 아직 안 끝난 노드 id 문자열 목록
                "agents"   => open_agent_descriptors(env),  # 금지 가능한 로봇(에이전트) 설명 목록
                "nodes"    => open_node_descriptors(env),   # 시간창 금지를 걸 수 있는 마일스톤 노드 설명 목록
                "zones"    => open_zone_descriptors(env))   # 활성 출입금지 구역 설명(ForbidZone grounding 용)
    # HTTP.post(주소, 헤더목록, 본문; 키워드...) : 그 주소로 HTTP POST 요청을 보냄.
    resp = HTTP.post(
        _respec_service_url() * "/propose",                # 제안(propose)을 요청하는 엔드포인트 주소(런타임 ENV)
        ["content-type" => "application/json"],            # 요청 헤더: 본문이 JSON 형식임을 명시
        JSON3.write(body);                                 # body(Dict)를 JSON 문자열로 직렬화해 본문으로 전송
        readtimeout = 30, retries = 0,                     # 최대 30초 대기, 재시도 없음
    )
    # `A || B` : 단락 평가 — A 가 참이면 거기서 끝, A 가 거짓일 때만 B 를 실행. (파이썬 `A or B` 와 유사)
    # 여기선 "상태가 200이면 통과, 아니면 error(...) 로 예외를 던져라"는 흔한 줄리아 관용구.
    resp.status == 200 || error("respec service returned HTTP $(resp.status): $(String(resp.body))")
    # `$(...)` : 문자열 안에 값을 끼워 넣는 보간(파이썬 f-string 의 {} 와 같음).
    payload = JSON3.read(resp.body)                        # 응답 본문(JSON)을 줄리아에서 다룰 수 있는 객체로 파싱
    # sched 를 넘겨 파싱 단계에서 참조 접지까지 확인한다(MILP 를 세우기 전에 걸린다).
    return _parse_proposal(payload, event; id_resolver = id_resolver, sched = env.sched)
end

"""
    open_node_id_strings(env) -> Vector{String}

The schedulable, NOT-yet-closed node ids, stringified the same way the
id_resolver reverses them. Closed nodes are filtered out so the model cannot
even reference completed work — the "completed work is invariant" rule enforced
at the prompt boundary, before the verifier re-checks it.
"""
function open_node_id_strings(env)
    sched = env.sched                       # env 의 sched 필드(조립 스케줄 그래프)를 꺼내 짧은 이름에 담음 (`.` 은 필드 접근)
    ids = String[]                          # 빈 문자열 배열 생성. `타입[]` 은 "그 타입의 빈 벡터"(파이썬의 [] 인데 원소 타입 지정).
    # for ... in ... : 파이썬 for 와 동일. Graphs.vertices(sched) 는 그래프의 모든 정점(노드)을 순회.
    for v in Graphs.vertices(sched)
        # `A && continue` : A 가 참이면 continue(이번 반복 건너뛰기) 실행. (`&&` 는 파이썬 and 의 단락 버전)
        # 즉 "이 노드가 이미 끝난(closed) 집합에 속하면 건너뛴다" — 완료된 작업은 LLM 에 노출하지 않음.
        v in env.cache.closed_set && continue
        # push!(배열, 값) : 배열 끝에 값 추가(파이썬 list.append). 끝의 `!` 는 배열을 직접 바꾼다는 관례 표시.
        push!(ids, string(get_vtx_id(sched, v)))  # 정점 v 의 id 를 문자열로 바꿔 목록에 추가
    end
    return ids                              # 아직 안 끝난 노드 id 문자열 목록 반환
end

"""
    open_agent_descriptors(env) -> Vector{Dict{String,String}}

The robots (agents) the model may forbid, one entry per distinct robot as
`{"id", "label"}`:
  * `id`    -- the EXACT `RobotID` string the `ForbidAgent.agent` field must echo,
               so `_default_id_resolver` can reverse it (built from `string(rid)`,
               never hand-written, so it stays in lockstep with the resolver).
  * `label` -- a human alias ("Robot R3 / robot 3") so the model can ground a
               natural-language fault report ("Robot R3 is immobile...") onto the
               opaque id. This is the missing link that made ROUND 1 fail: the
               flat node-id list never told the model which id is "R3".

Enumerated from `RobotGo` nodes (every robot has at least one), where
`entity(node).id` is known to be the agent's `RobotID` (same access the
ForbidAgent compiler's `bound_to_agent` uses).
"""
function open_agent_descriptors(env)
    sched = env.sched                       # 스케줄 그래프 꺼내기
    # Set{String}() : 문자열만 담는 빈 집합(중복 자동 제거). `{String}` 은 "원소 타입이 String"인 빈칸 채우기.
    seen = Set{String}()                    # 이미 처리한 로봇 id 를 기억(중복 등록 방지)
    # Vector{Dict{String,String}}() : "문자열→문자열 딕셔너리들의 배열"인 빈 벡터. (중첩 타입 매개변수)
    out = Vector{Dict{String,String}}()     # 결과로 돌려줄 로봇 설명 목록
    for v in Graphs.vertices(sched)         # 모든 정점 순회
        node = get_node_from_id(sched, get_vtx_id(sched, v))  # 정점 v 의 id 로 실제 노드 객체를 가져옴
        # `x isa T` : x 가 타입 T 의 인스턴스인지 검사(파이썬 isinstance). `A || continue` 와 합쳐
        # "이 노드가 RobotGo 타입이 아니면 건너뛴다"는 뜻.
        node isa RobotGo || continue
        # try ... catch ... end 를 한 줄 표현식으로 사용: entity(node).id 가 성공하면 그 값을,
        # 에러가 나면 catch 뒤의 nothing(파이썬 None 에 해당)을 rid 에 담음. `;` 는 catch 와 본문 구분.
        rid = try entity(node).id catch; nothing end
        rid isa RobotID || continue         # 꺼낸 값이 진짜 RobotID 타입이 아니면 건너뜀
        idstr = string(rid)                 # RobotID 를 문자열로 변환(LLM·resolver 가 그대로 주고받을 형태)
        idstr in seen && continue           # 이미 본 로봇이면 건너뜀(로봇당 한 번만)
        push!(seen, idstr)                  # 처리했음을 기록
        # 로봇 하나당 {id, label} 딕셔너리를 추가. label 은 "Robot R3 / robot 3" 같은 사람이 읽을 별칭.
        # rid.id 는 RobotID 안의 실제 번호 필드.
        push!(out, Dict("id" => idstr, "label" => "Robot R$(rid.id) / robot $(rid.id)"))
    end
    return out                              # 로봇 설명 목록 반환
end

"""
    open_node_descriptors(env) -> Vector{Dict{String,String}}

Schedulable MILESTONE nodes the model can put a ForbidWindow on,
each as `{"id", "label"}` with a STRUCTURAL human label so the model can ground a
natural-language reference ("the final assembly", "sub-assembly 2") onto the exact
node id. Same flexible-but-safe pattern as `open_agent_descriptors`:
  * flexibility lives in the label (the model picks among real options);
  * safety lives in the binding — the model must echo the EXACT id, which the
    resolver matches verbatim, and CLOSED nodes are never exposed here (so a spec
    can never reference completed work).

MVP scope: `AssemblyComplete` nodes (the natural "deliverable" milestones). The
root assembly (whose successor is `ProjectComplete`) is labelled distinctly. Labels
are derived purely from schedule/scene-tree structure — no LDraw model needed (the
env does not carry it); richer LDraw part/sub-model names are a later upgrade.
"""
function open_node_descriptors(env)
    sched = env.sched                       # 스케줄 그래프
    tree  = env.scene_tree                   # 장면 트리(부품/조립체의 계층 구조) 꺼내기
    out = Vector{Dict{String,String}}()      # 결과(노드 설명 목록) 빈 벡터
    for v in Graphs.vertices(sched)
        v in env.cache.closed_set && continue          # 완료된 작업은 절대 노출하지 않음(끝난 노드면 건너뜀)
        node = get_node(sched, v).node                 # 정점 v 의 노드 래퍼에서 실제 노드(.node 필드)를 꺼냄
        node isa AssemblyComplete || continue          # "조립 완료" 마일스톤 노드가 아니면 건너뜀
        idstr = string(get_vtx_id(sched, v))           # 정점 id 를 문자열로
        aid   = try entity(node).id catch; nothing end # 노드가 가리키는 조립체의 id(실패하면 nothing)
        aid === nothing && continue                    # `===` 는 "정확히 같은 객체인가" 검사 — nothing 이면 건너뜀
        # num_components(...) : 그 조립체가 몇 개 부품으로 이뤄졌는지. 실패 시 -1 로 표시.
        ncomp = try num_components(get_node(tree, aid)) catch; -1 end
        # any(컬렉션) do 인자 ... end : "do 블록"은 익명함수(파이썬 람다)를 보기 좋게 쓴 것.
        # 여기선 "v 의 바깥이웃(후속 노드) 중 하나라도 ProjectComplete 타입이면 true" → 이 조립체가 최종 루트인지 판별.
        is_root = any(Graphs.outneighbors(sched, v)) do vp
            get_node_from_id(sched, get_vtx_id(sched, vp)) isa ProjectComplete  # 후속 노드가 "프로젝트 완료"인가
        end
        # Spatial grounding: tag the staging-area location (north/central/south by
        # the staging circle's y) so the model can ground a zone reference ("the
        # southern area") onto these nodes. Same flexible-but-safe rule — the label
        # is advisory; the binding is still the exact node id.
        # `dir = if ... else ... end` : 줄리아의 if 는 "값을 돌려주는 표현식" — 분기 결과를 바로 변수에 담을 수 있음.
        # haskey(딕셔너리, 키) : 그 키가 있는지 검사(파이썬 `key in dict`).
        dir = if haskey(env.staging_circles, aid)
            # staging_circles[aid] : 이 조립체의 적치(staging) 원. center(...)[2] 는 그 중심의 두 번째 좌표(=y).
            # 주의: 줄리아 인덱스는 1부터 시작 → [2] 가 y 좌표. Float64(...) 로 실수 변환.
            y = Float64(LazySets.center(env.staging_circles[aid])[2])
            # `조건 ? A : B` : 삼항 연산자(파이썬의 `A if 조건 else B`). 여기선 두 번 겹쳐 씀:
            # "y>0.2 면 north, 아니면(y<-0.2 면 south, 아니면 central)" — y 값으로 북/중앙/남 방위를 정함.
            y > 0.2 ? "north" : y < -0.2 ? "south" : "central"
        else
            ""                              # 적치 원이 없으면 방위 정보 없음(빈 문자열)
        end
        # 위 if 와 같은 삼항 표현으로 라벨을 정함: 루트면 "최종 조립체", 아니면 "하위 조립체 N".
        label = is_root ?
            "the final assembly (root of the whole build; $(ncomp) components)" :
            "sub-assembly $(aid.id) ($(ncomp) components)"
        # isempty(x) : 비었는지 검사. `A || B` 단락: dir 이 비어있지 않을 때만 라벨에 방위를 덧붙임.
        # `*=` : 문자열에서 `label = label * 추가문자열`(이어붙이기)의 축약. 괄호로 묶은 건 || 의 우변으로 만들기 위함.
        isempty(dir) || (label *= "; located in the $(dir) staging area")
        push!(out, Dict("id" => idstr, "label" => label))  # {id, label} 한 쌍을 결과에 추가
    end
    return out                              # 노드 설명 목록 반환
end

"""
    open_zone_descriptors(env) -> Vector{Dict{String,Any}}

The ACTIVE no-go zones the model may reference with a `ForbidZone`, one entry per
registered zone in `RESTRICTION_ZONES`, as `{"key","center","radius","covers","covers_root"}`:
  * `key`         -- the EXACT `Symbol` string the `ForbidZone.zone` field must echo
                     (e.g. "zone"/"block"), so the dispatch can find the live geometry.
  * `center`,`radius` -- world-frame disc (advisory grounding only; the LLM never emits geometry).
  * `covers`      -- ids of the relocatable sub-assemblies this zone overlaps (cross-ref
                     with `nodes` labels so the model can name the blocked `assembly`).
  * `covers_root` -- true iff the zone also traps the root's un-relocatable deposit goals
                     (the central-core case → whole-build relocation, not per-assembly).
Empty when no zone is active, so non-spatial events see no zones and won't mis-emit ForbidZone.
"""
function open_zone_descriptors(env)
    out = Vector{Dict{String,Any}}()                    # 결과(구역 설명 목록). 값 타입이 섞여 Any 사용.
    isempty(RESTRICTION_ZONES[]) && return out          # 활성 구역이 없으면 빈 목록(비공간 사건엔 zone 안 보임)
    # RESTRICTION_ZONES[] : `[]` 는 Ref/전역 컨테이너의 "안쪽 값"을 꺼내는 것. (key, ball) 로 각 구역을 순회.
    for (key, ball) in RESTRICTION_ZONES[]
        # ball 은 원판(disc). 중심의 앞 2개 좌표(x,y)만 실수 벡터로, 반지름도 실수로 뽑음. `;` 는 두 문장을 한 줄에.
        c = Vector{Float64}(get_center(ball)[1:2]); r = Float64(get_radius(ball))
        # 이 구역이 막는 조립체 id 목록. 실패하면(계산 불가) 빈 AbstractID 배열로 대체(try/catch 한 줄 표현).
        blocked = try zone_blocked_assemblies(env; zone_keys = [key]) catch; AbstractID[] end
        # covers = the AssemblyComplete NODE id strings (what `_default_id_resolver` resolves and
        # `open_node_descriptors` exposes) — NOT raw AssemblyID strings, which the resolver can't map.
        # covers = 조립체의 "AssemblyComplete 노드 id 문자열"(resolver 가 되돌릴 수 있는 형태). 원시 AssemblyID 가 아님.
        covers = String[]                               # 이 구역이 덮는 노드 id 문자열 목록(빈 배열로 시작)
        for b in blocked
            ac = _assembly_complete_node(env, b)        # 조립체 b 에 대응하는 AssemblyComplete 노드를 찾음
            ac === nothing && continue                  # 못 찾으면(nothing) 건너뜀
            push!(covers, string(node_id(ac)))          # 그 노드 id 를 문자열로 목록에 추가
        end
        # 이 구역이 루트(전체 조립체)의 안 옮겨지는 deposit 목표까지 가두는지. `!` 로 뒤집음(안 비우면 true). 실패 시 false.
        covers_root = try !zone_clears_root_goals(c, r, env) catch; false end
        # 구역 하나를 {key, center, radius, covers, covers_root} 딕셔너리로 결과에 추가. round(...; digits=2)=소수 2자리 반올림.
        push!(out, Dict{String,Any}(
            "key" => string(key),                       # ForbidZone.zone 이 그대로 echo 할 구역 키(Symbol→문자열)
            "center" => [round(c[1]; digits = 2), round(c[2]; digits = 2)],  # 참고용 중심 좌표(모델은 좌표를 안 만듦)
            "radius" => round(r; digits = 2),           # 참고용 반지름
            "covers" => covers,                         # 덮는 조립체 노드 id 들
            "covers_root" => covers_root))              # 루트 목표까지 덮으면 빌드 전체 이동 사례
    end
    return out                                          # 활성 구역 설명 목록 반환
end

# Typed parse: the one place untrusted JSON becomes typed ConstraintSpec on the
# Julia side. Unknown kind / missing field / unknown id ref throws -> Reject.
# 타입 있는 파싱: 믿을 수 없는 JSON 이 줄리아 쪽에서 타입 있는 ConstraintSpec 으로 바뀌는 "유일한 한 곳".
# 모르는 kind / 빠진 필드 / 모르는 id 참조는 모두 예외를 던짐 → 호출부에서 Reject(거부)로 처리.
#
# ---- 🔴 2026-08-21 D-9 (Task C2, spec §5-8): 행동공간을 emit 가능한 것만 남기고 줄였다 --------
# 🔴 **수를 어느 시점 기준으로 세는지 반드시 밝힐 것.** 이 파일 기준:
#     C2 끝 = **4종** (ReplaceAgent · SwapBattery · LinearConstraint · Disjunction)
#     C3 끝 = **5종** (위 넷 + TranslateBuild) ← .claude/CLAUDE.md 의 "emit 가능 5종" 은 이 시점이다.
#   출발점은 8종이었다. 8 - 6 + 2 = 4, 그 뒤 C3 가 +1 해서 5.
# ⚠️ 바로 아래에 있던 2026-08-19 "대조 결과 = 바꿀 것 없음" 블록은 **철회됐다.** 그 논증은
#    "primitive 가 파싱되는 것은 위험하진 않고 그냥 쓸모없다" 였는데, D-9 가 그 전제를 뒤집었다:
#    같은 일을 하는 후보가 둘이면 LLM 이 어느 쪽으로 새는지가 **측정 잡음**이 된다.
#
# 뺀 것과 근거(spec §5-8 의 표 그대로):
#   ForbidZone        도메인 공집합 (closed≈46 이후 n_restage_feasible == 0)
#   ReformTeam        은퇴 — 복구가 maybe_unwedge_nominal! 로 명목 레인에 이관
#   ForbidAgent       D-7 아래 ReplaceAgent 에 약우월로 지배
#   ForbidWindow      대응 사건 없음 (도착 시점이 확률변수다). 필요하면 Disjunction 으로 쓴다
#   DeprioritizeAgent 선택 0회. cell 위험은 battery kind 로 도착하므로 SwapBattery 가 답이다
#                     (_hz_fire_cell! → battery_action, hazard.jl:583)
#   RelocateBuild     행동이 아니라 **solver** 다 — `_find_min_translation` 이 Δ 를 스스로 찾는다
#                     (restage_zone.jl:768-779). 진짜 원시연산 `_apply_uniform_translation!(env, Δ)`
#                     를 Task C3 의 `TranslateBuild(dx, dy)` 가 자유 파라미터로 노출한다.
#                     🔴 컨트롤러 판정(2026-08-21): 이걸 안 빼면 emit 가능 수가 5 가 아니라 6 이 된다.
#
# 🔴 **타입·컴파일러·내부 생산자는 전부 남는다.** 지우는 것은 이 파서 스위치와 `schema.py` 의
#    union 뿐이다. 내부 생산자 실측: `navigator/baselines.jl:173·192·201` ·
#    `respec/reassign.jl:382` · `oracle/ood_mdp_shim.jl:306`(RelocateBuild 를 **직접** 생성한다 —
#    파서를 안 탄다. 그래서 action_registry.json 의 팔 2 는 이 변경에 안 닿는다).
#
# 🔴 뺀 kind 가 오면 `error()` 로 **죽는다**. `nothing` 을 돌려주면 LLM 이 뺀 팔을 내도 조용히
#    NOOP 으로 무너지고, 그건 이 레포가 `valid_actions` 문지기에서 이미 데인 실패 모양이다.
#
# ⚠️ 알려진 대가: `tools/tests.jl`(ForbidZone·RelocateBuild·DeprioritizeAgent 파싱 단위시험)과
#    `tools/e2e.jl`(모의 LLM 응답)은 이 좁힘 뒤 그 kind 들에서 실패한다. 둘 다 `runtests.jl` 밖의
#    개발용 하니스이고, 명목 레인(`Pkg.test()`)은 이 스위치를 타지 않는다.

"""
    EMITTABLE_KINDS

🔴 LLM 이 **emit 할 수 있는** 제약 kind 의 단일 목록(D-9). 아래 `_parse_proposal` 의 스위치와
언제나 같아야 하고, `llm_service/schema.py` 의 discriminated union · `TOOL_SCHEMA` enum 과도
같아야 한다 — 세 표면 중 하나만 달라지면 그 자리가 조용한 갈라짐이다.
`test/respec_action_space.jl` 이 셋의 **집합 등식**을 직접 단언한다(포함이 아니라 등식).

⚠️ 이것은 `action_registry.json` 의 매크로 어휘(`v3-4arms`)와 **다른 이름공간**이다.
정렬된 튜플로 둔다(직렬화·로그가 결정적이도록).
"""
const EMITTABLE_KINDS = ("Disjunction", "LinearConstraint", "ReplaceAgent", "SwapBattery")

# --- L2-a 문법의 JSON 형태 -------------------------------------------------------
#   VarRef            {"kind": "t0"|"tF"|"xa", "node": <id>, "node2": <id>|null}
#   LinearConstraint  {"kind":"LinearConstraint",
#                      "terms":[{"coeff":1.0,"var":<VarRef>}, ...],
#                      "rel":"le"|"ge"|"eq", "rhs": <number>}
#   Disjunction       {"kind":"Disjunction", "left":<LinearConstraint>, "right":<LinearConstraint>}
# 모르는 rel / 모르는 VarRef kind / 빈 terms / 모르는 노드 id 는 전부 예외다(조용한 폴백 금지).

"""
    EMITTABLE_VARREF_KINDS

🔴 LLM 이 emit 할 수 있는 **결정변수 종류**. `VarRef` **타입**은 `:xa` 도 받지만
(`ForbidAgent ≡ Xa[u,v]=0`, 게이트 N-G8 이 그 등가를 쓴다) LLM 에게는 열지 않는다.

**왜 `:xa` 를 안 여는가 (2026-08-21 실측):**
 1. 프롬프트가 **어떤 `(u,v)` 가 실제 결정변수인지 목록을 주지 않는다.** `Xa` 는 희소행렬이고
    구조적 0 자리가 대부분이라, 모델은 유효한 쌍을 고를 방법이 없다 — 즉 유효한 인스턴스가
    존재하지 않는 형식을 광고하는 셈이 된다(= 함정).
 2. 관측된 판에서 후보 배정 엣지 **423개 중 최적해가 고른 것은 0개**다
    (test/respec_grammar.jl 헤더). 그 판에서는 `Xa` 위의 제약이 해를 **바꿀 수도 없다**.
 3. 후보 엣지 목록을 프롬프트에 실으려면 새 디스크립터 + `/propose` 요청 스키마 확장이 필요하다.
    그건 C2 범위 밖이고, 결속되는 판이 확보된 뒤에 해야 의미가 있다.

⇒ `schema.py` 의 `VarRef.kind` Literal · `TOOL_SCHEMA` · 프롬프트 산문과 **집합으로 같아야 한다**
   (`test/respec_action_space.jl` 이 단언한다). 정렬된 튜플.
"""
const EMITTABLE_VARREF_KINDS = ("t0", "tF")

"JSON 의 VarRef 하나를 타입 있는 `VarRef` 로. 모르는 kind·id 는 예외."
function _parse_varref(v; id_resolver)
    ks = String(v["kind"])
    ks in EMITTABLE_VARREF_KINDS ||
        error("VarRef kind '$ks' is not emittable. emittable = " *
              join(EMITTABLE_VARREF_KINDS, " | ") *
              (ks == "xa" ? " (:xa exists in the type but the prompt ships no candidate-edge " *
                            "list, so it has no valid instantiation — see EMITTABLE_VARREF_KINDS)" : ""))
    # emittable kind 는 노드 하나만 받는다. node2 가 오면 조용히 버리지 않고 죽는다.
    haskey(v, "node2") && v["node2"] !== nothing &&
        error("VarRef('$ks'): node2 is only meaningful for :xa, which is not emittable")
    return VarRef(Symbol(ks), id_resolver(String(v["node"])), nothing)
end

"JSON 의 LinearConstraint 하나를 타입 있는 `LinearConstraint` 로."
function _parse_linear(c; id_resolver)
    # 중첩(Disjunction 의 left/right)에서는 "kind" 가 생략될 수 있다. 있으면 반드시 일치해야 한다.
    haskey(c, "kind") && String(c["kind"]) != "LinearConstraint" &&
        error("Disjunction 의 항은 LinearConstraint 여야 한다 (받은 값: $(String(c["kind"])))")
    terms = Tuple{Float64,VarRef}[]
    for t in c["terms"]                       # 배열 순서대로 — 결정적
        push!(terms, (Float64(t["coeff"]), _parse_varref(t["var"]; id_resolver = id_resolver)))
    end
    return LinearConstraint(terms, Symbol(String(c["rel"])), Float64(c["rhs"]))
end

# 🔴 `sched` 를 받으면 **파싱 단계에서** 참조 접지를 확인한다(가장 싼 표면 — MILP 를 세우기
#    전에 걸러진다). 실전 경로(`llm_to_proposal`)는 언제나 `env.sched` 를 넘긴다.
#    `sched = nothing` 은 스텁 resolver 로 도는 단위시험용이고, 그 경우에도 **권위 있는 관문은
#    언제나 `verify()`** 다(verifier.jl 의 `grammar_ground_check` + build 백스톱).
function _parse_proposal(payload, event; id_resolver, sched = nothing)
    cs = ConstraintSpec[]                   # 제약(constraint) 객체들을 담을 빈 배열 (원소 타입은 ConstraintSpec)
    for c in payload["constraints"]         # JSON 의 "constraints" 배열을 하나씩 순회 (c 는 제약 하나)
        kind = String(c["kind"])            # 제약 종류 문자열(emit 가능한 것은 EMITTABLE_KINDS 뿐)
        # spec = if ... elseif ... else ... end : 분기 결과를 바로 변수에 담는 표현식 if. (파이썬 elif = elseif)
        spec = if kind == "ReplaceAgent"
            # ReplaceAgent(로봇id, after) : 로봇 고장 → 가장 가까운 예비로 1:1 인계(replace_robot.jl).
            # MILP 재배정이 아니라 그래프 splice 로 전용 dispatch(_is_robot_replace).
            # 예비 선택은 LLM 이 아니라 기하(nearest_pool)가 함 — 이 spec 은 고장 로봇 id 만 지목.
            ReplaceAgent(id_resolver(String(c["agent"])), Float64(get(c, "after", 0.0)))
        elseif kind == "SwapBattery"
            # SwapBattery(로봇id) : 방전 → 현장에서 배터리만 교체(swap_battery!). 같은 본체가 계속 일하고
            # 창고 예비 "본체"를 안 먹는다 — ReplaceAgent 와 소모 자원이 달라서 별도 종류로 둔 것이다.
            SwapBattery(id_resolver(String(c["agent"])))
        elseif kind == "LinearConstraint"
            # 🔴 L2-a: 아무도 안 짠 선형 제약을 LLM 이 직접 쓴다(spec §5-4). 안전장치는 kind 를
            #    안 보는 일반 verify() 다(verifier.jl:83-125) — 문법·과거불가침·feasibility·invariant.
            _parse_linear(c; id_resolver = id_resolver)
        elseif kind == "Disjunction"
            # Disjunction(left, right) : Big-M 이접. ForbidWindow(v,lo,hi) 가 정확히
            #   Disjunction(tF[v] ≤ lo, t0[v] ≥ hi) 다(test/respec_grammar.jl 이 두 해가 같음을 실측).
            Disjunction(_parse_linear(c["left"]; id_resolver = id_resolver),
                        _parse_linear(c["right"]; id_resolver = id_resolver))
        else
            # 🔴 D-9 로 뺀 kind(ForbidZone · ReformTeam · ForbidAgent · ForbidWindow ·
            #    DeprioritizeAgent · RelocateBuild)도 여기로 온다 — **조용히 무시하지 않고 죽는다.**
            error("kind '$kind' is not emittable (D-9). emittable = " *
                  join(EMITTABLE_KINDS, " | "))
        end
        push!(cs, spec)                     # 만든 제약을 배열에 추가
    end
    # 삼항 연산자: "rationale" 키가 있으면 그 문자열을, 없으면 빈 문자열을 rationale 에 담음.
    rationale = haskey(payload, "rationale") ? String(payload["rationale"]) : ""
    prop = RespecProposal(cs, rationale, String(event))
    # 스케줄을 알면 여기서 접지를 확인한다. 실패는 예외 — 이 함수의 기존 계약 그대로이고
    # (`llm_to_proposal` docstring), 호출부(`maybe_respecify!` replan.jl:355-375)가 그것을
    # 잡아 사건 심각도로 분기한다. 즉 시뮬 루프는 안 무너진다.
    if sched !== nothing
        rej = grammar_ground_check(prop, sched)
        rej === nothing ||
            error("proposal references something that is not a decision variable " *
                  "($(rej.reason)): $(rej.detail)")
    end
    # 제약 목록 + 근거(rationale) + 원본 이벤트 문자열을 묶어 타입 있는 RespecProposal 객체로 반환.
    return prop
end
