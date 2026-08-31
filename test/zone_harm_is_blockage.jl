# =============================================================================
# **공간 사건의 harm 은 덮임이 아니라 막힘에서 나온다.** (2026-08-31, S1/T1)
#
# 왜 이 파일이 필요한가
# ----------------------
# 2026-08-30 의 라이브 zone 판에서 프롬프트가 자기모순이었다: 기하 블록은
# "nav goal 3개가 막혀 251노드 중 32개가 얼어붙었다"고 적는데 서술자는
# harm=0.00 · work_at_risk=0.00 이었고, 모델의 reason 이 그 0 을 인용하며
# NOOP 을 골랐다(115/115 행이 expressible=True).
# 원인: `_zone_overlap` 은 **staging 원 면적비**인데 실제 피해 기전은
# **nav goal 도착 허용반경이 배제원 안에 들어간 것**이다. 기하가 다르다.
#
# 재는 명제 넷
#   (1) nav_blocked >= 1 이면 harm === 1.0 (종단성), war === downstream/pending
#   (2) nav_blocked == 0 이면 harm === zone_overlap 그대로
#       🔴 덮임만으로 1.0 을 만들면 안 된다 — 레포 실측: root 하역목표 8/8 을
#          덮은 판이 291노드를 전부 닫고 완주했다(시간만 2.1배).
#   (3) nav_blocked == -1(못 쟀다)이면 오늘 값 그대로 (삼상 규약)
#   (4) 비-공간 사건(battery/fault)의 6값이 **바이트 단위로 안 변한다**
#
# 변이시험 (실패하는 것을 실제로 볼 것)
#   · `zone_terminal` 판정에서 `nblk >= 1.0` 을 `nblk >= 0.0` 으로 바꾸면 (2)가
#     빨개진다(nav_blocked=0 인데 harm 이 1.0 이 된다).
#   · harm 의 `zone_terminal ? 1.0 :` 절을 지우면 (1)의 첫 어서션이
#     `1.0 === 0.001` 로 빨개진다 = 옛 공식을 이 fixture 에 대고 단언한 것과 같다.
#   · war 의 `ndown / pending_total` 을 `zov` 로 되돌리면 (1)의 둘째가 빨개진다.
#   · `nav_blocked` 기본값을 `-1.0` 에서 `0.0` 으로 바꾸면 (3)이 빨개진다.
#
# 실행: julia +lts --project=. test/zone_harm_is_blockage.jl
# =============================================================================
module ZoneHarmIsBlockage

using Test
using ConstructionBots
const CB = ConstructionBots

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

# 2026-08-30 라이브 판의 실제 값이다(streams/tractor__zone_minted.jsonl 에서 읽음).
const ZOV      = 0.002356843670973429
const NBLK     = 3
const NDOWN    = 32
const TOTAL    = 305
const CLOSED   = 54          # pending_total = 305 - 54 = 251 (그 판의 unfinished_total)
const PENDING  = TOTAL - CLOSED

_desc(; kw...) = CB.event_descriptors(; zone_overlap = ZOV, severity = ZOV,
                                        n_active = 18.0, spare_count = 8.0,
                                        closed_at_fire = CLOSED, total_nodes = TOTAL,
                                        progress = 0.177, kw...)

@testset "(1) 막힘이 있으면 harm 은 1.0 이고 war 는 얼어붙은 비율이다" begin
    d = _desc(nav_blocked = NBLK, nav_downstream = NDOWN)
    @test d[1] === 1.0
    @test d[2] ≈ NDOWN / PENDING
    @test d[2] > 0.12 && d[2] < 0.13      # 32/251 = 0.1275…
end

@testset "(2) 막힘이 0 이면 덮임만으로 1.0 을 만들지 않는다" begin
    d = _desc(nav_blocked = 0, nav_downstream = 0)
    @test d[1] === ZOV
    @test d[2] === ZOV
    # 큰 덮임에서도 마찬가지다 — 레포 실측(root 8/8 덮임 판)이 완주였다.
    big = CB.event_descriptors(zone_overlap = 0.8, severity = 0.8, n_active = 18.0,
                               spare_count = 8.0, closed_at_fire = CLOSED,
                               total_nodes = TOTAL, progress = 0.177,
                               nav_blocked = 0, nav_downstream = 0)
    @test big[1] === 0.8
end

@testset "(3) 못 쟀으면 오늘 값 그대로다 (삼상 규약)" begin
    unmeasured = _desc()                                  # 기본값 -1.0
    explicit   = _desc(nav_blocked = -1, nav_downstream = -1)
    legacy     = CB.event_descriptors(zone_overlap = ZOV, severity = ZOV, n_active = 18.0,
                                      spare_count = 8.0, closed_at_fire = CLOSED,
                                      total_nodes = TOTAL, progress = 0.177)
    @test unmeasured == explicit == legacy
    @test unmeasured[1] === ZOV
end

@testset "(4) 비-공간 사건은 바이트 단위로 안 변한다" begin
    # battery: soc 가 유한하므로 has_soc 분기. zone_overlap 은 -1(해당 없음).
    bat = CB.event_descriptors(soc = 0.55, agent_pending = 1.0, n_active = 17.0,
                               spare_count = 8.0, closed_at_fire = 245, total_nodes = 305,
                               progress = 0.803)
    @test bat[1] ≈ 0.45
    @test bat[3] ≈ 0.45
    # nav_* 를 줘도 비-공간 사건에서는 무시된다.
    @test bat == CB.event_descriptors(soc = 0.55, agent_pending = 1.0, n_active = 17.0,
                                      spare_count = 8.0, closed_at_fire = 245,
                                      total_nodes = 305, progress = 0.803,
                                      nav_blocked = 9, nav_downstream = 99)
end

@testset "(5) 파이썬 twin 과 소수점까지 같다" begin
    py = joinpath(REPO_ROOT, ".venv", "bin", "python")
    core = joinpath(REPO_ROOT, "wm4spacecraft_manufacturing", "core")
    if !isfile(py)
        @test_skip "venv 가 없다 — twin 대조를 건너뛴다 (초록으로 세지 말 것)"
    else
    row = """{"kind":"zone","zone_overlap":$(ZOV),"severity":$(ZOV),"soc":null,
              "agent_pending":-1,"n_active":18,"spare_count":8,"closed_at_fire":$(CLOSED),
              "total_nodes":$(TOTAL),"progress":0.177,
              "zone_nav_blocked":$(NBLK),"zone_nav_downstream":$(NDOWN)}"""
    code = """
import sys, json; sys.path.insert(0, r'$(core)')
import features_agnostic as fa
d = fa.descriptors_from_row(json.loads(r'''$(row)'''))
print(json.dumps([d[k] for k in fa.STATE_DESCRIPTORS]))
"""
    out = read(`$(py) -c $(code)`, String)
    pyv = [parse(Float64, strip(x)) for x in split(strip(out, ['[', ']', '\n', ' ']), ",")]
    jlv = _desc(nav_blocked = NBLK, nav_downstream = NDOWN)
    @test length(pyv) == 6
    for i in 1:6
        @test isapprox(pyv[i], jlv[i]; atol = 1e-12)
    end
    end # if isfile(py)
end

end # module
