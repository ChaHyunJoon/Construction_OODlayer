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
# 재는 명제 다섯
#   (1) nav_blocked >= 1 이면 harm === 1.0 (종단성), war === downstream/pending
#   (2) nav_blocked == 0 이면 harm === zone_overlap 그대로
#       🔴 덮임만으로 1.0 을 만들면 안 된다 — 레포 실측: root 하역목표 8/8 을
#          덮은 판이 291노드를 전부 닫고 완주했다(시간만 2.1배).
#   (3) 삼상 규약은 nav_blocked · nav_downstream 각각에 독립적으로 적용된다:
#       · nav_blocked 를 못 쟀으면(-1) 오늘 값(zone_overlap) 그대로다.
#       · nav_blocked 는 쟀는데(막힘 있음, 종단) nav_downstream 을 못 쟀으면(-1),
#         war 는 0 으로 접지 않고 zone_overlap 으로 폴백한다 — 이게 삼상 규약의 진짜
#         새 경로다(2026-08-31 fix round 1, F2). 이 폴백을 0.0 으로 접으면 다섯 testset
#         전부 초록인 채로 "못 쟀다"가 "0" 으로 새는 결함이 남는다 — 그래서 별도 어서션이
#         필요했다.
#   (4) 비-공간 사건(battery/fault)의 6값이 **바이트 단위로 안 변한다**
#   (5) 줄리아·파이썬 twin 이 `zone_terminal` 을 가르는 경계까지 포함해 일치한다
#       (nblk = -1 · 0 · 1(경계) · NBLK) — 한 점만 대조하면 파이썬이 `nblk > 1.0` 으로
#       경계를 하루 틀리게 적어도 안 잡힌다(2026-08-31 fix round 1, F3).
#   (6) 🔴 2026-09-01 (review I-4). `src/respec/llm_service/test_surro_zone_nav_descriptors.py`
#       의 `_reference_row` 는 `dspy_service._surro_row` 몸통을 손으로 베낀 사본이었다 —
#       구현을 자기 자신의 스냅샷과 비교하는 시험이라 Julia↔Python 발산을 원리적으로 못
#       본다("식을 베껴 쓴 시험"). 여기 (6)이 진짜 cross-lane 대조다: (5)와 같은 아이디엄
#       (줄리아가 venv 파이썬을 shell-out)이지만, raw dict 를 직접 짓는 대신 **프로덕션
#       경로 그대로** `MacroRequest` -> `dspy_service._surro_row` -> `descriptors_from_row`
#       를 거친 벡터를 줄리아 `event_descriptors` 와 1e-12 로 비교한다. 파이썬 쪽 시험
#       파일에는 이제 골든카피 시험이 없다 — 남은 둘(`test_negative_control_*` ·
#       `test_absent_never_becomes_measured_zero`)은 애초에 cross-lane 을 주장하지 않는
#       `_surro_row` sentinel 단위시험이라 그대로 둔다.
#
# 변이시험 (실패하는 것을 실제로 볼 것 — 아래 넷은 전부 실제로 돌려서 빨간 것을 봤다.
# 이 목록에 없는 변이 주장은 남기지 않는다: `nav_blocked` 기본값을 `-1.0`→`0.0` 으로
# 바꾸는 변이는 **아무것도 빨갛게 만들지 않는다** — `>= 1.0` 판정 아래서 nblk=-1 과
# nblk=0 은 둘 다 `zone_terminal=false` 라 바이트 단위로 같은 벡터가 나온다. 실측 후
# 이전 판의 그 주장은 뺐다(2026-08-31 fix round 1, F1).
#   · `zone_terminal` 판정에서 `nblk >= 1.0` 을 `nblk >= 0.0` 으로 바꾸면 (2)가
#     빨개진다(nav_blocked=0 인데 harm 이 1.0 이 된다).
#   · harm 의 `zone_terminal ? 1.0 :` 절을 지우면 (1)의 첫 어서션이
#     `1.0 === 0.001` 로 빨개진다 = 옛 공식을 이 fixture 에 대고 단언한 것과 같다.
#   · war 의 zone_terminal 절 전체를 `zov` 로 되돌리면(즉 `ndown / pending_total` 분기를
#     지우면) (1)의 둘째·셋째 어서션이 빨개진다(0.0024 ≉ 0.127…).
#   · war 의 zone_terminal 절에서 "못 쟀으면(-1) zov 로 폴백" 을 "0.0 으로 접는다" 로
#     바꾸면 (3)의 새 어서션이 빨개진다(0.0 !== 0.0024) — "못 쟀다"를 0 으로 접는
#     결함의 재현.
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
    # 🔴 2026-08-31 fix round 1 (F2). 여기가 진짜 새 삼상 경로다: nav_blocked 는 쟀고(종단)
    # nav_downstream 만 못 쟀을 때, war 는 0 으로 접히면 안 되고 zone_overlap 으로 폴백해야
    # 한다. 이 어서션 없이는 그 폴백을 0.0 으로 접어도 다섯 testset 전부 초록이었다(실측,
    # 아래 변이시험 참고).
    @test _desc(nav_blocked = NBLK, nav_downstream = -1)[2] === ZOV
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

