# tools/monitor/narrate.jl
# =============================================================================
# 스트림 레코드를 사람이 읽는 문장으로 바꾼다. **순수 함수만** — 파일·네트워크·시각을 읽지 않는다.
#
# 왜 LLM 을 안 쓰는가
# ------------------
#  (1) 입력이 이미 구조화된 수치다. 문장으로 바꾸는 데 모델이 필요하지 않다.
#  (2) 이 하니스는 프로세스 간 재현성이 없어서 시뮬 결과로는 아무것도 검증할 수 없는데,
#      순수 함수는 단위검사로 고정할 수 있다.
#  (3) 이 레인의 LLM 은 **정책 후보**다. 해석까지 LLM 이 하면 화면의 서술과 피고가 같은 모델이 된다.
#
# 절대 하지 않는 것
# ----------------
#  · 없는 필드를 지어내지 않는다. n_stalled 가 없으면 정지를 **언급하지 않는다**
#    (로그의 [STALL] 은 run_demo.jl:472 의 Logging.Warn 에 삼켜지므로 n_stalled 가 유일한
#     기계적 증거다 — "로그에 없다"를 "안 일어났다"로 읽으면 안 된다).
#  · complete==true 인데 closed<total 인 것을 미완주로 서술하지 않는다. 이 하니스는 완주해도
#    closed<total 이다(실측 291/313, md/README.md §6).
#  · 정지 0 을 "문제 없음" 으로 쓰지 않는다. 미완주는 정지 없이도 일어난다.
#  · 폴백이 있었으면 **반드시** 말한다(조용한 폴백 금지).
# =============================================================================

_has(d, k) = haskey(d, k) && d[k] !== nothing

_num(x, nd = 2) = try string(round(Float64(x); digits = nd)) catch; string(x) end

"""
    narrate_event(ev) -> String

한 OOD 결정을 서술한다: 무엇이 주입됐고, 누가 정했고, 무슨 팔을 골랐는가.
`ev` 는 policy.jl 이 만드는 레코드(또는 그 부분집합)를 담은 Dict.
"""
function narrate_event(ev::AbstractDict)
    parts = String[]

    kind = _has(ev, "kind") ? String(ev["kind"]) : "unknown"
    ctx = String[]
    _has(ev, "severity")      && push!(ctx, "severity " * _num(ev["severity"]))
    _has(ev, "soc")           && push!(ctx, "SoC " * _num(ev["soc"]))
    _has(ev, "spare_count")   && push!(ctx, string(ev["spare_count"]) * " spares left")
    _has(ev, "agent_pending") && push!(ctx, string(ev["agent_pending"]) * " pending jobs")
    _has(ev, "progress")      && push!(ctx, "at " * _num(100 * Float64(ev["progress"]), 0) * "% progress")
    who = _has(ev, "robot") ? " on " * String(ev["robot"]) : ""
    push!(parts, "A " * kind * " event fired" * who *
                 (isempty(ctx) ? "." : " (" * join(ctx, ", ") * ")."))

    lane = _has(ev, "enacted") ? String(ev["enacted"]) : "unknown"
    act  = _has(ev, "macro_name") ? String(ev["macro_name"]) : "no action"
    push!(parts, "The " * lane * " lane chose " * act * ".")

    # 폴백은 반드시 말한다.
    if get(ev, "fell_back", false) === true
        req = _has(ev, "requested") ? String(ev["requested"]) : "the routed lane"
        push!(parts, "It fell back to " * lane * " because " * req * " was unavailable.")
    end

    # 그 레인이 남긴 근거가 있으면 그대로 인용한다(지어내지 않는다).
    pol = get(ev, "policies", nothing)
    if pol isa AbstractDict && haskey(pol, lane) && pol[lane] isa AbstractDict
        why = get(pol[lane], "rationale", "")
        why isa AbstractString && !isempty(why) && push!(parts, "Its reason: " * why)
    end

    # 에너지가 결정에 실제로 실렸으면 그 사실을 말한다. J 의 축이 energy 이므로(objective.json),
    # 화면에서 "왜 이 팔인가" 의 절반이 여기에 있다. 값이 없으면 **언급하지 않는다**.
    if _has(ev, "energy_decisive") && ev["energy_decisive"] === true
        push!(parts, "Energy was the deciding term in this comparison (the objective J prices " *
                     "energy, so a cheaper-in-joules arm can win a tie on makespan).")
    end

    return join(parts, " ")
end

"""
    narrate_outcome(sm) -> String

런 하나의 결과를 서술한다. `sm` 은 DEMO_SUMMARY 레코드(또는 그 부분집합)를 담은 Dict.
"""
function narrate_outcome(sm::AbstractDict)
    parts = String[]

    complete = get(sm, "complete", nothing)
    closed   = _has(sm, "closed") ? sm["closed"] : nothing
    total    = _has(sm, "total")  ? sm["total"]  : nothing
    ledger = (closed === nothing || total === nothing) ? "" :
             " (" * string(closed) * "/" * string(total) * " nodes closed)"

    if complete === true
        # 완주해도 closed<total 이 정상이다 — 이 차이를 미완주로 쓰지 않는다.
        push!(parts, "The build completed" * ledger * ".")
    elseif complete === false
        push!(parts, "The build was incomplete" * ledger * ".")
    else
        push!(parts, "Completion is not recorded for this run" * ledger * ".")
    end

    if _has(sm, "n_stalled")
        n = sm["n_stalled"]
        push!(parts, n == 0 ?
            "No robot stalled; the shortfall came from something other than battery stalls." :
            string(n) * " robot stalls were recorded.")
    end
    # n_stalled 가 없으면 정지를 **언급하지 않는다**.

    # 에너지는 J 의 축이므로 결과 서술에도 들어간다. 없으면 지어내지 않는다.
    if _has(sm, "energy_J")
        e = sm["energy_J"]
        per = (closed !== nothing && closed isa Number && closed > 0) ?
              (" = " * _num(Float64(e) / closed, 1) * " J per closed node") : ""
        push!(parts, "It spent " * _num(e, 0) * " J" * per * ".")
    end

    return join(parts, " ")
end
