# =============================================================================
# selfimprove 라이브러리 팔 (spec §9.1, §5.4, §0.0 R4·R8).
#
# 🔴 LLM 을 부르는 경로를 타지 않는다 — 합성 레인의 경계 함수가 아니라 CB.enact_minted! 를 직접
#    부른다(경계 함수 안에는 유료 왕복이 있다). 등록은 라이브 body 와 **같은**
#    CB.register_minted_primitive! 이고, 집행 봉투도 같다 → 재생 동등성이 구조적이다.
# 🔴 검증이 등록보다 먼저다: 실제로 등록할 바이트의 sha256 을 manifest(또는 SELFIMPROVE_ARM_SHA)
#    와 대조한 뒤에만 등록한다. 한 바이트라도 다르면 **등록 전에** 죽는다.
# 🔴 성공 판정은 `execution_ok` 하나다(R4). `handled` 는 폴백 제어용 — 둘을 섞지 말 것.
#
# 의존: CB, JSON3, HTTP, ActionRegistry, router_drives, DSPY_URL(policy.jl), minted_handled(enact.jl).
# =============================================================================
using SHA

const LIBARMS = Dict{Int,Dict{String,Any}}()
const FORCED_ARM = Ref{Union{Nothing,Dict{String,Any}}}(nothing)
"마지막 라이브러리 팔 집행 시점 `(closed, sim_t)` — 불변식 I4(`invariants.jl`)의 기준점."
const LIBARM_ENACTED_AT = Ref{Union{Nothing,Tuple{Int,Float64}}}(nothing)

_sha(bytes) = bytes2hex(sha256(bytes))

function _manifest()
    vdir = get(ENV, "SELFIMPROVE_VERSION_DIR", "")
    isempty(vdir) && return nothing, ""
    raw = read(joinpath(vdir, "manifest.json"))
    return JSON3.read(String(copy(raw)), Dict{String,Any}), _sha(raw)
end

"""
    assert_selfimprove_version()

판이 고정된 버전(`SELFIMPROVE_VERSION_DIR` + `SELFIMPROVE_MANIFEST_SHA`)이 디스크의 manifest·레지스트리와,
라우터가 돌면 서비스 `/health` 의 `agent_version`·`manifest_sha256` 와 같은지 확인한다. 다르면 죽는다.
버전 없이 뜬 판(환경변수 없음)은 아무것도 안 한다.
"""
function assert_selfimprove_version()
    m, msha = _manifest()
    m === nothing && return
    want = get(ENV, "SELFIMPROVE_MANIFEST_SHA", "")
    msha == want || error("[selfimprove] manifest bytes sha $(msha) != pinned $(want)")
    strip(read(joinpath(ENV["SELFIMPROVE_VERSION_DIR"], "manifest.sha256"), String)) == msha ||
        error("[selfimprove] manifest.sha256 file disagrees with manifest bytes")
    _sha(read(ENV["ACTION_REGISTRY"])) == m["registry_sha256"] ||
        error("[selfimprove] ACTION_REGISTRY bytes differ from manifest registry_sha256")
    if router_drives()
        h = JSON3.read(String(HTTP.get(DSPY_URL * "/health").body))
        (get(h, :manifest_sha256, nothing) == want &&
         get(h, :agent_version, nothing) == m["version"]) ||
            error("[selfimprove] service $(DSPY_URL) serves $(get(h, :agent_version, nothing))/" *
                  "$(get(h, :manifest_sha256, nothing)); run pinned to $(m["version"])/$(want)")
    end
end

function _register_arm!(a)
    why = CB.register_minted_primitive!(; name = a["impl_name"], code = a["impl_code"],
                                        params = a["params"], surface = a["surface"],
                                        reversible = Bool(a["reversible"]))
    why === nothing || error("[libarm] arm $(a["arm_id"]) ($(a["impl_name"])) rejected: $(why)")
end

