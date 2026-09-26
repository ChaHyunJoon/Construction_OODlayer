# =============================================================================
# test/repair_runtime_wiring.jl — T8 production 배선(`ZONE_REPAIR_VERIFICATION=off|shadow|enforce`) 게이트.
# 단독 실행, runtests.jl 미포함(브리프 요구 없음).
#
#   julia +lts --project=. test/repair_runtime_wiring.jl                         # 빠른 부분(CB 미로드, ≈1.5 분 — 실제
#                                                                                 #  render_demo.jl 기동 거절 넷 포함;
#                                                                                 #  T8_SKIP_RENDER=1 은 변이 실행용으로 [2] 를 건너뛴다)
#   julia +lts --project=. test/repair_runtime_wiring.jl episodes <root> <offdir> # 에피소드(tractor zone s26, 순차, ≈1 시간)
#
# `<offdir>` = `run_off.sh` 가 만든 off 기준 판(`pre-plain`·`pre-trace` = 변경 **전** 커밋, 같은 디렉터리). 에피소드 부분은
# shadow 부모(원래 세계)의 실제 스트림·trace 가 off 판과 **같다**(shadow 는 관측 전용)는 것을 잰다.
# 서비스 기동 0 · 모델 호출 0: 서비스 경로는 닫힌 포트와 이 파일이 띄우는 가짜 `/health` 로만 잰다.
# =============================================================================
using Test, JSON3, SHA, Sockets
include(joinpath(@__DIR__, "..", "src", "verification", "repair_runtime.jl"))
const RT = RepairRuntime
const S = RepairSupervisor
const BR = BranchRunner
const R = RepairTypes
const RC = ReplayCompare
const ROOT = BR.ROOT
const RENDER = joinpath(ROOT, "tools", "monitor", "render_demo.jl")
const FIXTURE = joinpath(ROOT, "test", "fixtures", "repair_verification", "runtime_proposals.json")
const PI0CELL = merge(BR.PI0, Dict("DEMO_OOD" => "none", "DEMO_ZONE" => "1", "DEMO_MODEL" => "tractor.mpd",
                                   "DEMO_SEED" => "26", "DEMO_ZONE_SEED" => "26", "DEMO_CASE_TAG" => "pi0_zone"))
log(x...) = (println("[t8 ", Libc.strftime("%H:%M:%S", time()), "] ", x...); flush(stdout))

"render_demo.jl 을 **production 과 같은 방식**(새 julia, env 교체)으로 돌린다. 반환 (code, out)."
function render(env::AbstractDict; logfile = tempname(), timeout_s = 7200)
    e = merge(BR.base_env(), Dict{String,String}(String(k) => String(v) for (k, v) in env))
    open(logfile, "w") do io
        p = run(pipeline(ignorestatus(Cmd(setenv(`$(BR.JULIA) --project=$ROOT $RENDER`, e); dir = ROOT)); stdout = io, stderr = io); wait = false)
        t = time()
        while process_running(p)
            time() - t > timeout_s && (kill(p); break)
            sleep(1)
        end
        wait(p)
        return (code = p.exitcode, out = read(logfile, String), log = logfile)
    end
end

