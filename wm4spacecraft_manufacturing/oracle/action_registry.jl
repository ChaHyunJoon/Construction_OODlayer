# =============================================================================
# action_registry.jl — 행동 어휘의 **Julia 쪽 유일한 로더**.
#
# 왜 있는가 (2026-08-16, Global Constraint 4).
#   단일 진실원은 `wm4spacecraft_manufacturing/action_registry.json` 이고, 파이썬은
#   `action_registry.py` 로 **파생**해서 읽는다. Julia 쪽에는 그 파생이 없어서
#   `gen_oracle_dataset.jl` 의 `const MACROS = [0,1,2,3,4,8]` 처럼 **메뉴가 리터럴로**
#   박혀 있었다. 그 리터럴이 실제로 무엇을 잃었는가:
#     · 7(RelocateBuild) 이 빠져 있었다 — zone 의 정식 개입 팔인데 라벨 대상이 아니었다.
#     · kind 별 legal 집합이라는 개념이 없어, 사건마다 굴릴 팔을 shim 의 `valid_actions`
#       관측값(fault -> [0,1])에 의존했다. 그래서 `ReformTeam(4)` 은 **시험지에 나온 적이 없다**
#       (2026-08-15 실측: relabel 365행의 support = {0,1,2,7,8}).
#
# 왜 `ACTION_NAME`/`MACRO_COST` 는 여기로 안 옮기는가.
#   그 둘은 `audit_action_vocab.py` 항목 6 이 **소스에서 정규식으로 파싱해** 레지스트리와
#   대조한다(`audit_action_vocab.py:132`). 즉 이 저장소가 고른 Julia 쪽 파생 기전이 그
#   기계 대조다 — 리터럴을 없애면 감사 대상이 사라져 게이트가 **조용히 무력해진다**.
#   여기서 파생으로 받는 것은 감사가 보지 않는 것, 즉 **메뉴**(어떤 팔을 굴릴지)뿐이다.
#
# 조용한 폴백을 두지 않는다(`action_registry.py` 와 같은 규칙): 파일이 없거나 깨졌으면
# 큰 소리로 죽는다. 옛 리터럴로 되돌아가면 "레지스트리를 배선했다고 믿고" 돌린 라벨이
# 사실은 옛 어휘로 만들어진 것이 되고, 그 사고는 로그 한 줄에 묻힌다.
# =============================================================================
module ActionRegistry

import JSON3

const PATH = get(ENV, "ACTION_REGISTRY",
                 normpath(joinpath(@__DIR__, "..", "core", "action_registry.json")))

const _RAW      = JSON3.read(read(PATH, String))
const REGISTRY  = Dict{Int,Any}(parse(Int, String(k)) => v for (k, v) in pairs(_RAW.macros))
const IDS       = sort(collect(keys(REGISTRY)))
const NAME      = Dict(i => String(REGISTRY[i].name)  for i in IDS)
const COST      = Dict(i => Float64(REGISTRY[i].cost) for i in IDS)

# ---- 어휘 도장 (2026-08-19, spec §2.4·§8; 리뷰 라운드 1 판정 G 로 정정) ---------------------
# `action_registry.py:VOCAB` 과 **같은 JSON 필드**를 읽는다. 두 언어가 같은 파일을 보므로
# 복붙 리터럴이 생기지 않는다.
#
# 판정 G: 이 값은 **오늘 참인 것**을 선언해야 한다 — dynamics_stamp() 가 hazard_enabled() 에서
# 유도되는 것과 대칭이다. 오늘 registry 는 3/5/6 이 아직 은퇴 전인 9팔이므로 "v1-9arms" 다.
# 완전한 유도 대신 **기계적 일관성 검사**를 둔다: 도장의 "<n>arms" 가 실제 registry 항목 수와
# 같은지 로드 시점에 어서션한다. **이 어서션은 태스크 5 에서 load-bearing 이다** — 3/5/6 을
# 은퇴시키고 문자열을 "v2-6arms" 로 갈아 끼우는 순간, (선언 6, 실제 6) 통과가 그 은퇴가 실제로
# 집행됐다는 증거다.
const _VOCAB_ARMS_RE = r"^v\d+-(\d+)arms$"

