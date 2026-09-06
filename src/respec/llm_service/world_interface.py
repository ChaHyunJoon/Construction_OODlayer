"""생성 agent 가 코드를 쓰기 위해 읽는 세계 인터페이스. (2026-09-03, 설계 §4)

🔴 리터럴을 여기 적지 않는다. `tools/gen_world_interface.jl` 이 만든 산출물 하나를 읽고,
   그 산출물이 현행 코드와 같은지는 `test/world_interface_current.jl` 이 지킨다.
"""
import json
import os
from typing import Any, Dict, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.environ.get("WM_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "wm4spacecraft_manufacturing")
ARTIFACT = os.path.join(WM, "core", "world_interface.json")

#: 경로 -> (파일 도장, blob). 🔴 **키가 경로만이면 안 된다.** DSPy 서비스는 오래 살고,
#: 산출물의 최신성을 지키는 것은 줄리아 시험(`test/world_interface_current.jl`) 하나인데
#: **돌고 있는 서비스는 그것을 절대 안 본다.** 이 레포는 이미 그 모양으로 데었다 — 나흘 묵은
#: uvicorn 이 며칠 전에 들어온 코드를 안 가진 채 `/health` 200 을 내고 있었고, `/health` 의
#: 세대 도장 기계는 그 사고 때문에 생겼다. 낡은 스키마를 받은 모델이 쓴 코드는 기록에서
#: **모델의 실패**로 남는다. 그래서 도장으로 (mtime_ns, size) 를 같이 본다.
_CACHE: Dict[str, Any] = {}


def load_world_interface(path: Optional[str] = None) -> Dict[str, Any]:
    """🔴 조용한 폴백을 두지 않는다 — 파일이 없으면 큰 소리로 죽는다. 빈 인터페이스로
    돌면 모델은 아무것도 못 부르는 코드를 쓰고, 그 실패가 모델 탓으로 기록된다.

    🔴 `os.stat` 이 **캐시 히트에서도** 먼저 돈다. 그래야 (1) 다시 생성된 산출물을
    프로세스를 안 죽이고 읽고, (2) 지워진 산출물이 캐시에서 조용히 계속 나오지 않는다 —
    없는 파일은 히트에서도 큰 소리로 죽는 쪽이 이 파일의 규약과 같다.
    """
    p = path or ARTIFACT
    st = os.stat(p)                      # 🔴 없으면 여기서 죽는다(조용한 폴백 없음)
    stamp = (st.st_mtime_ns, st.st_size)
    hit = _CACHE.get(p)
    if hit is None or hit[0] != stamp:
        with open(p, encoding="utf-8") as fh:
            hit = (stamp, json.load(fh))
        _CACHE[p] = hit
    return hit[1]


#: 🔴 I2 (2026-09-04, 독립 검증자). 표제 이름은 **한 곳**이다. 규약 5 가 이 표제를 **이름으로**
#: 가리키므로, 표제만 바꾸고 규약 5 를 안 바꾸면 프롬프트가 **없는 표제**를 가리키게 된다 —
#: 모델에게는 "저기 적힌 목록에서 골라라" 가 가리키는 곳이 사라진 것이다. 검증자의 음성 대조가
#: 정확히 그것을 했고(표제를 `CALLABLE FUNCTIONS` 로 개명) **32 시험이 전부 초록이었다.**
#: 그래서 시험이 아니라 **구조로** 막는다: 렌더와 규약 5 가 같은 상수를 읽는다. 시험은 그
#: 위에 하나 더 얹어(`test_rule_5_names_a_heading_the_render_actually_emits`) 상수를 우회한
#: 하드코딩까지 잡는다.
_CALLABLE_HEADING = "FUNCTIONS YOU CAN CALL NOW"

_RULES = (
    "HOW YOUR CODE IS CALLED -- these are hard requirements, not style:\n"
    "  1. Exactly one top-level definition: `function NAME!(env; k1=<default>, ...) ... end`.\n"
    "     `env` is the ONLY positional argument. Every other argument is a keyword and MUST\n"
    "     have a default. The harness builds `env` and passes your declared parameters as\n"
    "     keywords; any other shape cannot be called and is rejected before it runs.\n"
    # 🔴 2026-09-04, 유료 런 3. 규약 6 을 더한 직후 body 가 `function T!(env;
    #    affected_robot, affected_tasks, alternative_robots)` 로 나와
    #    `reject:impl_keyword_needs_a_default:affected_robot` 에서 죽었다 — L1 이 무너졌다.
    #    이것은 모델의 실수가 아니라 **우리가 준 두 규약의 모순**이다: 규약 6 이 "id 는
    #    env 에서 얻은 객체" 라고 하는데 규약 1 은 "모든 키워드에 기본값" 을 요구하고,
    #    기본값은 **리터럴**이라 env 객체가 될 수 없다. 모델은 둘 중 하나를 버려야 했고
    #    방금 배운 쪽을 지켰다. 화해시키는 자리는 **의무가 적힌 곳**(규약 1)이다 —
    #    모델은 위에서 아래로 읽으므로 압력이 생기기 **전에** 해법이 도착해야 한다.
    #    🔴 의무는 안 약화시킨다: `check_impl_conventions`
    #    (`minted_registration.jl`, 모든 kw 가 `Expr(:kw)` 여야 한다)가 그대로 집행한다.
    #    그리고 이 패턴은 편의가 아니라 **유일한 길**이다: `bind_primitive_args`
    #    (`minted_tool.jl`)가 kw 를 `ctx.params` 의 JSON 값에서 만들고
    #    `_param_type_reject` 가 JSON 타입을 강제하므로 **id 객체는 그 채널로 못 온다.**
    "     A world object cannot be a literal, so a keyword that carries one defaults to\n"
    "     `nothing` and the body resolves it from env first -- literally\n"
    "     `function f!(env; affected_robot = nothing)`, then\n"
    "     `affected_robot === nothing && (affected_robot = first(keys(env.agent_policies)))`.\n"
    "     Keyword values arrive as JSON, so an id object can ONLY reach the body that way;\n"
    "     dropping the default is rejected before the code runs.\n"
    "  2. The name must end with `!` and must NOT already exist in the module.\n"
    "  3. Return a value the harness can read a status from: either a Symbol, or a NamedTuple\n"
    "     with a `status::Symbol` field. That status is how the record says what happened.\n"
    "     Write that NamedTuple with the semicolon form. The last line of your body should\n"
    "     read literally `return (; status = :success)`. Do NOT write\n"
    "     `NamedTuple{(:status,)}(:success)` -- that is not valid Julia and throws\n"
    "     `MethodError: no method matching length(::Symbol)`, which kills a body that had\n"
    "     already done all of its work correctly.\n"
    # 🔴 2026-09-05, 유료 런 16. 이 규약이 가르친 `:success` 를 모델이 **부른 함수의**
    #    상태 어휘로 옮겨 썼다: `translate_whole_build!(...).status == :success || error(...)`.
    #    그 함수엔 `:success` 경로가 없어서 빌드를 실제로 옮겨 놓고도 무조건 던졌다.
    #    규약 자체는 옳다 — 갈린 것은 **누구의 status 냐**이고, 그것을 여기서 못박는다.
    "     `:success` is YOUR return contract, not a vocabulary the functions you call share.\n"
    "     A function you call reports its own symbols; where they are known they are printed\n"
    "     on its line as `status seen in source:`. Never assume a callee returns `:success`,\n"
    "     and where its symbols are not printed, branch on what the call gives back rather\n"
    "     than on a symbol you guessed.\n"
    "  4. Exactly one TOP-LEVEL definition -- no other top-level `const`, macros, or\n"
    "     helper functions. Helper closures defined INSIDE your function body are fine.\n"
    '  5. Prefer CALLING the functions listed under "' + _CALLABLE_HEADING + '" over\n'
    "     writing struct fields by hand. A function call carries the module's own\n"
    "     invariants; a raw field write does not. Write a field directly only when no\n"
    "     listed function produces the required effect, and say why in a comment.\n"
    # 🔴 2026-09-04, 유료 런 2 의 사인. 이것이 **두 런 연속 identifier 환각**이다
    #    (런 1 은 필드 이름을, 런 2 는 키 타입을 지어냈다). 그래서 `battery_report` 아래에
    #    붙이는 국소 주석이 아니라 **일반 규약**으로 적는다 — `Dict{AbstractID, ...}` 필드가
    #    WORLD TYPES 에만 일곱 개고, 같은 착각이 그 전부에서 가능하다.
    #    실제 사인: 모델이 `soc[robot_id]` 를 `robot_id="R1"` 로 쳤고 `soc` 는
    #    `Dict{Any,Float64}` 인데 키가 `BotID` **객체**였다 → `KeyError: key "R1" not found`.
    #    🔴 2026-09-04 정정. 이 자리에 "`returns` 는 `Base.return_types` 에서 기계로
    #    유도되므로 `Any` 를 더 좁게 적을 길이 **산출물 쪽에 없다**" 고 적혀 있었다. 틀렸다 —
    #    길은 산출물이 아니라 **선언**에 있었다. `Any` 의 출처는 `src/navigator/battery.jl` 의
    #    `BatteryFleet.soc::Dict{Any,Float64}` 한 줄이었고(주석은 이미 "RobotID" 라고 적고
    #    있었다), 실측한 참값 `RobotID`(= `BotID{DeliveryBot}`)로 좁히자 `_returns_string` 이
    #    산문 없이 스스로 진실을 광고했다:
    #    `soc::Dict{ConstructionBots.BotID{ConstructionBots.DeliveryBot}, Float64}`.
    #    그러니 규약 6 은 이제 `soc` 를 **갚는 것이 아니라** 남은 id-키 사전들
    #    (`Dict{AbstractID, ...}` 필드들)을 덮는다.
    # 🔴 라운드 5 (2026-09-04). 여기 `A `Dict{Any, ...}` handed back by an accessor is
    #    keyed by those same id objects` 한 문장이 더 있었다. **걷어냈다** — 타입이 좁혀진
    #    뒤로 렌더 본문의 `Dict{Any` 는 **0건**이라 그 문장은 지시대상이 없는 인용이 됐다.
    #    (I2 와 같은 결함 부류다: 규약이 이름으로 가리킨 것이 사라졌는데 아무도 안 본다.)
    #    ⟹ 규약부는 **구체 타입을 인용하지 않는다.** 기계가 광고하는 것은 기계에 맡기고,
    #    시그니처가 못 나르는 것만 산문으로 남긴다: "id 는 객체다 · env 에서 얻어라",
    #    그리고 지어낸 이름의 결과(`KeyError`) — 그 둘은 어떤 타입에도 안 적힌다.
    "  6. Identifiers in this world are OBJECTS, never strings. There is no `\"R1\"`-style\n"
    "     display name anywhere: get an id out of env (e.g. `keys(env.agent_policies)`) and\n"
    "     pass that object -- a name you invented throws `KeyError`. A keyword that carries\n"
    "     an id defaults to `nothing` -- see rule 1.\n"
    # 🔴 2026-09-05, 유료 런 19·20·22. 세 판이 같은 문장으로 죽었다:
    #    `Vector{Float64}(::TransformNode)` · `Vector{Float64}(::AffineMap)` ×2. 런 22 는
    #    좌표를 꺼내는 길을 **맞게** 골라 놓고(그 길은 (나-1)에 광고돼 있다) 그 결과를
    #    무타입 인자에 넘겼다 — 그 자리엔 지킬 계약이 광고돼 있지 않았다.
    #    규약 6 과 같은 부류다: 시그니처가 못 나르는 것만 산문으로 남기고, 구체 타입은
    #    인용하지 않는다(기계가 `coerced in source:` 로 스스로 광고한다).
    "  7. An argument written WITHOUT a type in a signature promises you nothing: nothing\n"
    "     checks your value on the way in, so it reaches the callee's own arithmetic as it\n"
    "     is. Where that callee's source converts the argument itself, the conversion is\n"
    "     printed on its line as `coerced in source:` -- pass a value that conversion\n"
    "     accepts. Where no conversion is printed the required shape is not advertised at\n"
    "     all; prefer a listed function whose argument carries a type.\n"
)


def _method_line(m) -> str:
    """`- <이름> (…)      missing: <타입>` — 설계 §6.2 의 모양.

    🔴 `missing` 은 **두 표제 모두**에 붙는다. 둘째 표제(못 부른다)에서는 스펙이 요구하는
    그대로이고, 첫째 표제에서는 리뷰 I1 을 갚는다: "every argument is obtainable from env"
    아래에 경로 없는 인자를 가진 항목이 32건 앉아 있었고, 모델은 `apply_cmd!(node, twist,
    env)` 를 쓰려다 `node` 의 출처를 못 찾고 다시 placeholder 를 쓴다 — 그것이 설계 §1.2,
    즉 D11 이 없애려던 실패 그 자체이고, 그 실패는 기록에 **모델의 실패**로 남는다.

    🔴 `returns` 는 **있을 때만** 붙는다 (2026-09-05, 판정 R-RET2). 생성기의 삼상 판정에서
    필드의 **부재**가 "기계가 말할 수 없었다" 이고, `"Any"` 라는 **값**이 "세계가 아무것도
    약속하지 않는다" 다 — 둘은 다른 사실이므로 렌더도 안 섞는다(전자는 화살표가 없고,
    후자는 `->  Any` 로 나온다). 빈 문자열을 화살표 뒤에 적으면 모델이 "반환이 없다" 로
    읽으므로, 없을 때는 화살표째 없앤다.
    ⚠️ 화살표 모양(`  ->  `)은 앰비언트 블록의 선례를 그대로 쓴다 — 같은 사실을 두 모양으로
    적으면 모델이 둘을 다른 것으로 읽는다.

    판정도 문구도 생성기(`_missing_types` · `_method_returns`)가 정한다 — 여기서 다시
    계산하지 않는다.
    """
    line = "- %s %s" % (m["name"], m["signature"])
    ret = m.get("returns")
    if ret:
        line += "  ->  %s" % ret
    # 🔴 2026-09-05, 유료 런 19. `active_restriction_zones()` 를 `collect` 하면 `Pair` 가
    #    나오는데 광고된 타입(`Base.Generator{…}`)은 그것을 한 글자도 안 말했고, body 가
    #    `get_center(::Pair{Symbol, Ball2})` 로 죽었다. 순회 결과는 **타입과 다른 사실**이다.
    el = m.get("element_type")
    if el:
        line += "      yields: %s" % el
    # 🔴 2026-09-05, 유료 런 16. 그 body 는 `translate_whole_build!` 의 반환을
    #    `.status == :success` 로 검사했는데 그 함수엔 `:success` 경로가 **없다** — 빌드를
    #    실제로 옮겨 놓고도 무조건 던졌다. 유도가 맨 `NamedTuple` 로 넓어져 어휘가 안 보였다.
    # ⚠️ 문구가 "one of" 가 **아니다.** 생성기의 판정은 소스에 대한 **구문적 상계**라
    #    도달 불가한 갈래를 포함할 수 있고 다른 함수가 만든 상태는 못 본다
    #    (근거 정본은 `_status_symbols` 의 docstring). 모델이 이것을 폐집합으로 읽고
    #    나머지를 오류로 처리하면 우리가 안 잰 것을 잰 것처럼 말하게 된다.
    ss = m.get("status_symbols") or []
    if ss:
        line += "      status seen in source: %s" % " | ".join(":" + x for x in ss)
    # 🔴 2026-09-05, 유료 런 19·20·22. 세 판이 같은 문장으로 죽었다 —
    #    `Vector{Float64}(::TransformNode)` · `Vector{Float64}(::AffineMap)` ×2. 런 22 의 body 는
    #    광고된 `global_transform(goal_config(node))` 를 **맞게** 부른 뒤 그 AffineMap 을 무타입
    #    인자 `goal` 에 넘겼다: 시그니처가 그 자리에서 아무 모양도 약속하지 않기 때문이다.
    #    변환은 callee 의 소스에 이미 적혀 있고, 생성기가 그것을 그대로 옮긴다.
    # ⚠️ 문구가 "must be" 가 **아니다.** 생성기의 판정은 구문적 상계라 다른 함수가 대신
    #    변환해 주는 경우를 못 본다(근거 정본은 `_arg_coercions` 의 docstring).
    ac = m.get("arg_coercions") or []
    if ac:
        line += "      coerced in source: %s" % " ; ".join(ac)
    # 🔴 2026-09-05, 유료 런 23·26. run23 의 body 가 자기 주석에 원인을 적었다:
    #    "No query returns the blocked schedule-node objects directly" — 그래서 탐지를 손수
    #    짰고 빈손으로 끝났다. 그 질의는 **있었다**(`zone_blockage(...).blocked`). 없던 것은
    #    질의가 아니라 광고다: 유도가 맨 `NamedTuple` 로 넓어져 필드가 한 글자도 안 실렸다.
    # ⚠️ `status seen in source:` 와 같은 규약 — **갈래의 합집합**이지 한 호출이 전부를
    #    돌려준다는 뜻이 아니다. 그래서 "fields are" 가 아니라 `fields seen in source` 다.
    # 🔴 2026-09-05, 난수 존 시드 1. body 가 `zone_blockage(...).n_nav_blocked` 를 읽고
    #    던졌다 — 그 필드는 `zone_diagnosis` 것이다. 그런데 `seen` 은 삼상 규율상 "본 것"이라
    #    **목록에 없는 이름은 "없다" 가 아니라 "모른다"** 로 읽힌다. 모델의 읽기가 옳았다.
    #    수확이 모든 반환 경로를 덮은 자리(`returned_fields_complete`)에서는 그렇게 말해야
    #    부재가 판단 근거가 된다. 그 키는 **참일 때만** 생기므로 else 는 옛 문구 그대로다
    #    ("불완전하다" 가 아니라 "완전한지 못 말한다" 이고, 둘은 같은 문구를 쓴다).
    rf = m.get("returned_fields") or []
    if rf:
        if m.get("returned_fields_complete"):
            line += ("      fields (complete -- every return path was read; a name not "
                     "listed here is not a field of this call): %s" % " | ".join(rf))
        else:
            line += "      fields seen in source: %s" % " | ".join(rf)
    # 🔴 2026-09-05, 유료 런 27·28·29. 바로 위 개입이 `zone_blockage(...).blocked` 를
    #    광고하자 **세 판 다 그것을 찾아 썼다** — 그리고 세 판 다 그것을 *id 의 목록*으로
    #    읽어 매칭이 전부 빗나갔다(원소는 `(vtx, id, kind, status)` 다). 필드 이름만 대고
    #    안의 모양을 안 대면, 모델은 손을 뻗은 바로 그 자리에서 넘어진다.
    # ⚠️ `fields seen in source:` 와 같은 규약 — 갈래의 합집합이지 폐집합이 아니다.
    fe = m.get("field_element_fields") or []
    if fe:
        line += "      elements seen in source: %s" % " ; ".join(fe)
    miss = m.get("missing") or []
    if miss:
        line += "      missing: %s" % ", ".join(miss)
    return line


def build_world_interface_block(blob=None) -> str:
    b = blob if blob is not None else load_world_interface()
    parts = [_RULES, "",
             "WORLD TYPES (what the world is made of; you may read these, and write"
             " them only as a last resort -- see rule 5):"]
    for t in b["types"]:
        parts.append("- %s" % t["name"])
        for f in t.get("fields") or []:
            parts.append("    %s :: %s" % (f["name"], f["type"]))
        if t.get("subtypes"):
            parts.append("    (abstract; one of: %s)" % ", ".join(t["subtypes"]))
    amb = b.get("ambient") or []
    if amb:
        parts += ["", "AMBIENT WORLD STATE (not on env; read it with the accessor shown):"]
        for a in amb:
            # 🔴 `.get`. 무조건 첨자는 Task 2 리뷰가 Critical 로 잡은 `t["fields"]` KeyError
            #    와 같은 모양이다 — 생성기가 유일한 생산자라 오늘은 잠재적이지만, 그 모양을
            #    한 태스크 만에 다시 열지 않는다(리뷰 m3).
            parts.append("- %s" % a.get("name", ""))
            parts.append("    %s  ->  %s" % (a.get("accessor", ""), a.get("returns", "")))
            # 🔴 I4. 전제조건 없는 광고는 모델이 못 지킨 것을 **모델의 실패**로 기록되게 한다.
            if a.get("precondition"):
                parts.append("    valid %s" % a["precondition"])
    # 🔴 D11. 평평한 한 목록은 "선택자가 없다" 로 읽혔다(설계 §1.2) — 모델이 placeholder 를
    #    썼다. 가르는 것은 **렌더**이지 모집단이 아니다: 두 표제 다 같은 `b["methods"]` 에서
    #    나오고, D6 이 감춘 셋은 애초에 산출물에 없다.
    now = [m for m in b["methods"] if m.get("callable")]
    later = [m for m in b["methods"] if not m.get("callable")]
    parts += ["", "%s (every argument is obtainable from env):" % _CALLABLE_HEADING]
    for m in now:
        parts.append(_method_line(m))
        for p in m.get("argpaths") or []:
            parts.append("      %s" % p)
    parts += ["", "FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET:"]
    for m in later:
        parts.append(_method_line(m))
    return "\n".join(parts)