@testset "(5) 파이썬 twin 과 소수점까지 같다 (zone_terminal 경계까지)" begin
    py = joinpath(REPO_ROOT, ".venv", "bin", "python")
    core = joinpath(REPO_ROOT, "wm4spacecraft_manufacturing", "core")
    if !isfile(py)
        @test_skip "venv 가 없다 — twin 대조를 건너뛴다 (초록으로 세지 말 것)"
    else
    # 🔴 2026-08-31 fix round 1 (F3). 점 하나(NBLK=3)만 대조하면 파이썬이 `nblk > 1.0` 으로
    # 경계를 하루 틀리게 적어도 안 잡힌다. `zone_terminal` 을 가르는 경계까지 훑는다:
    #   -1(못 쟀다, 비종단) · 0(막힘 없음, 비종단) · 1(경계 그 자체, >= 니까 종단) ·
    #   NBLK(참고용, 원래 fixture 값).
    cases = [(-1, -1), (0, 0), (1, 10), (NBLK, NDOWN)]
    rows = ["""{"kind":"zone","zone_overlap":$(ZOV),"severity":$(ZOV),"soc":null,
                "agent_pending":-1,"n_active":18,"spare_count":8,"closed_at_fire":$(CLOSED),
                "total_nodes":$(TOTAL),"progress":0.177,
                "zone_nav_blocked":$(nblk),"zone_nav_downstream":$(ndown)}"""
            for (nblk, ndown) in cases]
    rows_json = "[" * join(rows, ",") * "]"
    # 한 번의 파이썬 호출로 네 행을 전부 계산한다(부프로세스 반복 대신 파이썬 안에서 루프) —
    # 행마다 한 줄씩 JSON 배열을 찍는다.
    code = """
import sys, json; sys.path.insert(0, r'$(core)')
import features_agnostic as fa
for r in json.loads(r'''$(rows_json)'''):
    d = fa.descriptors_from_row(r)
    print(json.dumps([d[k] for k in fa.STATE_DESCRIPTORS]))
"""
    out = read(`$(py) -c $(code)`, String)
    lines = filter(!isempty, split(strip(out), '\n'))
    @test length(lines) == length(cases)
    for (i, (nblk, ndown)) in enumerate(cases)
        pyv = [parse(Float64, strip(x)) for x in split(strip(lines[i], ['[', ']', ' ']), ",")]
        jlv = _desc(nav_blocked = nblk, nav_downstream = ndown)
        @test length(pyv) == 6
        for k in 1:6
            @test isapprox(pyv[k], jlv[k]; atol = 1e-12)
        end
    end
    end # if isfile(py)
end

@testset "(6) _surro_row (프로덕션 row 빌더) 가 줄리아 event_descriptors 와 진짜로 일치한다" begin
    # 🔴 2026-09-01 (review I-4). raw dict 가 아니라 실제 프로덕션 경로
    # (`MacroRequest` -> `dspy_service._surro_row` -> `descriptors_from_row`) 를 거친다 --
    # 이게 골든카피 시험이 못 보던 그 자리다. nblk/ndown 이 `nothing` 이면 두 필드를
    # MacroRequest 에서 생략(JSON `null`)해 **진짜 삼상 sentinel 경로**(None -> -1.0)를
    # 태운다 -- (5)처럼 raw dict 에 리터럴 -1 을 박는 것과는 다른, 더 정직한 "못 쟀다".
    py = joinpath(REPO_ROOT, ".venv", "bin", "python")
    llm_service = joinpath(REPO_ROOT, "src", "respec", "llm_service")
    core = joinpath(REPO_ROOT, "wm4spacecraft_manufacturing", "core")
    if !isfile(py)
        @test_skip "venv 가 없다 — twin 대조를 건너뛴다 (초록으로 세지 말 것)"
    else
    cases6 = [(nothing, nothing), (0, 0), (1, 10), (NBLK, NDOWN)]
    jsonval(x) = x === nothing ? "null" : string(x)
    rows6 = ["""{"kind":"zone","severity":$(ZOV),"zone_overlap":$(ZOV),
                 "n_active":18,"spare_count":8,"closed_at_fire":$(CLOSED),
                 "total_nodes":$(TOTAL),"progress":0.177,
                 "zone_nav_blocked":$(jsonval(nblk)),"zone_nav_downstream":$(jsonval(ndown))}"""
             for (nblk, ndown) in cases6]
    rows6_json = "[" * join(rows6, ",") * "]"
    code6 = """
import sys, json
sys.path.insert(0, r'$(llm_service)')
sys.path.insert(0, r'$(core)')
import dspy_service as svc  # numpy/sklearn-before-dspy 계약은 이 모듈 안에서 이미 지켜진다 (import 만, 서버 기동 없음)
import features_agnostic as fa
for r in json.loads(r'''$(rows6_json)'''):
    req = svc.MacroRequest(**r)
    row = svc._surro_row(req, macro=1)
    d = fa.descriptors_from_row(row)
    print(json.dumps([d[k] for k in fa.STATE_DESCRIPTORS]))
"""
    out6 = read(`$(py) -c $(code6)`, String)
    lines6 = filter(!isempty, split(strip(out6), '\n'))
    @test length(lines6) == length(cases6)
    for (i, (nblk, ndown)) in enumerate(cases6)
        pyv = [parse(Float64, strip(x)) for x in split(strip(lines6[i], ['[', ']', ' ']), ",")]
        jlv = nblk === nothing ? _desc() : _desc(nav_blocked = nblk, nav_downstream = ndown)
        @test length(pyv) == 6
        for k in 1:6
            @test isapprox(pyv[k], jlv[k]; atol = 1e-12)
        end
    end
    end # if isfile(py)
end

end # module
