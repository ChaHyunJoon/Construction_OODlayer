# =============================================================================
# **SoC 임계 넷이 하나의 사다리인가.** (2026-08-31, S1/T3)
#
# 왜 이 파일이 필요한가 — 2026-08-31 실측
# ----------------------------------------
# 임계 셋이 갈라져 (0.1, 0.2] 구간이 조용히 죽어 있었다: 그 구간은 `routing_kind` 가
# `unknown:battery_mild`(LLM 레인)를 내면서 `battery_arms` 는 개입 팔 셋을 다 준다 —
# 즉 그 구간에서 합성 레인은 구조적으로 절대 발화하지 않는다.
# 🔴 그리고 두 임계를 **함께 보는 게이트가 레포에 0개였다**: `test_lane_select.jl` 은
# REPLACE_SOC_THRESHOLD/battery_arms 를 0회 언급하고, `mild_menu_is_noop_only.jl` 은
# ROUTING_SEVERE_SOC/routing_kind 를 0회 언급한다. 이 파일이 그 사이를 잇는다.
#
# 재는 명제 여섯
#   (1) 라우팅 경계와 메뉴 경계가 **같다** — 사다리 전 구간에서 두 판정이 일치한다
#   (2) 정지 임계가 deep 경계보다 **엄격히 낮다**
#       (같으면 deep 안에 감속 구간이 없어져 battery_ladder_is_deep_only 단언 2 가
#        만족 불가능해진다 — D-6 이 그래서 폐기됐다)
#   (3) severe 데모 프리셋이 **정지 임계 아래로 확실히 떨어진다**
#       soc_after <= 1 - DEMO_BSOC 이므로 (1 - DEMO_BSOC) <= stall 이면 충분하다
#   (4) 두 엔진(run_demo · render_demo)의 DEMO_BSOC·DEMO_STALL_SOC 기본값이 같다
#   (5) 라벨 레인의 DS_STALL 이 실행 레인의 정지 임계와 같다
#   (6) `isdefined(...) ? REPLACE_SOC_THRESHOLD[] : X` / `try...catch; X end` 류 폴백 리터럴을
#       src/·tools/·test/·wm4spacecraft_manufacturing/ 전체에서 **찾아서**(파일 목록을
#       하드코딩하지 않는다 — 2026-08-31 fix round 1, I-2) 전부 DEEP 과 같은지 잰다.
#       navigator.jl 이 include 안 된 경로에서 옛 사다리가 조용히 되살아나는 것을 막는다.
#       (2026-08-31 fix round 2 실측: 8곳. 이 숫자는 게이트가 강제하지 않는다 — 강제하면
#       또 하드코딩이 된다. 실행 시 진단 출력이 그때그때의 실제 개수를 보여 준다.)
#
# 변이시험 — 2026-08-31, 아래 다섯을 전부 실제로 돌려서 각각의 실패를 직접 봤다
# (task-3-report.md 에 각 mutation 의 실측 출력이 그대로 있다). 넷은 이 파일이 처음부터
# "일으키면 빨개진다"고 적었던 것이고, 다섯째(폴백)는 (3)의 정정과 같이 새로 더한 것이다.
#   · ROUTING_SEVERE_SOC 만 0.2 로 되돌리면 (1)이 빨개진다 — 실측: 8 passed, 3 failed.
#   · STALL_SOC_DEFAULT 를 REPLACE_SOC_THRESHOLD 와 같게 두면 (2)가 빨개진다 — 실측: 1 passed, 1 failed.
#   · 두 엔진 모두 DEMO_BSOC 기본값을 0.9 로 되돌리면 (3)이 빨개진다(1-0.9=0.09999… > STALL=0.05)
#     — 실측: 2 passed, 2 failed.
#   · 두 엔진 중 하나만 DEMO_BSOC 를 고치면(예: run_demo.jl 만 0.97) (4)가 빨개진다 —
#     실측: 2 passed, 1 failed.
#   · 발견된 폴백 자리 중 하나(battery.jl)만 리터럴 0.2 로 되돌리면 (6)이 빨개진다 —
#     실측(fix round 0, 목록이 여섯이던 시절): 11 passed, 1 failed. fix round 2 재구조화 뒤의
#     같은 실측은 task-3-report.md "Fix round 2" 절 참고.
#
# 🔴 **2026-08-31 실측 정정 — 계획 초안의 Step 2 음성대조 주장은 과장이었다.** 계획 초안은
#    "오늘의 HEAD 에 STALL=0.15 를 박으면 (1)(2)(3) 전부 빨갛다" 고 적었으나, 실제로 돌려
#    보면 **(1) 만 빨갛다(7 passed, 4 failed)**. (2)·(3)·(4)·(5)는 초록으로 남는다(당시
#    실측: 2/2, 4/4, 3/3, 3/3 전부 통과) — `0.15 < 0.2`(deep, 당시 HEAD 값)가 이미 참이고
#    `1.0 - 0.9 = 0.10 <= 0.15`(당시 STALL 스텁)도 이미 참이었기 때문이다. 이 파일이 HEAD 에서
#    실제로 잡던 결함은 (1)의 4 fail 뿐이었다 — 나머지는 위 변이시험처럼 T3 완료 뒤 값을
#    바꿔서 개별적으로 다시 확인해야 "잡는다"고 말할 수 있고, 위 다섯 줄이 그 실측이다.
#
# 실행: julia +lts --project=. test/soc_ladder_is_coherent.jl
# =============================================================================
module SocLadderIsCoherent

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
isdefined(@__MODULE__, :ActionRegistry) ||
    include(joinpath(REPO, "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))
include(joinpath(REPO, "tools", "monitor", "lane_select.jl"))
const AR = ActionRegistry

const DEEP  = Float64(CB.REPLACE_SOC_THRESHOLD[])
const STALL = Float64(CB.STALL_SOC_DEFAULT[])

"소스에서 리터럴 기본값을 읽는다 — 숫자를 여기 박으면 두 번째 진실원이 된다."
function envdefault(path, name)
    src = read(joinpath(REPO, path), String)
    m = match(Regex("get\\(ENV,\\s*\"$(name)\",\\s*\"([^\"]*)\"\\)"), src)
    m === nothing && error("$(path) 에서 $(name) 기본값을 못 찾았다 — 정규식을 고칠 것")
    return m.captures[1]
end

@testset "(1) 라우팅 경계와 메뉴 경계가 같다" begin
    for s in (0.0, 0.02, 0.05, DEEP - 1e-9, DEEP, nextfloat(DEEP), 0.15, 0.2, 0.3, 0.45, 0.9)
        local severe_by_routing = routing_kind("BatteryTruth", s) == "battery"
        local severe_by_menu    = length(AR.battery_arms(s, DEEP, true)) > 1
        @test severe_by_routing == severe_by_menu
    end
end

@testset "(2) 정지 임계가 deep 보다 엄격히 낮다" begin
    @test STALL < DEEP
    # 그래야 deep 안에 "정지하는 칸"과 "감속만 하는 칸"이 둘 다 존재할 수 있다.
    @test AR.battery_arms(STALL, DEEP, true) == AR.battery_arms(DEEP, DEEP, true)
end

@testset "(3) severe 프리셋이 정지 임계 아래로 확실히 떨어진다" begin
    for f in ("tools/monitor/run_demo.jl", "tools/monitor/render_demo.jl")
        local drop = parse(Float64, envdefault(f, "DEMO_BSOC"))
        # soc_after = max(floor_soc=0.0, soc_at_fire - drop) <= 1.0 - drop
        @test (1.0 - drop) <= STALL
        @test (1.0 - drop) <= DEEP        # 라우팅도 severe 로 간다
    end
end

@testset "(4) 두 엔진의 배터리 기본값이 같다" begin
    for name in ("DEMO_BSOC", "DEMO_STALL_SOC")
        @test envdefault("tools/monitor/run_demo.jl", name) ==
              envdefault("tools/monitor/render_demo.jl", name)
    end
    @test parse(Float64, envdefault("tools/monitor/run_demo.jl", "DEMO_STALL_SOC")) === STALL
end

@testset "(5) 라벨 레인의 정지 임계가 실행 레인과 같다" begin
    local gen = "wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl"
    @test parse(Float64, envdefault(gen, "DS_STALL")) === STALL
    # 학습 사다리의 모든 칸이 새 경계에서도 비교 가능해야 한다(battery_ladder_is_deep_only
    # 단언 1 과 같은 명제를 새 경계에서 다시 확인한다 — 그 파일과 겹치는 것이 의도다).
    for s in [parse(Float64, x) for x in split(envdefault(gen, "DS_BSOC"), ",")]
        @test length(AR.battery_arms(s, DEEP, true)) > 1
    end
end

# 폴백 정규식 — REPLACE_SOC_THRESHOLD 를 못 읽을 때 쓰는 리터럴을 두 형태로 잡는다:
#   `isdefined(...) ? REPLACE_SOC_THRESHOLD[] : X`   그리고   `try ... catch; X end`
# 모듈 스코프 상수로 둔 이유: 아래에서 스캐너 자신에게도 적용해 자기지시(self-match) 여부를
# 확인해야 하고(테스트 (6b)), 스캔 함수와 어서션 양쪽이 같은 패턴을 공유해야 "찾은 것과 잰
# 것이 같은 정규식"이라고 말할 수 있다.
const FALLBACK_RE = Regex(
    "REPLACE_SOC_THRESHOLD" * "\\[\\]\\s*:\\s*([0-9]*\\.?[0-9]+)" *
    "|REPLACE_SOC_THRESHOLD" * "\\[\\]\\)\\s*catch;\\s*([0-9]*\\.?[0-9]+)\\s*end")

"`dirs` 각각을 재귀적으로 훑어 `.jl` 파일에서 `re` 에 맞는 모든 자리를 찾는다. 각 `d` 는
REPO 상대경로(예: \"src\")이거나 절대경로(예: mktempdir() 결과)일 수 있다 — 후자는 (6b) 가
심는 파일을 REPO 밖의 임시 디렉터리에 두고도 같은 함수로 스캔하기 위해서다(2026-08-31 fix
round 2, N-3: 예전 버전은 test/ 안에 심어서, 프로세스가 write 와 finally 사이에서 죽으면
0.2 리터럴을 담은 파일이 test/ 에 그대로 남아 **다음 실행이 원인 모를 이유로 빨개지는**
위험이 있었다). 반환: (표시용 경로, 캡처된 리터럴 문자열) 쌍의 벡터 — REPO 안쪽 파일은
상대경로로, 밖은 절대경로로 보여 준다. 하드코딩한 파일 목록에 기대지 않는다 — 그래야 새로
생긴 폴백 자리도 잡는다(2026-08-31 fix round 1, I-2)."
function scan_fallback_sites(dirs, re)
    local hits = Tuple{String,String}[]
    for d in dirs
        local root = isabspath(d) ? d : joinpath(REPO, d)
        isdir(root) || continue
        for (dirpath, _, files) in walkdir(root)
            for fn in files
                endswith(fn, ".jl") || continue
                local fpath = joinpath(dirpath, fn)
                local text = read(fpath, String)
                for m in eachmatch(re, text)
                    # 캡처 그룹이 없는 정규식으로 부를 수도 있다((6b)의 "아무것도 안 잡아야
                    # 하는" 마커가 그렇다) — 그때는 매치 전체 문자열을 리터럴로 쓴다.
                    local lit = isempty(m.captures) ? m.match :
                                (m.captures[1] === nothing ? m.captures[2] : m.captures[1])
                    # REPO 안쪽이면 상대경로로 짧게, 밖(임시 디렉터리 등)이면 절대경로 그대로.
                    local shown = startswith(fpath, REPO) ? relpath(fpath, REPO) : fpath
                    push!(hits, (shown, lit))
                end
            end
        end
    end
    return hits
end

@testset "(6) REPLACE_SOC_THRESHOLD 폴백 리터럴이 진실원과 같다 (발견형)" begin
    # 🔴 2026-08-31 fix round 1 (I-2): 예전 버전은 파일 목록 다섯 개를 하드코딩했다 —
    # `test/battery_ladder_is_deep_only.jl` · `test/battery_menu_lanes_agree.jl` 이 각각
    # `catch; 0.2 end` 폴백을 갖고 있었는데도 목록에 없어서 스캔이 안 됐고, `total_sites == 6`
    # 이 그 틀린 개수를 굳혔다. 리뷰어가 새 폴백 파일을 심었는데도 6/6 그린이었다 — 저자가
    # 이미 아는 자리만 보는 게이트는 "단일 진실원" 보장이 아니다. 이제 파일 목록을 아예 없애고
    # src/·tools/·test/·wm4spacecraft_manufacturing/ 를 직접 훑는다.
    local hits = scan_fallback_sites(("src", "tools", "test", "wm4spacecraft_manufacturing"), FALLBACK_RE)
    # 🔴 스캐너가 하나도 못 찾으면 "패턴이 텅 비어도 통과하는" 실패할 수 없는 게이트가 된다
    # (I-2 의 경고 그대로) — 그래서 발견 개수 자체를 셈한다.
    @test length(hits) > 0
    for (path, lit) in hits
        @test parse(Float64, lit) == DEEP
    end
    # 2026-08-31 fix round 1 실측: 여덟 곳(src 셋 + tools 하나 + wm4 둘 + test 둘).
    # 이 숫자는 어서션이 아니라 진단용 출력이다 — 스캐너가 목록을 강제하면 I-2 가 도로 난다.
    println("    [진단] REPLACE_SOC_THRESHOLD 폴백 자리 ", length(hits), "곳: ",
            join(["$(p)=$(l)" for (p, l) in hits], ", "))
end

@testset "(6b) 스캐너 자기증명 — 두 방향" begin
    # 방향 1: 패턴이 아무것도 안 잡으면 빨개져야 한다(실패할 수 없는 게이트 방지, I-2).
    # 존재하지 않을 패턴으로 스캔해서 직접 확인한다.
    # 마커도 쪼개 이어붙인다 — 통짜 리터럴로 쓰면 이 정규식의 "정의 자체"가 test/ 스캔 대상인
    # 이 파일 소스 안에서 자기 자신과 매치돼(위 (6) 수정 때 밟은 것과 같은 함정) "아무것도 안
    # 잡는 패턴"을 만들려던 의도가 깨진다.
    local nothing_marker = "THIS_PATTERN" * "_MATCHES_NOTHING_" * "2026_08_31_FIX_ROUND_1"
    local nothing_re = Regex(nothing_marker)
    local empty_hits = scan_fallback_sites(("src", "tools", "test", "wm4spacecraft_manufacturing"), nothing_re)
    @test isempty(empty_hits)
    # 방향 2: 새 자리를 실제로 심으면 스캐너가 잡아야 한다.
    # 🔴 2026-08-31 fix round 2 (N-3): 예전 버전은 이 파일을 test/ 안에 썼다. `Pkg.test()` 가
    #    write 와 finally 사이에서 죽으면(kill, OOM, 정전) 0.2 리터럴을 담은 `.jl` 파일이
    #    test/ 에 그대로 남고, 그 파일은 이 게이트 자신의 (6) 이 훑는 디렉터리 안이라 **다음
    #    실행이 원인 모를 이유로 빨개진다.** `mktempdir()` 로 REPO 밖에 심어서 이 위험을
    #    구조적으로 없앤다 — 정리가 안 돼도 (6) 이 안 훑는 곳에 남을 뿐이다.
    mktempdir() do tmpdir
        # 문자열을 쪼개 이어붙인다 — 통짜 리터럴로 쓰면 **이 게이트 파일 자신의 소스**에
        # 폴백 패턴과 그대로 맞아떨어지는 부분문자열이 나타나서, 위 (6) 이 이 파일 자신을
        # 아홉 번째 자리로 잘못 집는다(2026-08-31 fix round 1 중 실측: 자기지시로 (6) 이
        # 빨개졌었다 — 첫 시도는 코드만 쪼개고 이 설명 주석 자체에 그 부분문자열을 다시
        # 써 넣는 바람에 또 걸렸다. 그래서 이 주석도 그 문자열을 통짜로 인용하지 않는다).
        local sym = ":REPLACE_SOC_THRESHOLD"
        local ref = "REPLACE_SOC_THRESHOLD" * "[]"
        local planted = joinpath(tmpdir, "_tmp_i2_planted_fallback.jl")
        write(planted, "thr = isdefined(@__MODULE__, $(sym)) ? $(ref) : 0.2\n")
        local planted_hits = scan_fallback_sites((tmpdir,), FALLBACK_RE)
        @test any(p -> p == planted, first.(planted_hits))
        # 심은 값(0.2)은 DEEP(0.1)과 다르므로, 실제 (6) 어서션 로직을 그대로 이 hit 에 적용하면
        # 빨개져야 한다 — 그것이 이 전체 방향의 요점이다.
        local this_hit = only(filter(h -> h[1] == planted, planted_hits))
        @test parse(Float64, this_hit[2]) != DEEP   # 심은 자리는 DEEP 과 달라야 발견의 의미가 있다
        # mktempdir() do 블록이 끝나면(정상/예외 무관) 줄리아가 tmpdir 자체를 지운다 — 여기서
        # 따로 rm 할 필요가 없다. test/ 는 애초에 건드리지 않았다.
    end
end

end # module