"가짜 `/health` 서버(모델 없음): 고정 JSON 을 HTTP/1.1 로 돌려준다."
function fake_health(body::AbstractString)
    srv = listen(ip"127.0.0.1", 0); port = Int(getsockname(srv)[2])
    @async while true
        s = try accept(srv) catch; break end
        @async try
            while !eof(s); isempty(strip(readline(s))) && break; end
            write(s, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $(sizeof(body))\r\nConnection: close\r\n\r\n$(body)")
        finally
            close(s)
        end
    end
    return srv, "http://127.0.0.1:$(port)"
end
closed_port_url() = (s = listen(ip"127.0.0.1", 0); p = Int(getsockname(s)[2]); close(s); "http://127.0.0.1:$(p)")

fixture() = RT.load_proposals(FIXTURE)

if isempty(ARGS)
@testset "T8 runtime wiring (fast, no CB)" begin

@testset "[1] 모드 파싱 — 정확히 off|shadow|enforce, 오타는 오류" begin
    @test RT.parse_mode("off") === :off
    @test RT.parse_mode("shadow") === :shadow
    @test RT.parse_mode("enforce") === :enforce
    for bad in ("OFF", "Shadow", " shadow", "", "on", "enforced", "1")
        @test_throws ErrorException RT.parse_mode(bad)
    end
end

get(ENV, "T8_SKIP_RENDER", "") == "1" || @testset "[2] render_demo.jl — 오타·pi0 위반·서비스 게이트·enforce 는 부모를 띄우기 전에 거절" begin
    d = mktempdir()
    # (a) 오타: production 진입점에서 오류(조용히 off 가 되지 않는다)
    r = render(merge(PI0CELL, Dict("ZONE_REPAIR_VERIFICATION" => "Shadow", "ZONE_REPAIR_DIR" => joinpath(d, "a"))))
    @test r.code != 0
    @test occursin("is not one of off|shadow|enforce", r.out)
    # (b) pi0 위반 + 우회 손잡이
    r = render(merge(PI0CELL, Dict("ZONE_REPAIR_VERIFICATION" => "shadow", "DEMO_POLICY" => "dspy",
                                   "DEMO_SYNTH_FIXTURE" => "/tmp/x.json", "ZONE_REPAIR_PROPOSALS" => FIXTURE,
                                   "ZONE_REPAIR_DIR" => joinpath(d, "b"))))
    @test r.code != 0
    @test occursin("refused at startup", r.out) && occursin("DEMO_POLICY=\"dspy\"", r.out) && occursin("DEMO_SYNTH_FIXTURE is set", r.out)
    @test !isdir(joinpath(d, "b", "parent"))
    # (c) 서비스 후보 source + 닿지 않는 서비스 → 세대 게이트(check_health CLI)가 거절
    r = render(merge(PI0CELL, Dict("ZONE_REPAIR_VERIFICATION" => "shadow", "DSPY_URL" => closed_port_url(),
                                   # T9: 서비스 source 는 모델 예산이 필수다(기본값 없음) — 게이트까지 가려면 싣는다
                                   "ZONE_REPAIR_MAX_TOTAL_TOKENS" => "20000", "ZONE_REPAIR_MAX_COST_USD" => "1.0",
                                   "ZONE_REPAIR_DIR" => joinpath(d, "c"))))
    @test r.code != 0
    @test occursin("generation gate", r.out) && occursin("FAIL unreachable", r.out)
    @test !isdir(joinpath(d, "c", "parent"))
    # (d) enforce: 능력표를 실측하고 enforce_allowed=false 면 거절(shadow 로 내려가지 않는다), 보고서를 인용
    r = render(merge(PI0CELL, Dict("ZONE_REPAIR_VERIFICATION" => "enforce", "ZONE_REPAIR_PROPOSALS" => FIXTURE,
                                   "ZONE_REPAIR_DIR" => joinpath(d, "d"))))
    capf = joinpath(d, "d", "capabilities", "capabilities.json")
    @test r.code != 0
    @test occursin("ZONE_REPAIR_VERIFICATION=enforce refused", r.out) && occursin(capf, r.out)
    @test isfile(capf) && BR._json(capf)["enforce_allowed"] === false
    @test "same_process_runtime_override" in BR._json(capf)["not_enforced"]
    @test !isdir(joinpath(d, "d", "parent"))
    log("[2] enforce refusal cites ", capf, " not_enforced=", BR._json(capf)["not_enforced"])
end

@testset "[3] 기동 전제 — pi0 셋·우회 손잡이·대화형" begin
    @test RT.startup_problems(PI0CELL) == String[]
    for k in RT.PI0_KEYS
        @test length(RT.startup_problems(merge(PI0CELL, Dict(k => "x")))) == 1
        e = copy(PI0CELL); delete!(e, k)
        @test occursin("<unset>", only(RT.startup_problems(e)))
    end
    for k in RT.BYPASS_KEYS
        @test occursin(k, only(RT.startup_problems(merge(PI0CELL, Dict(k => "1")))))
    end
    @test occursin("MONITOR_INTERACTIVE", only(RT.startup_problems(merge(PI0CELL, Dict("MONITOR_INTERACTIVE" => "1")))))
end

@testset "[4] enforce 문 — 능력표 false/부재면 닫힘" begin
    @test !isempty(RT.enforce_problems(nothing))
    p = RT.enforce_problems(Dict("enforce_allowed" => false, "not_enforced" => ["udp_send", "same_process_runtime_override"]))
    @test occursin("udp_send", only(p))
    @test RT.enforce_problems(Dict("enforce_allowed" => true)) == String[]
    # run_episode! 도 스스로 문을 본다(부모를 띄우기 전)
    d = mktempdir()
    @test_throws ErrorException RT.run_episode!(; mode = :enforce, launch_env = PI0CELL, root = joinpath(d, "e"),
        proposals = fixture(), source = :fixture, capabilities = Dict("enforce_allowed" => false), out_dir = d)
    @test !isdir(joinpath(d, "e", "parent"))
end

@testset "[5] 결정 전 신원 — 서비스·source·API·schema·권한 지문" begin
    ok = fixture()
    @test RT.decision_gaps(ok; source = :fixture) == String[]
    tweak(f) = (p = deepcopy(ok); f(p[1]); p)
    g = RT.decision_gaps(tweak(p -> p["schema_version"] = "tool-proposal/0"); source = :fixture)
    @test occursin("API schema_version", only(g))
    g = RT.decision_gaps(tweak(p -> p["provenance"]["capability_contract_version"] = "capability/0"); source = :fixture)
    @test occursin("permission contract", only(g))
    g = RT.decision_gaps(tweak(p -> p["provenance"]["tool_proposal_schema_sha256"] = "0"^64); source = :fixture)
    @test occursin("schema digest", only(g))
    good = tweak(p -> (p["provenance"]["tool_proposal_schema_sha256"] = RT._sha(RT.SCHEMA_FILE);
                       p["provenance"]["capability_contract_version"] = R.DEFAULT_CAPABILITY_CONTRACT.version))
    @test RT.decision_gaps(good; source = :fixture) == String[]              # 양성 대조: 맞는 도장은 통과
    g = RT.decision_gaps(tweak(p -> p["provenance"]["service_code_fingerprint"] = "deadbeef"); source = :fixture,
                         tree_fingerprint = () -> "cafef00d")
    @test occursin("service source deadbeef != this tree cafef00d", only(g))
    @test RT.decision_gaps(tweak(p -> p["provenance"]["service_code_fingerprint"] = "cafef00d"); source = :fixture,
                           tree_fingerprint = () -> "cafef00d") == String[]
    # 서비스 source: 게이트 실패 = gap, 도장 셋은 필수
    g = RT.decision_gaps(Dict{String,Any}[]; source = :service, url = "x", service_gate = _ -> (false, "[generation] FAIL stale — x"))
    @test occursin("FAIL stale", only(g))
    g = RT.decision_gaps(ok; source = :service, url = "x", service_gate = _ -> (true, "OK"), tree_fingerprint = () -> "f")
    @test count(x -> occursin("service proposal lacks provenance", x), g) == 3
end

@testset "[6] 세대 게이트를 실제로 부른다 — 닫힌 포트·가짜 /health(stale·unstamped·flag_off·ok)" begin
    ok, line = RT.service_gate(closed_port_url())
    @test !ok && occursin("FAIL unreachable", line)
    tfp = RT.tree_service_fingerprint()
    @test tfp isa String && length(tfp) >= 8
    cases = ["stale" => "{\"code_fingerprint\":\"0000\",\"synth_tool_synthesis\":true,\"synth_multi_agent\":true}",
             "unstamped" => "{\"status\":\"ok\"}",
             "flag_off" => "{\"code_fingerprint\":\"$(tfp)\",\"synth_tool_synthesis\":true,\"synth_multi_agent\":false}",
             "ok" => "{\"code_fingerprint\":\"$(tfp)\",\"synth_tool_synthesis\":true,\"synth_multi_agent\":true}"]
    for (code, body) in cases
        srv, url = fake_health(body)
        try
            ok, line = RT.service_gate(url)
            @test ok == (code == "ok")
            @test occursin(code == "ok" ? "OK ok" : "FAIL $(code)", line)
            log("[6] ", code, " → ", first(line, 90))
            # 결정 전 검사 경로도 같은 판정을 싣는다
            g = RT.decision_gaps(Dict{String,Any}[]; source = :service, url)
            @test isempty(g) == (code == "ok")
        finally
            close(srv)
        end
    end
end

@testset "[7] 활성화 = ack(T7 minor) · commit worker ack 탐지" begin
    @test RT.RS.activation_state(; acked = false, handover = nothing, ctl_err = nothing) == (; activated = false, reasons = String[])
    @test RT.RS.activation_state(; acked = true, handover = Dict("x" => 1), ctl_err = nothing).activated
    a = RT.RS.activation_state(; acked = true, handover = nothing, ctl_err = "boom")
    @test a.activated && occursin("handover record failed after the commit worker was activated: boom", only(a.reasons))
    d = mktempdir(); mkpath(joinpath(d, "control"))
    @test !S.worker_acked_activate(d)
    write(joinpath(d, "control", "1.out.json"), "{\"cmd\":\"exit\"}")
    @test !S.worker_acked_activate(d)
    write(joinpath(d, "control", "2.out.json"), "{\"cmd\":\"activate\",\"counters_equal\":true}")
    @test S.worker_acked_activate(d)
end

@testset "[8] 상태 기계 — shadow 는 REJECT_CANDIDATE 가 아니라 SHADOW_NOT_COMMITTED" begin
    @test S.transition(:SELECTED_TOOL, :SHADOW_NOT_COMMITTED) === :SHADOW_NOT_COMMITTED
    @test S.transition(:SHADOW_NOT_COMMITTED, :SELECTED_NOOP) === :SELECTED_NOOP
    @test_throws ArgumentError S.transition(:SHADOW_NOT_COMMITTED, :PRECOMMIT_VERIFIED)
    @test_throws ArgumentError S.transition(:SELECTED_NOOP, :SHADOW_NOT_COMMITTED)
end

@testset "[9] 세계 프로세스의 raw body 문(enact.jl) — 검증 모드면 등록 전에 거절" begin
    m = Module(:EnactProbe)
    Base.include(m, joinpath(ROOT, "tools", "monitor", "enact.jl"))
    dec = (synth_lane = Dict{String,Any}("impl_name" => "evil!", "impl_code" => "function evil!(env) end"),)
    old = get(ENV, "ZONE_REPAIR_VERIFICATION", nothing)
    try
        delete!(ENV, "ZONE_REPAIR_VERIFICATION")
        @test Base.invokelatest(m.zrv_refuses_raw_body, dec) === nothing                 # off: 오늘 경로
        for md in ("shadow", "enforce")
            ENV["ZONE_REPAIR_VERIFICATION"] = md
            @test occursin("refuses to register/run generated body 'evil!'", Base.invokelatest(m.zrv_refuses_raw_body, dec))
            @test Base.invokelatest(m.zrv_refuses_raw_body, (synth_lane = nothing,)) === nothing
            r = Base.invokelatest(m.enact_minted_decision!, nothing, nothing, dec)      # env/truth 없이도 CB 에 닿기 전에 돌아선다
            @test r.handled === false && r.verdict === :reject && r.registered === false
        end
    finally
        old === nothing ? delete!(ENV, "ZONE_REPAIR_VERIFICATION") : (ENV["ZONE_REPAIR_VERIFICATION"] = old)
    end
end

@testset "[10] 우회 감사 — 생성 코드 등록/집행 호출처는 enact_minted_decision!(문 뒤)과 ToolExecution 뿐" begin
    # 파일을 **구문 분석**해 함수별 호출 이름을 모은다(주석·docstring 의 이름은 호출이 아니다).
    fname(sig) = sig isa Expr && sig.head === :where ? fname(sig.args[1]) :
                 sig isa Expr && sig.head === :call ? string(sig.args[1]) : nothing
    function calls_by_function(path)
        out = Dict{String,Set{String}}()
        walk(x, cur) = if x isa Expr
            if x.head in (:function, :(=)) && length(x.args) == 2 && fname(x.args[1]) !== nothing &&
               (x.head === :function || (x.args[1] isa Expr && x.args[1].head in (:call, :where)))
                cur = fname(x.args[1])
            end
            x.head === :call && push!(get!(out, cur, Set{String}()), string(x.args[1]))
            foreach(a -> walk(a, cur), x.args)
        end
        walk(Meta.parseall(read(path, String); filename = path), "<toplevel>")
        return out
    end
    targets = ("CB.register_minted_primitive!", "CB.enact_minted!", "register_minted_primitive!", "enact_minted!",
               "_install_rewrite!", "_rewrite_retry!", "_rewrite_once")
    callers = Dict{String,Vector{String}}()
    for dir in (joinpath(ROOT, "src"), joinpath(ROOT, "tools", "monitor")), (d, _, fs) in walkdir(dir), f in fs
        endswith(f, ".jl") || continue
        p = joinpath(d, f)
        cbf = try calls_by_function(p) catch; continue end
        for (fn, cs) in cbf, t in targets
            t in cs && push!(get!(callers, t, String[]), relpath(p, ROOT) * "::" * fn)
        end
    end
    log("[10] callers: ", callers)
    world_entry = Set(["tools/monitor/enact.jl::enact_minted_decision!", "tools/monitor/enact.jl::_install_rewrite!",
                       "tools/monitor/enact.jl::_rewrite_retry!", "tools/monitor/enact.jl::_rewrite_once"])
    tx = r"^src/verification/tool_execution\.jl::"
    for t in ("CB.register_minted_primitive!", "CB.enact_minted!")
        @test all(c -> c in world_entry || occursin(tx, c), get(callers, t, String[]))
        @test any(c -> occursin(tx, c), get(callers, t, String[]))          # 도메인: 스캐너가 실제로 찾았다
    end
    # CB 안의 비한정 호출은 정의 파일 자신뿐이어야 한다(다른 CB 코드가 몰래 부르지 않는다)
    @test all(c -> startswith(c, "src/respec/minted_"), vcat(get(callers, "register_minted_primitive!", String[]),
                                                            get(callers, "enact_minted!", String[])))
    # rewrite 사슬은 enact_minted_decision! 안에서만 시작한다
    @test all(c -> c in world_entry, get(callers, "_install_rewrite!", String[]))
    @test all(c -> c in world_entry, get(callers, "_rewrite_retry!", String[]))
    @test all(c -> c in world_entry, get(callers, "_rewrite_once", String[]))
    # 문이 enact_minted_decision! 본문에서 등록·rewrite·집행 호출 **어느 것보다 앞**에 있다(구문 트리의 순서로)
    ex = Meta.parseall(read(joinpath(ROOT, "tools", "monitor", "enact.jl"), String))
    body = Ref{Any}(nothing)
    findef(x) = x isa Expr && (x.head === :function && fname(x.args[1]) == "enact_minted_decision!" ? (body[] = x.args[2]) :
                               foreach(findef, x.args))
    findef(ex)
    order = String[]
    seq(x) = x isa Expr && (x.head === :call && push!(order, string(x.args[1])); foreach(seq, x.args))
    seq(body[])
    ig = findfirst(==("zrv_refuses_raw_body"), order)
    @test ig !== nothing
    for t in ("CB.register_minted_primitive!", "CB.enact_minted!", "_install_rewrite!", "_rewrite_retry!", "_rewrite_once")
        i = findfirst(==(t), order)
        @test i !== nothing && ig < i
    end
end

@testset "[11] follow! — 완결된 줄만, stop 뒤 비운다" begin
    d = mktempdir(); src = joinpath(d, "a.log"); dst = joinpath(d, "b.log")
    write(src, "")
    stop = Ref(false)
    t = RT.follow!(src, RT.append_sink(dst), stop)
    open(io -> write(io, "one\ntw"), src, "a"); sleep(0.8)
    @test read(dst, String) == "one\n"
    open(io -> write(io, "o\nthree"), src, "a"); sleep(0.8)
    @test read(dst, String) == "one\ntwo\n"
    stop[] = true; wait(t)
    @test read(dst, String) == "one\ntwo\nthree"
end

@testset "[12] shadow 에서 도구가 선택돼도 commit 하지 않는다 — 부모는 resume, commit worker 없음" begin
    root = mktempdir()
    dir = mkpath(joinpath(root, "parent")); ctl = mkpath(joinpath(dir, "control"))
    wj(p, d) = open(io -> JSON3.write(io, d), p, "w")
    write(joinpath(dir, "t0.envelope.json"), "{}"); wj(joinpath(dir, "task_contract.json"), Dict("x" => 1))
    wj(joinpath(dir, "contract.json"), Dict("checkpoint_id" => "t0", "envelope" => joinpath(dir, "t0.envelope.json"), "t0_iter" => 1,
        "batch_pos" => 1, "sim_params" => Dict(), "pi0" => Dict(), "gaps" => String[], "parent_pid" => 1, "real_ledger" => "",
        "task_contract" => Dict("sha256" => bytes2hex(sha256(read(joinpath(dir, "task_contract.json")))))))
    write(joinpath(dir, "held.json"), "{}")
    p = run(`sleep 600`; wait = false); seen = String[]
    @async while process_running(p)
        f = joinpath(ctl, "$(length(seen) + 1).cmd")
        if isfile(f)
            c = strip(read(f, String)); push!(seen, c)
            wj(joinpath(ctl, "$(length(seen)).out.json"), c == "verify" ?
               Dict("mismatched_blocks" => String[], "counters_equal" => true, "rng_equal" => true) : Dict("cmd" => c))
            c in ("resume", "exit") && kill(p)
        end
        sleep(0.05)
    end
    par = (process = p, dir = dir, token = "fake", log = devnull)
    sv = S.Supervision(par; outroot = joinpath(root, "out"), launch_env = Dict{String,String}(),
                       limits = BR.Limits(wall_s = 30, cpu_s = 10, mem_bytes = 10))
    try
        # 같은 trace/terminal 을 기준 분기와 부모에 → replay 일치(이 시험이 보는 것은 전이·명령이다)
        bd = mkpath(joinpath(sv.outroot, "noop"))
        for d in (bd, dir)
            write(joinpath(d, "trace.tsv"), "1\ta\tb\tc\td\te\tf\tg\n2\ta\tb\tc\td\te\tf\tg\n")
            wj(joinpath(d, "terminal.json"), Dict("iter" => 2, "complete" => true, "terminal_reason" => "project_complete"))
        end
        sv.baseline = (report = R.RolloutReport("noop", "t0", :FAIL_WITHIN_BUDGET, nothing, :no_progress_limit, 2, 1.0, 1.0, 0, Dict{String,Int}()),
                       dir = bd)
        sv.verify0 = Dict{String,Any}("mismatched_blocks" => String[], "counters_equal" => true, "rng_equal" => true)
        sv.selection = R.SelectionReport("t0", :FAIL_WITHIN_BUDGET, :tool, "p1", :rescued, String[], Dict("p1" => :COMPLETE), ["stub"])
        sv.state = :SELECTED_TOOL
        S.shadow_fork!(sv)
        S.commit!(sv)
    finally
        S.retire!(sv)
    end
    @test [t["to"] for t in sv.transitions][2:end] == ["SHADOW_NOT_COMMITTED", "SELECTED_NOOP", "PRECOMMIT_VERIFIED", "COMMITTED", "REPLAY_CHECKED"]
    @test sv.commit === nothing && !isdir(joinpath(sv.outroot, "commit"))            # commit worker 를 띄우지 않았다
    @test seen == ["verify", "resume"] && sv.replay.kind === :noop && sv.replay.match
    @test sv.selection.selected === :tool                                           # 선택 기록은 그대로 남는다
    # 다른 상태에서는 아무것도 안 한다
    @test S.shadow_fork!(sv) === sv                                                 # REPLAY_CHECKED — no-op
end

@testset "[13] 부모·분기 env 는 허용 목록 — 이름이 비밀 패턴을 피하는 운영자 변수는 넘어가지 않는다(T8 리뷰)" begin
    inv = RT.config_env_inventory()
    @test all(k -> k in inv.names, ("DEMO_SEED", "REPAIR_ABLATION", "ZONE_REPAIR_VERIFICATION", "ZONE_REPAIR_PROPOSALS", "HOME", "PATH"))
    @test "DEMO_" in inv.prefixes
    fake = "zrv-fake-not-a-secret"                                  # 가짜 값 — 실제 자격 증명 아님
    leaky = ("ZZ_GITHUB_PAT_TEST", "PGPASSFILE", "KUBECONFIG", "DATABASE_DSN", "GITHUB_PAT")
    op = merge(PI0CELL, Dict(k => fake for k in leaky), Dict("ZONE_REPAIR_VERIFICATION" => "shadow", "JULIA_NUM_THREADS" => "1",
               "ZRV_BRANCH_ROLE" => "x", "DSPY_URL" => "http://127.0.0.1:1", "HOME" => ENV["HOME"], "SHELL" => "/bin/zsh"))
    # 음성 대조: 이름 패턴 거부 목록만으로는 이 이름들이 **새어 나간다**(그래서 허용 목록이 필요하다)
    @test all(k -> !BR.denied_env(k), leaky)
    l = RT.launch_env_from(op)
    @test all(k -> !haskey(l, k), leaky) && !haskey(l, "SHELL") && !haskey(l, "ZRV_BRANCH_ROLE")
    @test all(k -> l[k] == PI0CELL[k], keys(PI0CELL)) && l["JULIA_NUM_THREADS"] == "1" && l["ZONE_REPAIR_VERIFICATION"] == "shadow"
    # 두 번째 층: worker env(부모·분기 공통)에서 서비스 주소도 빠진다, 값은 어디에도 없다
    for extra in (Dict("ZRV_BRANCH_ROLE" => "parent"), Dict("ZRV_BRANCH_ROLE" => "branch"))
        we, removed = BR.worker_env(l, extra)
        @test all(k -> !haskey(we, k), leaky) && !haskey(we, "DSPY_URL") && removed == ["DSPY_URL"]
        @test !any(==(fake), values(we))
    end
end

end # testset
end # fast

# =============================================================================
# 에피소드 (tractor zone s26 — NOOP 이 완주하는 fixture, T3~T7 과 같은 칸). 순차, 한 디렉터리.
# =============================================================================
if !isempty(ARGS) && ARGS[1] == "episodes"
root, offdir = abspath(ARGS[2]), abspath(ARGS[3])
mkpath(root)
stream_name = "tractor__pi0_zone_s26_z26.jsonl"
off_stream = joinpath(offdir, "pre-plain", "out", "streams", stream_name)
off_trace = joinpath(offdir, "pre-trace", "trace.tsv")
off_score = only(filter(l -> startswith(l, "[score] "), readlines(joinpath(offdir, "pre-plain", "run.log"))))
score_of(txt) = filter(l -> startswith(l, "[score] "), split(txt, '\n'))
only_names(dir) = sort!(readdir(dir))
R_ = Dict{String,Any}()
"`T8_EPISODES=E1,E3` 면 그 판만(재실행용). 비면 전부."
want(e) = (w = strip(get(ENV, "T8_EPISODES", "")); isempty(w) || e in split(w, ','))

@testset "T8 runtime wiring — episodes (tractor zone s26)" begin

want("E1") && @testset "E1 shadow via render_demo.jl — 후보는 worker 에서 평가, 원래 세계는 off 와 같은 궤적" begin
    d = joinpath(root, "E1"); zr = joinpath(d, "zr")
    log("E1 start")
    # T8 리뷰: 운영자 셸의 비밀 모양 변수(이름이 거부 패턴을 피한다, 값은 가짜)가 부모·분기 env 에 없어야 한다
    r = render(merge(PI0CELL, Dict("ZONE_REPAIR_VERIFICATION" => "shadow", "ZONE_REPAIR_PROPOSALS" => FIXTURE,
                                   "ZZ_GITHUB_PAT_TEST" => "zrv-fake-not-a-secret",
                                   "DEMO_OUT_DIR" => joinpath(d, "out"), "ZONE_REPAIR_DIR" => zr)); logfile = joinpath(root, "E1.log"))
    log("E1 done code=", r.code)
    ep = BR._json(joinpath(zr, "episode.json")); R_["E1"] = ep
    sup = ep["supervision"]; states = [t["to"] for t in sup["transitions"]]
    @test r.code == 0 && ep["exit_code"] == 0
    @test occursin("\n[run-ctx] ", r.out) && score_of(r.out) == [off_score]        # 실제 로그 = 원래 세계(부모)의 로그
    @test occursin("[zrv-episode] mode=shadow certification=available", r.out)
    @test ep["active_world"]["kind"] == "original_world"
    @test states == ["CAPTURED", "IDENTITY_VERIFIED", "PROPOSALS_FROZEN", "BASELINE_AND_CANDIDATE_ROLLOUTS",
                     "SELECTED_NOOP", "PRECOMMIT_VERIFIED", "COMMITTED", "REPLAY_CHECKED"]
    @test sup["gaps"] == String[] && ep["decision_gaps"] == String[]
    c = only(values(sup["candidates"]))
    @test c["outcome"] == "COMPLETE" && c["eligible"] === true                      # 후보가 실제 worker 에서 집행·검증됐다
    @test isfile(joinpath(c["dir"], "enactment.json")) && BR._json(joinpath(c["dir"], "enactment.json"))["status"] == "enacted"
    @test sup["selection"]["classification"] == "baseline_complete"
    @test sup["replay"]["kind"] == "noop" && sup["replay"]["match"] === true && sup["replay"]["certified"] === true
    # 🔴 shadow = 관측 전용: 원래 세계의 실제 스트림이 off(변경 전 커밋, 무하네스)와 바이트 동일, 전 스텝 trace 가 off(trace 하니스)와 같다
    real = joinpath(d, "out", "streams", stream_name)
    @test isfile(real) && read(real) == read(off_stream)
    ct = RC.compare_traces(off_trace, joinpath(zr, "parent", "trace.tsv"); ignore = ("rng",))
    @test ct.first_divergent_iter === nothing && ct.only_a == 0 && ct.only_b == 0 && ct.n_common >= 883
    R_["E1_trace"] = Dict(pairs(ct))
    # shadow 원장은 분기 디렉터리에만 — 실제 산출물 폴더에는 실제 스트림 하나
    @test only_names(joinpath(d, "out", "streams")) == [stream_name]
    for b in ("noop", "noop-b", c["dir"])
        bd = isabspath(b) ? b : joinpath(zr, "supervision", b)
        @test isfile(joinpath(bd, "shadow_MONITOR_IO.jsonl"))
        @test BR._json(joinpath(bd, "terminal.json"))["resume"]["dispatch_guard"] == []    # 같은 사건 중복 주입/dispatch 없음
    end
    plog = read(joinpath(zr, "parent", "run.log"), String)
    @test count("[zrv] zone event at t0 → pi0 NOOP in this world (role=parent)", plog) == 1   # 한 번만 dispatch
    @test !occursin("CERTIFICATION UNAVAILABLE", plog) && !occursin("lane=zrv_refused", plog)
    # t0 는 그 사건의 첫 결정보다 앞(capture 가 policy_producer 의 존 dispatch 보다 먼저 찍힌다)
    @test first(findfirst("[zrv] t0 captured", plog)) < first(findfirst("[zrv] zone event at t0", plog))
    # T2: production 경로의 실제 Main 스크립트 전역이 checkpoint 에 있다, gap 은 명시된 하나(T5 문구, task_contract 로 해소)뿐
    fj = BR._json(joinpath(zr, "parent", "ckpt", "t0.fields.json"))
    mains = sort!([k for k in keys(fj["field_sha256"]) if startswith(k, "globals.Main.")])
    for k in ("globals.Main.pre", "globals.Main.stream_path", "globals.Main._ZONE_CT", "globals.Main._REFORM_CT", "globals.Main.RUN_CTX")
        @test k in mains
    end
    env0 = BR._json(joinpath(zr, "parent", "t0.envelope.json"))
    @test env0["gaps"] == ["task_world: original task contract not supplied (T5)"]
    @test env0["dispatch"]["zone_event_index"] == 1 && length(env0["dispatch"]["pending"]) == 1
    R_["E1_main_globals"] = mains
    # 허용 목록: 부모와 모든 분기의 실행 env 이름에 운영자 변수가 없다(값은 애초에 기록되지 않는다), checkpoint ENV 에도 없다
    for ld in [joinpath(zr, "parent"); [joinpath(zr, "supervision", b) for b in ("noop", "noop-b", "cand-1")]]
        names = BR._json(joinpath(ld, "launch.json"))["env_names"]
        @test !("ZZ_GITHUB_PAT_TEST" in names) && "DEMO_SEED" in names
    end
    @test !occursin("ZZ_GITHUB_PAT_TEST", read(joinpath(zr, "parent", "ckpt", "t0.small_fields.tsv"), String))
    @test !occursin("zrv-fake-not-a-secret", read(joinpath(zr, "parent", "ckpt", "t0.small_fields.tsv"), String))
end

want("E1b") && @testset "E1b shadow + 도구 선택(기준 결과 강제 — 시험 전용) — 선택돼도 원래 세계는 off 와 같은 궤적" begin
    d = joinpath(root, "E1b"); mkpath(d)
    lf = joinpath(root, "E1b.log")
    env = merge(PI0CELL, Dict("ZONE_REPAIR_VERIFICATION" => "shadow", "ZONE_REPAIR_PROPOSALS" => FIXTURE))
    log("E1b start")
    ep = open(lf, "w") do io
        RT.run_episode!(; mode = :shadow, launch_env = env, root = joinpath(d, "zr"), proposals = fixture(), source = :fixture,
            out_dir = joinpath(d, "out"), noise_floor = true, baseline_override = :FAIL_WITHIN_BUDGET, log_io = io)
    end
    log("E1b done exit=", ep["exit_code"])
    R_["E1b"] = ep
    out = read(lf, String)
    sup = ep["supervision"]; states = [t["to"] for t in sup["transitions"]]
    @test states == ["CAPTURED", "IDENTITY_VERIFIED", "PROPOSALS_FROZEN", "BASELINE_AND_CANDIDATE_ROLLOUTS", "SELECTED_TOOL",
                     "SHADOW_NOT_COMMITTED", "SELECTED_NOOP", "PRECOMMIT_VERIFIED", "COMMITTED", "REPLAY_CHECKED"]
    @test sup["selection"]["selected"] == "tool" && sup["commit"] === nothing
    @test !isdir(joinpath(d, "zr", "supervision", "commit"))
    @test ep["active_world"]["kind"] == "original_world" && ep["exit_code"] == 0
    @test sup["replay"]["match"] === true
    @test score_of(out) == [off_score]
    @test read(joinpath(d, "out", "streams", stream_name)) == read(off_stream)
    ct = RC.compare_traces(off_trace, joinpath(d, "zr", "parent", "trace.tsv"); ignore = ("rng",))
    @test ct.first_divergent_iter === nothing && ct.only_a == 0 && ct.only_b == 0 && ct.n_common >= 883
end

want("E3") && @testset "E3 enforce (문·기준 결과 강제 — 시험 전용) — commit worker 가 활성 세계, 기록이 그것을 읽는다" begin
    d = joinpath(root, "E3"); mkpath(d)
    lf = joinpath(root, "E3.log")
    env = merge(PI0CELL, Dict("ZONE_REPAIR_VERIFICATION" => "enforce", "ZONE_REPAIR_PROPOSALS" => FIXTURE))
    log("E3 start")
    ep = open(lf, "w") do io
        RT.run_episode!(; mode = :enforce, launch_env = env, root = joinpath(d, "zr"), proposals = fixture(), source = :fixture,
            capabilities = Dict{String,Any}("enforce_allowed" => true, "test_forced" => true, "not_enforced" => String[]),
            out_dir = joinpath(d, "out"), noise_floor = true, baseline_override = :FAIL_WITHIN_BUDGET, log_io = io)
    end
    log("E3 done exit=", ep["exit_code"])
    R_["E3"] = ep
    out = read(lf, String)
    sup = ep["supervision"]; states = [t["to"] for t in sup["transitions"]]
    @test ep["enforce_gate"] == "FORCED (test)" && startswith(ep["baseline_override"], "FORCED (test)")
    @test states == ["CAPTURED", "IDENTITY_VERIFIED", "PROPOSALS_FROZEN", "BASELINE_AND_CANDIDATE_ROLLOUTS",
                     "SELECTED_TOOL", "PRECOMMIT_VERIFIED", "COMMITTED", "REPLAY_CHECKED"]
    @test sup["commit"]["status"] == "committed" && sup["commit"]["activated"] === true && sup["commit"]["replay_match"] === true
    @test occursin("FORCED (test)", join(sup["selection"]["reasons"], " "))
    aw = ep["active_world"]
    @test aw["kind"] == "commit_worker" && aw["terminal"]["complete"] === true && ep["exit_code"] == 0
    # 기록 = 활성 세계: [score] 는 commit worker terminal 에서, 그 worker 의 log 는 [active-world] 로
    @test only(score_of(out)) == RT.score_line(aw["terminal"])
    @test occursin("[active-world] ", out) && occursin("[zrv-runtime] commit worker commit is the active world", out)
    # 실제 스트림 = 부모(t0 까지) ‖ commit worker 원장(t0 부터) — splice 지점에서 정확히 이어 붙었다
    real = joinpath(d, "out", "streams", stream_name)
    act = joinpath(aw["dir"], "shadow_MONITOR_IO.jsonl")
    sp = ep["real_ledger_splice"]
    @test sp["real"] == real && sp["active"] == act
    @test filesize(real) == sp["real_bytes_at_activation"] + filesize(act)
    @test read(real)[sp["real_bytes_at_activation"]+1:end] == read(act)
    @test filesize(act) > 0
    # 원래 세계는 t0 에서 멈춘 채 은퇴(더 굴지 않았다), 두 세계가 동시에 굴지 않았다
    pd = joinpath(d, "zr", "parent")
    # (부모 trace 는 t0 경계의 행을 hold 가 끝난 **뒤**에 쓴다 — 은퇴한 부모는 데이터 행이 0 이고 terminal 은 atexit 의 t0 기록)
    @test count(l -> !startswith(l, "#"), eachline(joinpath(pd, "trace.tsv"))) == 0
    pt = BR._json(joinpath(pd, "terminal.json"))
    @test pt["iter"] == ep["t0_iter"] && pt["written_at"] == "atexit (no sim_end)" && pt["complete"] === false
    @test any(f -> endswith(f, ".cmd") && strip(read(joinpath(pd, "control", f), String)) == "exit", readdir(joinpath(pd, "control")))
    # commit worker 안에서도 t0 의 존 사건은 **한 번** pi0 NOOP 으로 dispatch 된다(도구는 dispatch 가 아니다), 중복 주입 없음
    clog = read(joinpath(aw["dir"], "run.log"), String)
    @test count("[zrv] zone event at t0 → pi0 NOOP in this world (role=branch)", clog) == 1
    @test BR._json(joinpath(aw["dir"], "terminal.json"))["resume"]["dispatch_guard"] == []
    h = BR._json(aw["handover"])
    @test h["parent"]["retired"] === true && h["t1_iter"] == ep["t0_iter"] + h["engine_steps"] && h["engine_steps"] == 3
end

want("E4") && @testset "E4 지연 존(DEMO_ZONE_PRESIM=0) — t0 capture 불가를 조용히 넘기지 않는다" begin
    d = joinpath(root, "E4"); zr = joinpath(d, "zr")
    log("E4 start")
    r = render(merge(PI0CELL, Dict("ZONE_REPAIR_VERIFICATION" => "shadow", "ZONE_REPAIR_PROPOSALS" => FIXTURE,
                                   "DEMO_ZONE_PRESIM" => "0", "DEMO_OUT_DIR" => joinpath(d, "out"), "ZONE_REPAIR_DIR" => zr));
               logfile = joinpath(root, "E4.log"))
    log("E4 done code=", r.code)
    ep = BR._json(joinpath(zr, "episode.json")); R_["E4"] = ep
    @test ep["certification"] == "unavailable" && ep["active_world"]["kind"] == "original_world"
    @test occursin("no t0 capture", ep["certification_reasons"][1])
    @test any(x -> occursin("zone event dispatched without a t0 capture", x), ep["certification_reasons"])
    @test occursin("[zrv] CERTIFICATION UNAVAILABLE", r.out)
    @test !isdir(joinpath(zr, "supervision")) && !isfile(joinpath(zr, "parent", "held.json"))
    @test ep["exit_code"] == r.code && length(score_of(r.out)) == 1
end

want("E5") && @testset "E5 결정 전 지문 불일치(후보 provenance 의 서비스 source) — rollout 없이 인증 불가, 원래 세계 NOOP" begin
    d = joinpath(root, "E5"); zr = joinpath(d, "zr"); mkpath(d)
    bad = fixture(); bad[1]["provenance"]["service_code_fingerprint"] = "deadbeefdeadbeef"
    bf = joinpath(d, "stale_proposals.json"); write(bf, JSON3.write(bad))
    log("E5 start")
    r = render(merge(PI0CELL, Dict("ZONE_REPAIR_VERIFICATION" => "shadow", "ZONE_REPAIR_PROPOSALS" => bf,
                                   "DEMO_OUT_DIR" => joinpath(d, "out"), "ZONE_REPAIR_DIR" => zr)); logfile = joinpath(root, "E5.log"))
    log("E5 done code=", r.code)
    ep = BR._json(joinpath(zr, "episode.json")); R_["E5"] = ep
    sup = ep["supervision"]; states = [t["to"] for t in sup["transitions"]]
    @test occursin("generated by service source deadbeefdeadbeef != this tree", only(ep["decision_gaps"]))
    @test states == ["CAPTURED", "CERTIFICATION_UNAVAILABLE", "SELECTED_NOOP", "COMMITTED", "REPLAY_CHECKED"]
    @test ep["certification"] == "unavailable" && sup["baseline"] === nothing && isempty(sup["candidates"])
    @test !isdir(joinpath(zr, "supervision", "noop")) && !isdir(joinpath(zr, "supervision", "cand-1"))
    @test r.code == 0 && score_of(r.out) == [off_score]
    @test read(joinpath(d, "out", "streams", stream_name)) == read(off_stream)
end

end # testset
open(io -> JSON3.pretty(io, JSON3.write(R_)), joinpath(root, "results.json"), "w")
end
