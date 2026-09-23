# =============================================================================
# test/config_digest_inventory.jl — 설정 지문이 엔진이 실제로 읽는 설정을 싣는다 (Task 6b, R-B)
#
#   julia +lts --project=. test/config_digest_inventory.jl
#
# 🔴 왜 (2026-09-23 외부 리뷰 R-B): 옛 `config_digest` 는 접두사(`DEMO_`·`DS_`·`DSPY_`·
#    `TOOL_SYNTH`·`SYNTH_`) 안의 **설정된** env 만 해시했다. 그래서 `RESTAGE_ZONE_MARGIN_FRAC` 을
#    0.5 → 1.5 로 바꿔도 지문이 같았다(엔진은 그 값을 읽는다). 이제 render 경로(`src/**/*.jl`·
#    `tools/monitor/*.jl`)가 읽는 **모든** ENV 이름이 세 분류 중 하나에 명시돼 있어야 하고,
#    `result` 이름은 `name=<값 | "<unset>">` 으로 지문에 든다.
#
# (1) 인벤토리 게이트는 **어휘적**이다: `get(ENV,"X"…)` · `get!(ENV,"X"…)` · `ENV["X"]` ·
#     `haskey(ENV,"X")` 의 문자열 리터럴만 본다. 이름을 변수로 넘기는 읽기(`get(ENV, k, …)`)는
#     못 본다 — 2026-09-23 실측 render 경로에 그런 읽기는 0곳이다(주석 한 줄뿐).
#     `#` 로 시작하는 줄은 건너뛴다(주석 속 예시 `"X"`·`"NAME"` 이 이름으로 잡혔다).
# =============================================================================
module ConfigDigestInventory

using Test
import Random
include(joinpath(@__DIR__, "..", "tools", "monitor", "policy.jl"))

const REPO = normpath(joinpath(@__DIR__, ".."))
const _ENV_READ_RX = r"(?:get!?\(\s*ENV\s*,\s*\"([A-Za-z0-9_]+)\"|ENV\[\s*\"([A-Za-z0-9_]+)\"\s*\]|haskey\(\s*ENV\s*,\s*\"([A-Za-z0-9_]+)\")"

"render 경로의 소스 파일: `src/` 아래 모든 .jl + `tools/monitor/` 바로 아래 .jl."
function render_path_files(repo = REPO)
    fs = String[]
    for (d, _, names) in walkdir(joinpath(repo, "src")), n in names
        endswith(n, ".jl") && push!(fs, joinpath(d, n))
    end
    tm = joinpath(repo, "tools", "monitor")
    append!(fs, [joinpath(tm, n) for n in readdir(tm) if endswith(n, ".jl")])
    return sort!(fs)
end

"이름 => 읽는 파일들. 주석 줄(`#` 로 시작)은 건너뛴다."
function env_reads(files)
    out = Dict{String,Vector{String}}()
    for f in files, line in eachline(f)
        startswith(lstrip(line), "#") && continue
        for m in eachmatch(_ENV_READ_RX, line)
            name = something(m.captures...)
            push!(get!(out, name, String[]), f)
        end
    end
    return out
end

"`get(ENV, \"NAME\", \"lit\")` 의 리터럴 기본값들(주석 줄 제외)."
function literal_defaults(files, name)
    rx = Regex("get\\(\\s*ENV\\s*,\\s*\"$(name)\"\\s*,\\s*\"([^\"]*)\"")
    vals = Set{String}()
    for f in files, line in eachline(f)
        startswith(lstrip(line), "#") && continue
        for m in eachmatch(rx, line); push!(vals, m.captures[1]); end
    end
    return vals
end

const NONREPO = mktempdir()           # 설정 지문만 볼 때 코드 지문(git) 비용을 피한다
cfg(e)  = run_fingerprint(NONREPO; env = e).config_digest
cenv(e) = run_fingerprint(NONREPO; env = e).config_env

@testset "(1) 인벤토리 — render 경로의 ENV 읽기 ⊆ 세 분류의 합집합, 분류는 서로소" begin
    reads = env_reads(render_path_files())
    @test length(reads) > 50                                   # 도메인: 스캐너가 실제로 읽었다
    classified = union(Set(CONFIG_ENV_RESULT), Set(CONFIG_ENV_CELL_AXIS),
                       Set(CONFIG_ENV_OBSERVATIONAL))
    unclassified = sort!([n for n in keys(reads) if !(n in classified)])
    isempty(unclassified) ||
        @info "분류 안 된 ENV 이름 — policy.jl 의 세 목록 중 하나에 넣을 것" unclassified [
            n => unique(reads[n]) for n in unclassified]
    @test isempty(unclassified)
    @test isempty(intersect(Set(CONFIG_ENV_RESULT), Set(CONFIG_ENV_CELL_AXIS)))
    @test isempty(intersect(Set(CONFIG_ENV_RESULT), Set(CONFIG_ENV_OBSERVATIONAL)))
    @test isempty(intersect(Set(CONFIG_ENV_CELL_AXIS), Set(CONFIG_ENV_OBSERVATIONAL)))
    @test _CONFIG_ENV_EXCLUDED == union(Set(CONFIG_ENV_CELL_AXIS), Set(CONFIG_ENV_OBSERVATIONAL))
