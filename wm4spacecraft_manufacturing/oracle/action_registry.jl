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
# 완전한 유도 대신 **기계적 일관성 검사**를 둔다: 도장의 "<n>arms" 가 **은퇴 표식이 없는**
# registry 항목 수와 같은지 로드 시점에 어서션한다.
#
# 재리뷰 정정(라운드 2): 처음엔 "실제 registry 항목 수" 를 `length(IDS)`(= 전체 JSON 엔트리
# 수)로 재고 커밋했는데 이건 **정반대로 작동한다.** 태스크 5 의 은퇴(`task-5-brief.md` Step 3)
# 는 3/5/6 엔트리를 **지우지 않는다** — "retired" 표식만 달고 이름·비용은 그대로 둔다. 그래서
# `length(IDS)` 는 은퇴 뒤에도 **영원히 9** 다: 은퇴를 집행하고 도장을 안 바꾼 실수는
# (선언 9, 실제 9)로 통과해 못 잡고, 반대로 은퇴를 집행하고 도장을 옳게 "v2-6arms" 로 바꾼
# 정상 변경은 (선언 6, 실제 9)로 **죽어서 막아버린다** — 재리뷰가 스크래치 registry 로 두
# 방향 다 실측했다. 옳은 `n_actual` 은 **"retired" 표식이 없는 엔트리 수**(`n_non_retired`)
# 다: 오늘은 은퇴 표식이 0개라 9 그대로고, 태스크 5 가 3/5/6 을 은퇴시키면 6 으로 실제로 준다.
#
# **이 어서션은 태스크 5 에서 load-bearing 이다**: 3/5/6 을 은퇴(retired 표식 추가)시키고
# 문자열을 "v2-6arms" 로 갈아 끼우는 순간, `n_non_retired` 가 6 을 세어 (선언 6, 실제 6)로
# 통과하는 것이 곧 은퇴가 실제로 집행됐다는 증거다. 문자열만 바꾸고 은퇴 표식을 안 달면
# (또는 그 반대) 여기서 죽는다.
const _VOCAB_ARMS_RE = r"^v\d+-(\d+)arms$"

"""
    isretired(i, m) -> Bool

이 매크로가 은퇴했는가 — **엄격** 판정(2026-08-19 판정 K). `haskey(m,:retired) &&
Bool(m.retired)` 는 `m.retired` 가 문자열이면 `Bool("문자열")` 에서 `MethodError` 로 죽는다
(2026-08-19 컨트롤러 재리뷰 실측) — 이 도장이 막으려는 바로 그 실패("두 언어가 갈린다")가
도장 자신에게서 나는 것이다. 그래서 "retired" 는 **기계 술어**(반드시 JSON boolean)이고
사유 산문은 "retired_reason" 으로 분리했다. 규칙(양 언어 동일): 부재 → false · boolean →
그 값 · **그 밖의 무엇이든(문자열·수·null·객체) → 매크로 id 를 밝히며 에러.** 강제변환·추측 금지.
"""
function isretired(i::Int, m)::Bool
    haskey(m, :retired) || return false
    v = m.retired
    v isa Bool && return v
    error("macro $(i): 'retired' 값이 boolean 이 아니다($(repr(v))) — remap 하지 않는다" *
          "(그러면 구세대 macro 3 행이 4 로 에러 없이 재해석된다). 명시적으로 true/false 로 고칠 것.")
end

"""
    n_non_retired(registry) -> Int

`registry`(id => JSON3.Object, 선택적 `retired` 필드) 에서 은퇴 표식이 없는 엔트리 수.
은퇴는 엔트리를 지우지 않고 표식만 다는 영구적 성질이다(레지스트리 자체의 속성) — 실험
팔 게이트(`experimental`/`is_active`)와는 다른 축이다: 그건 ENV 로 켜고 끄는 **런타임**
성질이라 도장(정적 provenance)에 넣으면 `DS_COMBO_ARMS=1` 을 export 하는 순간 도장의
유효성이 흔들린다 — 그래서 여기서는 쓰지 않는다.
"""
function n_non_retired(registry)
    return count(kv -> !isretired(kv[1], kv[2]), pairs(registry))
end

"""
    assert_vocab_arm_count(vocab, n_actual)

도장의 `<n>arms` 를 `n_actual`(호출자가 `n_non_retired(REGISTRY)` 로 넘긴다)과 대조한다.
형식이 아니거나 수가 다르면 죽는다.
"""
function assert_vocab_arm_count(vocab::AbstractString, n_actual::Integer)
    m = match(_VOCAB_ARMS_RE, vocab)
    m === nothing && error("vocab 도장 형식이 아니다(v<버전>-<n>arms 꼴이어야 한다): $(vocab)")
    declared = parse(Int, m.captures[1])
    declared == n_actual || error(
        "vocab 도장이 거짓말한다 — 선언 $(declared) arms($(vocab)) vs 실제(은퇴 제외) registry $(n_actual) arms.")
    return nothing
end

const VOCAB = haskey(_RAW, :vocab) ? String(_RAW.vocab) :
    error("action_registry.json 에 'vocab' 도장이 없다: $(PATH)")
assert_vocab_arm_count(VOCAB, n_non_retired(REGISTRY))

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

"""은퇴한 팔 (spec §2). 은퇴는 실험 게이트를 이긴다 — DS_COMBO_ARMS=1 으로도 안 살아난다.
id => retired_reason 산문(테스트/디버깅용). 이름표(NAME)와 비용(COST)은 지우지 않는다 —
지우면 구세대 행을 읽을 때 KeyError 로 죽는데(2026-08-02 사고), 원하는 실패 모양은
'도장 불일치로 죽는 것'이다."""
const RETIRED = Dict(i => String(get(REGISTRY[i], :retired_reason, "")) for i in IDS if isretired(i, REGISTRY[i]))

"""
    is_active(i) -> Bool

이 매크로를 지금 **제안해도 되는가**. `action_registry.py:is_active` 와 같은 규칙:
`"experimental": "<ENV 이름>"` 이 있으면 그 환경변수가 `"1"` 일 때만 활성.

⚠️ 상수가 아니라 **함수**다. 조합 팔 게이트(`DS_COMBO_ARMS`)는 `include` 시점이 아니라
호출 시점에 읽혀야 한다 — 상수로 접으면 로드 순서에 따라 플래그가 조용히 무시된다.
"""
function is_active(i::Int)
    # 리뷰 라운드 2 Minor 수정: registry 밖 id(-1·9·10 등, DS_EP_MACROS 로 손으로 넣을 수 있다)는
    # 예전엔 `REGISTRY[i]` 에서 그냥 `KeyError` 로 죽었다. "제안 가능한가"라는 질문에 대한 답은
    # false 여야 한다(그런 팔은 애초에 없다) — 계약 없는 크래시가 아니라.
    haskey(REGISTRY, i) || return false
    m = REGISTRY[i]
    isretired(i, m) && return false      # 은퇴가 실험 게이트를 이긴다
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
