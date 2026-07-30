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
    return _parse_proposal(payload, event; id_resolver = id_resolver)  # 파싱된 JSON 을 타입 있는 제안 객체로 변환해 반환
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
function _parse_proposal(payload, event; id_resolver)
    cs = ConstraintSpec[]                   # 제약(constraint) 객체들을 담을 빈 배열 (원소 타입은 ConstraintSpec)
    for c in payload["constraints"]         # JSON 의 "constraints" 배열을 하나씩 순회 (c 는 제약 하나)
        kind = String(c["kind"])            # 제약 종류 문자열("ForbidWindow" 또는 "ForbidAgent")
        # spec = if ... elseif ... else ... end : 분기 결과를 바로 변수에 담는 표현식 if. (파이썬 elif = elseif)
        spec = if kind == "ForbidWindow"
            # ForbidWindow(노드id, 하한, 상한) : 특정 노드를 [t_lo, t_hi] 시간창 동안 금지하는 제약 생성.
            # id_resolver(...) 로 문자열 노드 id 를 실제 id 객체로 되돌림(모르는 id 면 여기서 예외 발생).
            ForbidWindow(id_resolver(String(c["node"])), Float64(c["t_lo"]), Float64(c["t_hi"]))
        elseif kind == "ForbidAgent"
            # ForbidAgent(로봇id, after) : 특정 로봇을 after 시각 이후로 못 쓰게 막는 제약.
            # get(c, "after", 0.0) : "after" 키가 있으면 그 값, 없으면 기본 0.0(딕셔너리 get 기본값).
            ForbidAgent(id_resolver(String(c["agent"])), Float64(get(c, "after", 0.0)))
        elseif kind == "ForbidZone"
            # ForbidZone(조립체id, zone키) : 공간적 출입금지 구역이 한 조립체의 적치영역을 덮은 사건.
            # MILP 으로 안 풀고 기하 복구(restage/whole-build)로 dispatch 됨. assembly 는 grounding(감사·교차검증)용 —
            # id_resolver 로 실제 노드 id 로 되돌리고(모르는 id 면 예외→거부), zone 은 RESTRICTION_ZONES 의 키(Symbol).
            ForbidZone(id_resolver(String(c["assembly"])), Symbol(String(c["zone"])))
        elseif kind == "ReplaceAgent"
            # ReplaceAgent(로봇id, after) : 로봇 고장 → 가장 가까운 예비로 1:1 인계(replace_robot.jl).
            # ForbidAgent 와 필드는 같지만(로봇 id + after) 처리 경로가 다른 별도 종류 — MILP 재배정이 아니라
            # 그래프 splice 로 전용 dispatch(_is_robot_replace). 예비 선택은 LLM 이 아니라 기하(nearest_pool)가 함.
            ReplaceAgent(id_resolver(String(c["agent"])), Float64(get(c, "after", 0.0)))
        elseif kind == "ReformTeam"
            # ReformTeam() : 다로봇 운반팀 형성 교착 → 기하 재정립(reform_stuck_teams!). 필드 없음.
            ReformTeam()
        elseif kind == "DeprioritizeAgent"
            # DeprioritizeAgent(로봇id, factor) : TIER-2 소프트 회피(예: 배터리 저하). 제약을 안 더하고
            # 목적함수에서 그 로봇 배정엣지 비용에 factor 를 곱함 → feasible set 불변(빌드 안 멈춤).
            # factor 는 advisory(없으면 50.0); enactment(deprioritize_agent!)에서 [1,1e3] 로 클램프됨(안전).
            DeprioritizeAgent(id_resolver(String(c["agent"])), Float64(get(c, "factor", 50.0)))
        else
            error("unknown constraint kind from respec service: $kind")  # 알 수 없는 종류면 예외 → 거부
        end
        push!(cs, spec)                     # 만든 제약을 배열에 추가
    end
    # 삼항 연산자: "rationale" 키가 있으면 그 문자열을, 없으면 빈 문자열을 rationale 에 담음.
    rationale = haskey(payload, "rationale") ? String(payload["rationale"]) : ""
    # 제약 목록 + 근거(rationale) + 원본 이벤트 문자열을 묶어 타입 있는 RespecProposal 객체로 반환.
    return RespecProposal(cs, rationale, String(event))
end
