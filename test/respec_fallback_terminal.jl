# =============================================================================
# respec_fallback_terminal.jl — `engage_fallback!` 은 TERMINAL 이다 (사용자 결정 D-13)
#
# 🔴 **이 파일이 존재하는 이유는 재발이다.** 같은 실패 모양이 이 레포에서 두 번 나왔다:
#
#   1. `verifier.jl` (RELOCATE_GATE) 의 docstring 이 "빌드는 계속 돈다" 고 주장했다 —
#      근거는 아무도 켜지 않는 opt-in `set_failclosed_stop!` 이었다. 2026-08-18 정정.
#   2. `replan.jl` 의 `engage_fallback!` docstring 이 스스로를 "recoverable" 이라 부르고
#      호출자에게 `release_fallback!` 과 짝지으라고 요구했다 — production 호출자 0 개.
#      2026-08-21 정정 (D-13).
#
#    **스무 줄 떨어진 같은 파일군에서 두 번.** 한 번은 사고고 두 번은 패턴이므로, 세 번째를
#    사람이 아니라 기계가 막는다.
#
# 이 시험이 지키는 계약: **`release_fallback!` 의 production 호출자 수 == 0.**
# 누가 나중에 호출자를 넣으면 이 시험이 빨개지고, 그때 docstring 의 "terminal" 주장을 같이
# 고치도록 강제한다. (호출자를 넣는 것 자체는 금지가 아니다 — 문서와 코드가 **함께** 움직이는
# 것을 강제하는 것이다. 그게 두 번의 재발이 공통으로 어긴 규약이다.)
#
# ⚠️ 이 시험은 **항진명제가 되기 쉽다** — 스캐너가 아무것도 못 찾으면 언제나 0 이다.
#    그래서 아래 [2] 가 **음성 대조**로 스캐너 자신이 호출을 실제로 볼 수 있음을 증명한다.
# =============================================================================

using ConstructionBots, Test

const CB = ConstructionBots
const REPO = dirname(@__DIR__)

"""
`root` 아래 `.jl` 전부에서 `name` 의 **호출**(`name(`) 이 나오는 (파일, 행번호, 내용) 목록.

호출이 아닌 것은 뺀다:
  · `function name(` — 정의 자신
  · 줄 앞이 `#` 인 주석
  · `\"\"\"` 로 둘러싸인 docstring 블록 안
정의·주석·docstring 은 계약을 어기지 않는다 — **부르는 것**만 어긴다.
"""
function _call_sites(root::AbstractString, name::AbstractString)
    hits = Tuple{String,Int,String}[]
    needle = name * "("
    for (dir, _, files) in walkdir(root), f in files
        endswith(f, ".jl") || continue
        path = joinpath(dir, f)
        in_doc = false
        for (i, line) in enumerate(eachline(path))
            # docstring 경계: 한 줄에 `"""` 가 홀수 번 나오면 상태가 뒤집힌다.
            # ⚠️ 바이트 인덱스로 자르지 말 것 — 이 레포의 주석은 한글이라 UTF-8 경계에서 죽는다
            #    (이 시험을 처음 쓸 때 실제로 `StringIndexError` 로 죽었다).
            n_q = count("\"\"\"", line)
            stripped = lstrip(line)
            if !in_doc && occursin(needle, line) &&
               !startswith(stripped, "#") &&
               !occursin("function " * needle, line)
                push!(hits, (relpath(path, REPO), i, strip(line)))
            end
            isodd(n_q) && (in_doc = !in_doc)
        end
    end
    return hits
end

@testset "🔴 D-13 — engage_fallback! 은 terminal 이다" begin

    # --- [1] 계약: production 호출자 0 개 --------------------------------------
    #     `src/` 와 `tools/` 둘 다 본다 — run_demo.jl 이 실행 레인이므로 production 이다.
    @testset "[1] release_fallback! 의 production 호출자가 없다" begin
        sites = vcat(_call_sites(joinpath(REPO, "src"),   "release_fallback!"),
                     _call_sites(joinpath(REPO, "tools"), "release_fallback!"))
        if !isempty(sites)
            @info "release_fallback! 호출자가 생겼다" sites
        end
        @test isempty(sites)
    end

    # --- [2] 🔴 음성 대조: 스캐너가 항진이 아님 --------------------------------
    #     스캐너가 정말로 호출을 볼 수 있는가? 실제로 존재하는 호출을 세어 증명한다.
    #     `engage_fallback!` 은 replan.jl 안에서 여러 번 **불린다**(거부 분기들).
    @testset "[2] 음성 대조 — 스캐너가 실제 호출을 본다" begin
        eng = _call_sites(joinpath(REPO, "src"), "engage_fallback!")
        @test length(eng) >= 5          # 실측 기준 15+ 개. 5 는 넉넉한 하한
        # 그리고 정의 줄은 세지 않았는가
        @test !any(s -> occursin("function engage_fallback!(", s[3]), eng)
    end

    # --- [3] 래치가 실제로 영구인가 --------------------------------------------
    #     "terminal" 주장의 **기전**을 확인한다: 켜면 스스로 안 꺼진다.
    @testset "[3] RESPEC_HOLD 는 스스로 풀리지 않는다" begin
        was = CB.RESPEC_HOLD[]
        try
            CB.RESPEC_HOLD[] = true
            @test CB.RESPEC_HOLD[] == true          # 아무도 안 껐다
            CB.release_fallback!()                  # 오직 이것만이 푼다
            @test CB.RESPEC_HOLD[] == false
        finally
            CB.RESPEC_HOLD[] = was                  # 🔴 이 시험 자신이 래치를 안 남긴다
        end
    end

    # --- [4] docstring 이 "recoverable" 을 다시 주장하지 않는다 ------------------
    #     두 번의 재발이 전부 **문서**에서 났으므로 문서도 건다.
    @testset "[4] docstring 이 terminal 을 말한다" begin
        # 정의 줄을 앵커로 잡고 **그 앞의** docstring 블록을 줄 단위로 되짚는다.
        # (바이트 슬라이싱 금지 — 위 [1] 의 이유와 같다.)
        lines = readlines(joinpath(REPO, "src", "respec", "replan.jl"))
        def   = findfirst(l -> occursin("function engage_fallback!(", l), lines)
        @test def !== nothing

        close_q = findlast(l -> occursin("\"\"\"", l), lines[1:def-1])   # 닫는 """
        @test close_q !== nothing
        open_q  = findlast(l -> occursin("\"\"\"", l), lines[1:close_q-1])  # 여는 """
        @test open_q !== nothing

        block = join(lines[open_q:close_q], "\n")
        @test occursin("engage_fallback!", block)      # 정말 그 docstring 을 잡았나
        @test occursin("TERMINAL", block) || occursin("terminal", block)
        @test !occursin("The recoverable fallback", block)
    end
end