"버전의 팔 전부와 (있으면) 강제 팔 하나를 **바이트 검증 뒤** 등록한다."
function load_library_arms!()
    m, _ = _manifest()
    if m !== nothing
        vdir = ENV["SELFIMPROVE_VERSION_DIR"]
        for meta in m["arms"]
            raw = read(joinpath(vdir, "arms", "m$(meta["arm_id"]).json"))
            _sha(raw) == meta["arm_json_sha256"] ||
                error("[libarm] arms/m$(meta["arm_id"]).json bytes differ from manifest — refusing to register")
            a = JSON3.read(String(raw), Dict{String,Any})
            _register_arm!(a); LIBARMS[Int(a["arm_id"])] = a
        end
    end
    p = get(ENV, "SELFIMPROVE_ARM", "")
    if !isempty(p)
        raw = read(p)
        want = get(ENV, "SELFIMPROVE_ARM_SHA", "")
        _sha(raw) == want || error("[libarm] SELFIMPROVE_ARM bytes sha != SELFIMPROVE_ARM_SHA")
        a = JSON3.read(String(raw), Dict{String,Any})
        _register_arm!(a); FORCED_ARM[] = a
    end
    println("[libarm] loaded version_arms=", sort(collect(keys(LIBARMS))),
            " forced=", FORCED_ARM[] === nothing ? "none" : FORCED_ARM[]["role"])
end

"""
    libarm_for(truth, macro_name) -> arm dict | nothing

zone 사건에서만: 강제 팔(S1·S3)이 있으면 그것, 아니면 결정된 매크로가 id ≥ 100 인 버전 팔이면 그 팔.
레지스트리가 그 팔을 부르는데 검증된 arm 파일이 없으면 죽는다(조용히 NOOP 으로 무너지지 않게).
"""
function libarm_for(truth, macro_name)
    truth isa CB.ZoneTruth || return nothing
    FORCED_ARM[] !== nothing && return FORCED_ARM[]
    id = findfirst(==(String(macro_name)), ActionRegistry.NAME)
    (id === nothing || id < 100) && return nothing
    haskey(LIBARMS, id) || error("[libarm] registry names arm $(id) but no verified arms/m$(id).json was loaded")
    return LIBARMS[id]
end

_sim_t(env) = try Float64(CB.sim_time(env.dt)) catch; NaN end

"""
    enact_libarm!(env, truth, arm) -> (handled, execution_ok, rec)

`execution_ok` = verdict 가 집행 계열 ∧ 던진 단계 없음 ∧ ¬partial ∧ 재개 성공 ∧ 재풀이 실패 아님.
body 예외는 `enact_minted!` 가 `steps[].status=:threw`·`partial=true` 로 **돌려준다** — 바깥 try 로는 못 잡는다.
"""
function enact_libarm!(env, truth, a)
    synth = Dict{String,Any}(k => a[k] for k in
        ("impl_name", "body_names", "calls", "params", "surface", "reversible"))
    synth["tool_minted"] = true; synth["synthesis_ran"] = true; synth["wrote"] = true
    t0 = time()
    r = CB.enact_minted!(env, truth, synth)
    wall = time() - t0
    steps = [(name = String(s.name), status = String(s.status)) for s in r.steps]
    ok = CB.minted_handled_verdict_ok(r.verdict) && !any(s.status == "threw" for s in steps) &&
         !r.partial && r.resume !== :failed &&
         !(r.resolve === :infeasible || r.resolve === :commit_failed || r.resolve === :threw)
    h = minted_handled(r)
    closed = length(env.cache.closed_set)
    simt = _sim_t(env)
    rec = Dict{String,Any}("arm_id" => a["arm_id"], "role" => a["role"], "impl" => a["impl_name"],
               "artifact" => get(a, "artifact_sha256", ""), "verdict" => string(r.verdict),
               "steps" => steps, "partial" => r.partial, "resume" => string(r.resume),
               "resolve" => string(r.resolve), "reason" => String(r.reason),
               "handled" => h, "execution_ok" => ok,
               "wall_s" => round(wall; digits = 2), "closed_at" => closed, "sim_t" => simt)
    println("[libarm] ", JSON3.write(rec))
    LIBARM_ENACTED_AT[] = (closed, simt)
    return (handled = h, execution_ok = ok, rec = rec)
end