"""
    assert_vocab_arm_count(vocab, n_actual)

도장의 `<n>arms` 를 실제 registry 항목 수와 대조한다. 형식이 아니거나 수가 다르면 죽는다.
"""
function assert_vocab_arm_count(vocab::AbstractString, n_actual::Integer)
    m = match(_VOCAB_ARMS_RE, vocab)
    m === nothing && error("vocab 도장 형식이 아니다(v<버전>-<n>arms 꼴이어야 한다): $(vocab)")
    declared = parse(Int, m.captures[1])
    declared == n_actual || error(
        "vocab 도장이 거짓말한다 — 선언 $(declared) arms($(vocab)) vs 실제 registry $(n_actual) arms.")
    return nothing
end

const VOCAB = haskey(_RAW, :vocab) ? String(_RAW.vocab) :
    error("action_registry.json 에 'vocab' 도장이 없다: $(PATH)")
assert_vocab_arm_count(VOCAB, length(IDS))

"""
    require_vocab(obj, where)

산출물의 어휘 도장을 대조한다. 없거나 다르면 **죽는다** — 조용히 remap 하지 않는다.
remap 하면 구세대 macro 3(`ForbidZone`) 행이 4(`ReformTeam`) 로 에러 없이 재해석된다.
"""
function require_vocab(obj, where::AbstractString)
    got = try obj["vocab"] catch; nothing end
    got === nothing && error("$(where): 어휘 도장('vocab')이 없다 — 구세대 파일이다. 현행은 $(VOCAB).")
    # 문자열이 아닌 도장 값(정수 등)도 계약 메시지로 죽어야 한다 — `String(got)` 을 그냥 부르면
    # `String(::Int64)` 에 메서드가 없어 MethodError 로 죽는다(죽긴 죽지만 계약 메시지가 아니다).
    got_str = try String(got) catch; nothing end
    got_str === nothing && error(
        "$(where): 어휘 도장이 문자열이 아니다 — 구세대/손상 파일이다. 받은 값 $(repr(got)), 현행은 $(VOCAB).")
    got_str == VOCAB || error("$(where): 어휘 도장 불일치 — 파일 $(got_str) vs 현행 $(VOCAB).")
    return nothing
end

"""
    is_active(i) -> Bool

이 매크로를 지금 **제안해도 되는가**. `action_registry.py:is_active` 와 같은 규칙:
`"experimental": "<ENV 이름>"` 이 있으면 그 환경변수가 `"1"` 일 때만 활성.

⚠️ 상수가 아니라 **함수**다. 조합 팔 게이트(`DS_COMBO_ARMS`)는 `include` 시점이 아니라
호출 시점에 읽혀야 한다 — 상수로 접으면 로드 순서에 따라 플래그가 조용히 무시된다.
"""
function is_active(i::Int)
    m = REGISTRY[i]
    haskey(m, :experimental) || return true
    return get(ENV, String(m.experimental), "0") == "1"
end

"활성 매크로 id 목록 (오름차순). `action_registry.ACTIVE_MACROS` 의 Julia 대응."
active_ids() = [i for i in IDS if is_active(i)]

"""
    kind_valid(kind) -> Vector{Int}

그 사건 종류에서 **전제조건상 말이 되는** 활성 팔. `action_registry.KIND_VALID` 의 대응.

상태를 아는 호출자(shim 의 `_zone_arms_for` 처럼 결정 시점 기하를 재는 쪽)가 더 좁힐 수는
있다 — 이 표는 그 상한이다. 넓히는 방향으로는 못 간다.
"""
function kind_valid(kind)
    k = String(kind)
    return [i for i in active_ids() if k in String.(collect(REGISTRY[i].kinds))]
end

end # module