end

@testset "(1b) 스캐너가 새 읽기를 잡는다 — 주석 줄은 안 잡는다" begin
    mktempdir() do d
        f = joinpath(d, "planted.jl")
        write(f, "x = get(ENV, \"ZZ_NEW\", \"0\")\n# y = get(ENV, \"ZZ_COMMENT\", \"0\")\n" *
                 "z = ENV[\"ZZ_IDX\"]; haskey(ENV, \"ZZ_HAS\")\n")
        r = env_reads([f])
        @test Set(keys(r)) == Set(["ZZ_NEW", "ZZ_IDX", "ZZ_HAS"])
    end
end

@testset "(2) 복구 손잡이가 지문을 가른다 (리뷰어 재현의 음성 대조)" begin
    base = Dict("DS_HOTSWAP" => "1", "HOME" => "/x")
    @test cfg(merge(base, Dict("RESTAGE_ZONE_MARGIN_FRAC" => "0.5"))) !=
          cfg(merge(base, Dict("RESTAGE_ZONE_MARGIN_FRAC" => "1.5")))
    for k in ("CARRIER_RESCUE", "ZONE_RESCUE", "RELOCATE_GATE")
        @test cfg(merge(base, Dict(k => "0"))) != cfg(merge(base, Dict(k => "1")))
    end
    # 설정 안 함 과 명시 는 다른 지문이다 — 드라이버가 복구 손잡이를 **명시** export 해서
    # 모든 격자 판이 같은 쪽에 선다(기본값이 코드에서 조용히 바뀌면 코드 지문이 가른다).
    @test cfg(base) != cfg(merge(base, Dict("RESTAGE_ZONE_MARGIN_FRAC" => "0.5")))
end

@testset "(3) observational·cell_axis 이름만 바뀌면 지문이 같다" begin
    base = Dict("DS_HOTSWAP" => "1", "RESTAGE_ZONE_MARGIN_FRAC" => "0.5")
    for k in CONFIG_ENV_OBSERVATIONAL
        @test cfg(merge(base, Dict(k => "zz-observational"))) == cfg(base)
    end
    for k in CONFIG_ENV_CELL_AXIS
        @test cfg(merge(base, Dict(k => "zz-cell"))) == cfg(base)
    end
end

@testset "(4) config_env 가 run_ctx 에 평문으로 실린다 — result 전부 + 접두사 보조" begin
    fp = run_fingerprint(NONREPO; env = Dict("RESTAGE_ZONE_MARGIN_FRAC" => "1.5",
                                             "DS_HOTSWAP" => "1", "DEMO_SEED" => "3",
                                             "NAV_DEBUG" => "1", "HOME" => "/x"))
    @test Set(keys(fp)) == Set([:code_rev, :code_dirty_digest, :config_digest, :config_env])
    ce = fp.config_env
    @test ce["RESTAGE_ZONE_MARGIN_FRAC"] == "1.5"
    @test ce["ZONE_RESCUE"] == "<unset>"
    @test Set(CONFIG_ENV_RESULT) ⊆ Set(keys(ce))
    @test ce["DS_HOTSWAP"] == "1"                              # 접두사 보조 규칙(분류 밖 이름)
    @test !haskey(ce, "DEMO_SEED") && !haskey(ce, "NAV_DEBUG") && !haskey(ce, "HOME")
    # 해시는 이 dict 에서 나온다 — 평문으로 두 판이 어디서 갈렸는지 복원할 수 있다.
    @test fp.config_digest ==
          bytes2hex(SHA.sha256(join(sort!([string(k, "=", v) for (k, v) in ce]), "\n")))[1:16]
    Random.seed!(5); a = rand(); Random.seed!(5); run_fingerprint(NONREPO); b = rand()
    @test a == b                                               # 전역 RNG 불변
end

@testset "(5) Phase 3 의 새 손잡이는 result 로 등록돼 있다" begin
    for k in ("RESTAGE_NAV_BUFFER", "RESPEC_TRANSLATE_ON_INFEASIBLE")
        @test k in CONFIG_ENV_RESULT
        @test haskey(CONFIG_ENV_PINNED_DEFAULTS, k)
    end
end

@testset "(6) 드라이버가 명시 export 하는 기본값 = 소스의 리터럴 기본값" begin
    files = render_path_files()
    for (k, v) in CONFIG_ENV_PINNED_DEFAULTS
        @test k in CONFIG_ENV_RESULT
        lits = literal_defaults(files, k)
        # 아직 읽는 코드가 없는 손잡이(Phase 3 예약)는 리터럴이 없다 — 그때는 비교할 것이 없다.
        isempty(lits) && continue
        lits == Set([v]) || @info "기본값 불일치" k v lits
        @test lits == Set([v])
    end
end

end # module
