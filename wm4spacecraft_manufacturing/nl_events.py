#!/usr/bin/env python
"""
nl_events.py -- the NATURAL-LANGUAGE observation channel of an OOD event.

WHY THIS FILE EXISTS
====================
The system under test is meant to work like this:

    a genuinely NEW kind of OOD  ->  an LLM READS THE SENTENCE and picks a response  (adaptive)
    an OOD kind already seen     ->  the trained surrogate answers in ~0.1 ms        (cheap)

Measuring the first line honestly requires the LLM's input to be the SENTENCE, not the parsed
record. Handing it `kind=battery, soc=0.55, spare_count=8` is circular: those fields exist only
because the event was already recognised as one of the three known kinds. A truly novel event has
no `soc` and no `zone_overlap` column to put anything in.

The sentence has always existed -- the injectors build it and log it into `OOD_TRUTH_LOG` as the
`nl` half of the (nl, truth) pair (ConstructionBots.jl/src/navigator/ood_truth.jl). It was simply
never written to the dump. `oracle/gen_oracle_dataset.jl` now writes it (`nl`, `nl_source`), so
every dump generated from 2026-07-28 on carries the real sentence.

THE EXISTING 60-INSTANCE DUMP HAS NO `nl` FIELD, and regenerating it costs ~81 s per label x 300
labels. So this module also RECONSTRUCTS the sentence from the recorded numbers, using the exact
templates the injectors emit, and marks it `nl_source="synthesized"`. Which is honest only if the
distinction is carried through every downstream table -- so every consumer here reports the mix.

    captured     the sentence the controller actually saw. Evidence-grade.
    synthesized  rebuilt from the dump's numeric fields with the injector's own wording. Correct
                 wording and correct severity branch, but the robot id and the zone coordinates
                 were not stored, so those are anonymised. Use for pipeline development and for a
                 first read on the LLM arm; regenerate before quoting a headline number.

THE CEILING NOBODY SHOULD MISS
==============================
Two OOD variants in this dataset are DELIBERATELY given identical sentences:

    fault    (agent_pending > 0, intervening pays)   |  faultidle (agent_pending = 0, NOOP is right)
    zoneblk  (covers pending staging, ForbidZone)    |  zoneharm  (covers open floor, NOOP is right)

`gen_oracle_dataset.jl` says so in as many words ("the NL is identical", "same event, same NL").
That was a design choice to stop a model from taking the event NAME as a shortcut -- and it means a
producer given ONLY the sentence is INFORMATION-LIMITED here: it cannot tell the harmful variant
from the harmless one, no matter how good it is. `nl_partition_ceiling()` below computes exactly
how good an NL-only producer could possibly be, so the LLM arm is scored against its own ceiling
instead of being blamed for a limit the data imposes.

The fix is not to hide this: it is to give the LLM the sentence PLUS the kind-agnostic measured
state (harm / work_at_risk / ... from features_agnostic.py), which is what a deployed system would
have and which contains no closed-vocabulary class name. That is the `nl+state` arm.

────────────────────────────────────────────────────────────────────────────────────────────
[한국어 설명]
이 파일이 하는 일: OOD 사건의 "자연어 관찰 문장"을 다룬다.

왜 필요한가: 선생님 설계("처음 보는 OOD 는 LLM 이 자연어로 해석, 아는 OOD 는 surrogate 가 싸게")를
정직하게 재려면 LLM 의 입력이 **문장**이어야 한다. kind=battery, soc=0.55 같은 정제된 필드를 주면
순환논리다 -- 그 필드가 있다는 것 자체가 "이미 아는 종류로 파싱됐다"는 뜻이기 때문.

문장은 원래부터 주입 시점에 만들어져 OOD_TRUTH_LOG 에 있었지만 덤프에 안 실렸다. 이제 라벨러가
싣는다. 기존 60인스턴스 덤프에는 없으므로, 여기서 같은 템플릿으로 복원하고 "synthesized" 로 표시한다.

반드시 알아야 할 한계(천장): 이 데이터셋은 일부러 fault/faultidle, zoneblk/zoneharm 의 문장을
**똑같이** 만든다(모델이 사건 이름을 지름길로 쓰지 못하게 하려고). 그래서 문장만 주면 해로운 변종과
무해한 변종을 원리적으로 구분할 수 없다. nl_partition_ceiling() 이 그 상한을 계산해 준다.
해법은 문장을 숨기는 게 아니라, 문장 + (종류 이름이 아닌) 물리 서술자를 함께 주는 것 = `nl+state` arm.

[문법 참고]
  - hashlib.md5(...).hexdigest() : 문자열을 고정 길이 지문으로. 여기선 "재현 가능한 가짜 로봇번호" 용도.
  - dict.get(k, default)         : 키가 없으면 default.
  - float("nan") != float("nan") : NaN 은 자기 자신과도 다르다 -> NaN 판정 관용구.
────────────────────────────────────────────────────────────────────────────────────────────
"""
import hashlib
import math
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

# ood_truth.jl 의 REPLACE_SOC_THRESHOLD 와 같은 값이어야 한다. battery 사건의 문장이 이 경계에서
# "치명적(고장 취급)" <-> "열화(먼 거리 피하기)" 로 갈리기 때문(battery.jl inject_battery_fault!).
REPLACE_SOC_THRESHOLD = 0.2


def _f(v, default=math.nan):
    """JSON 이 문자열로 준 'NaN'/'Inf' 를 float 으로 되돌린다."""
    if v is None:
        return default
    if isinstance(v, str):
        if v in ("NaN", "nan"):
            return math.nan
        if v in ("Inf", "inf", "-Inf"):
            return math.inf
        try:
            return float(v)
        except ValueError:
            return default
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _pseudo_robot_id(instance):
    """복원용 가짜 로봇 번호. 실제 id 는 덤프에 없다.

    결정을 바꾸지 않는 식별자이므로 익명화해도 정보 손실이 없지만, 지어낸 값이라는 사실은
    nl_source='synthesized' 로 항상 함께 다닌다.
    """
    h = hashlib.md5(str(instance).encode("utf-8")).hexdigest()
    return int(h[:4], 16) % 90 + 10          # R10..R99


# ==========================================================================================
#  주입기(injector)가 실제로 내보내는 문장 -- 템플릿을 그대로 옮겨온 것
# ==========================================================================================
# 출처:
#   fault   : ConstructionBots.jl/src/respec/ood_injection.jl  (fault_robot! 의 return)
#   battery : ConstructionBots.jl/src/navigator/battery.jl     (inject_battery_fault! 의 nl)
#   zone    : wm4.../oracle/gen_oracle_dataset.jl              (place_blocking_zone! / place_harmless_zone!)

def _nl_fault(rid):
    return (f"Robot R{rid} has broken down on the build floor and cannot move; "
            f"dispatch the nearest backup robot to take over its remaining work.")


def _nl_battery(rid, soc):
    pct = int(round(100 * soc))
    if soc <= REPLACE_SOC_THRESHOLD:
        return (f"Robot R{rid}'s battery is critically flat at about {pct}% charge; it can no longer "
                f"drive or carry — treat it as broken down and hand its work to a backup robot.")
    return (f"Robot R{rid}'s battery is degraded and now at about {pct}% charge; "
            f"it should avoid long-distance and heavy-payload hauls so it does not run flat.")


def _nl_zone():
    return ("A no-go exclusion zone has appeared near a staging area; "
            "restage the affected assembly out of the restricted region.")


def synthesize_nl(row):
    """덤프 한 행 -> 주입기가 냈을 문장(복원). 종류 이름(kind)이 아니라 어떤 필드가 유효한지로 분기한다.

    features_agnostic.descriptors_from_row 와 같은 판별 규칙을 쓴다:
      soc 가 유한        -> 배터리 사건
      zone_overlap >= 0  -> 공간(구역) 사건
      그 밖              -> 기계적 고장
    """
    soc = _f(row.get("soc"))
    zov = _f(row.get("zone_overlap"), -1.0)
    rid = _pseudo_robot_id(row.get("instance", "?"))
    if math.isfinite(zov) and zov >= 0.0:
        return _nl_zone()
    if math.isfinite(soc):
        return _nl_battery(rid, soc)
    return _nl_fault(rid)


def event_nl(row):
    """(문장, 출처) 를 돌려준다. 출처는 'captured' 또는 'synthesized'.

    row 는 dict 또는 pandas Series. 라벨러가 실제로 저장한 문장이 있으면 무조건 그것을 쓴다.
    """
    raw = row.get("nl", None)
    if isinstance(raw, str) and raw.strip():
        src = row.get("nl_source", "captured")
        return raw.strip(), (src if isinstance(src, str) and src else "captured")
    return synthesize_nl(row), "synthesized"


def attach_nl(df):
    """DataFrame 에 nl_text / nl_provenance 두 열을 추가해 돌려준다(원본은 안 건드림)."""
    out = df.copy()
    pairs = [event_nl(df.iloc[i]) for i in range(len(df))]
    out["nl_text"] = [p[0] for p in pairs]
    out["nl_provenance"] = [p[1] for p in pairs]
    return out


def provenance_summary(df):
    """캡처/복원 비율. 모든 리포트가 이 줄을 찍어야 숫자의 등급을 오해하지 않는다."""
    pairs = [event_nl(df.iloc[i]) for i in range(len(df))]
    n_cap = sum(1 for _, s in pairs if s == "captured")
    return {"n_rows": len(pairs), "captured": n_cap, "synthesized": len(pairs) - n_cap,
            "grade": ("evidence" if n_cap == len(pairs) else
                      ("mixed" if n_cap else "reconstruction"))}


# ==========================================================================================
#  의미 키: 결정과 무관한 식별자를 지운 문장
# ==========================================================================================
# 로봇 번호("R37")와 좌표("(12.4, -3.1)")는 **어느 대응이 옳은지를 전혀 바꾸지 않는다** -- 어떤 로봇이든
# 고장은 고장이고, 구역이 어디 있든 답은 겹침 정도로 정해진다. 반면 충전 퍼센트("about 12% charge")는
# 답을 바꾸므로 남긴다.
# 이 정규화 없이 상한을 계산하면 "모든 문장이 서로 다르다 -> 상한 0" 이라는 가짜 결론이 나온다
# (실제로 처음 돌렸을 때 그랬다). 상한의 의미는 "구분에 쓸 수 있는 정보가 문장에 있는가"이지
# "문자열이 유일한가"가 아니다.
import re

_ID_RE = re.compile(r"\bR\d+\b")
_COORD_RE = re.compile(r"\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)")


def nl_semantic_key(text):
    """결정과 무관한 식별자(로봇번호·좌표)를 가린 문장. 충전 퍼센트 등 결정에 영향 주는 수치는 유지."""
    t = _COORD_RE.sub("(#, #)", str(text))
    t = _ID_RE.sub("R#", t)
    return " ".join(t.split())


# ==========================================================================================
#  관찰 vs 지시: 주입기의 문장에는 **정답이 산문으로 들어 있다**
# ==========================================================================================
# 2026-07-28 라이브 데모를 처음 돌려보고 발견한 것. 네 템플릿이 전부 이렇게 끝난다:
#
#   fault        "... and cannot move; dispatch the nearest backup robot to take over its remaining work."
#   battery(깊음) "... can no longer drive or carry — treat it as broken down and hand its work to a backup robot."
#   battery(약함) "... it should avoid long-distance and heavy-payload hauls so it does not run flat."
#   zone         "... blocking a staging area; restage the affected assembly out of the restricted region."
#
# 뒷절이 곧 canonical 정답(Replace / Replace / Deprioritize / ForbidZone)이다. 이 문장을 그대로
# LLM 에 주면 우리가 재는 것은 "LLM 이 상황을 해석하는 능력"이 아니라 **"문장에 적힌 지시를 따르는가"**다.
# 실제로 라이브 데모에서 LLM 은 서술자를 읽고 "harm and work at risk are minimal" 이라고 써 놓고도
# ForbidZone 을 골랐다 — 문장이 restage 하라고 했으니까. (오프라인 C1 에서 llm:nl 이 zoneblk 에서
# regret 1.000 이었던 것도 같은 이유로 설명된다: 모든 zone 문장이 restage 를 지시한다.)
#
# 그래서 producer 입력 경계에서 **지시 절을 떼어낸다**. 주입기 자체는 건드리지 않는다(다른 데모와
# 애니메이션이 그 문장을 쓴다). 떼어낸 결과가 "관찰만 남은" 문장이다.
#
#   raw          기존 문장 그대로 (지시 포함) — 예전 수치를 재현할 때
#   observation  지시 절 제거 — "LLM 이 해석하는가"를 재는 정직한 설정
#
# 이건 데이터를 조작하는 게 아니라, **입력 채널에서 정답 누수를 제거**하는 것이다. verify.py 의
# V0(정답은 LLM 이 짓지 않는다)와 같은 원칙이 입력 쪽에도 적용되어야 한다.

# 지시 절을 여는 표현들(문장 뒷부분이 "무엇을 하라"로 넘어가는 지점).
_IMPERATIVE = re.compile(
    r"(?:;|—|--|,)?\s*(?:"
    r"dispatch\b|restage\b|treat it as\b|hand its work\b|hand it\b|replace\b|"
    r"reroute\b|re-?stage\b|it should avoid\b|avoid\b|lower its\b|deprioriti[sz]e\b"
    r")",
    re.I)


def observation_only(text):
    """문장에서 **무엇을 하라**는 부분을 떼고 **무슨 일이 있었는가**만 남긴다.

    예)
      입력: "Robot R1 has broken down at (-0.8, 0.7) and cannot move; dispatch the nearest
             backup robot to take over its remaining work."
      출력: "Robot R1 has broken down at (-0.8, 0.7) and cannot move."

    지시 절을 못 찾으면 원문을 그대로 돌려준다(과하게 자르지 않는다).
    """
    t = " ".join(str(text or "").split())
    if not t:
        return t
    m = _IMPERATIVE.search(t)
    if not m or m.start() == 0:
        return t
    head = t[:m.start()].rstrip(" ;,—-")
    if len(head) < 20:              # 너무 많이 잘렸으면 자르지 않는다
        return t
    return head + "."


def nl_for_producer(text, mode=None):
    """producer 에게 줄 문장. mode = "observation"(기본 권장) | "raw".

    환경변수 LLM_NL_MODE 로 전역 지정. 기본값은 "raw" -- 기존에 캐시된 응답과 발표된 수치가
    조용히 바뀌지 않도록(모드를 바꾸면 프롬프트가 바뀌어 캐시가 전부 미스가 된다).
    """
    import os
    m = (mode or os.environ.get("LLM_NL_MODE", "raw")).lower()
    return observation_only(text) if m.startswith("obs") else text


# ==========================================================================================
#  NL-only 상한: "문장만 보는 정책이 원리적으로 낼 수 있는 최고 성적"
# ==========================================================================================
def nl_partition_ceiling(df, lam=3.0, nl_of=None):
    """문장이 같은 instance 들을 한 덩어리로 묶고, 덩어리마다 **하나의** macro 만 고를 수 있다고 할 때의
    최소 평균 regret.

    왜 필요한가: 이 데이터셋은 fault/faultidle, zoneblk/zoneharm 에 **일부러 같은 문장**을 준다.
    그래서 문장만 받은 producer 는 두 변종을 구분할 방법이 없다 -- LLM 이 나빠서가 아니라 정보가 없어서다.
    이 함수가 그 한계선을 숫자로 준다. LLM(nl) arm 은 0 이 아니라 **이 값**과 비교해야 공정하다.

    반환: {"ceiling": float, "n_groups": int, "groups": [...]}
    """
    from verify import norm_regret
    from openworld_experiments import valid_macros_of

    # 기본 묶음 기준 = 의미 키(식별자 마스킹 후). nl_of 로 다른 기준을 줄 수 있다.
    nl_of = nl_of or (lambda g: nl_semantic_key(event_nl(g.iloc[0])[0]))
    by_inst = {i: g for i, g in df.groupby("instance")}

    groups = {}
    for i, g in by_inst.items():
        groups.setdefault(nl_of(g), []).append(i)

    total, detail = [], []
    for text, insts in groups.items():
        # 이 덩어리 전체에 같은 macro 하나를 강제했을 때의 평균 regret 을 macro 마다 계산 -> 최소값 채택.
        cand = set()
        for i in insts:
            cand |= valid_macros_of(by_inst[i])
        best_m, best_r = None, None
        for m in sorted(cand):
            rs = [norm_regret(by_inst[i], m if m in valid_macros_of(by_inst[i])
                              else min(valid_macros_of(by_inst[i])), lam) for i in insts]
            mean_r = sum(rs) / len(rs)
            if best_r is None or mean_r < best_r:
                best_m, best_r = m, mean_r
        per = [norm_regret(by_inst[i], best_m if best_m in valid_macros_of(by_inst[i])
                           else min(valid_macros_of(by_inst[i])), lam) for i in insts]
        total += per
        detail.append({"nl": text[:70], "n_inst": len(insts), "best_macro": int(best_m),
                       "regret": float(sum(per) / len(per))})

    return {"ceiling": float(sum(total) / len(total)) if total else float("nan"),
            "n_groups": len(groups), "groups": sorted(detail, key=lambda d: -d["regret"])}


# ==========================================================================================
def main():
    import json
    import pandas as pd
    from e1_analyze import load

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = args[0] if args else "oracle/out/openworld_merged.jsonl"
    write = next((a.split("=")[1] for a in sys.argv[1:] if a.startswith("--write=")), None)

    df = load(path)
    df = df[df.fired == True].copy()
    prov = provenance_summary(df)
    print(f"[data] {path}: {len(df)} rows, {df.instance.nunique()} instances")
    print(f"[nl]   captured={prov['captured']}  synthesized={prov['synthesized']}  "
          f"-> grade={prov['grade']}")
    if prov["grade"] != "evidence":
        print("       (복원본 포함. 확정 수치를 뽑기 전 라벨러 재생성 필요 -- 위 docstring 참고)")

    print("\n-- one sentence per kind --")
    for k in sorted(df.kind.astype(str).unique()):
        g = df[df.kind.astype(str) == k]
        for v in sorted(g.variant.astype(str).unique()) if "variant" in g else [k]:
            gg = g[g.variant.astype(str) == v] if "variant" in g else g
            if not len(gg):
                continue
            t, s = event_nl(gg.iloc[0])
            print(f"  [{k}/{v}] ({s})\n    {t}")

    print("\n-- NL-only ceiling (문장만 보는 정책의 원리적 최고 성적) --")
    c = nl_partition_ceiling(df)
    print(f"  {c['n_groups']} distinct sentences over {df.instance.nunique()} instances")
    print(f"  best achievable mean regret with NL alone = {c['ceiling']:.3f}  (0 = perfect)")
    print("  worst sentence groups (문장이 같아 구분이 불가능한 곳):")
    for d in c["groups"][:4]:
        print(f"    regret={d['regret']:.3f}  n={d['n_inst']}  macro={d['best_macro']}  {d['nl']}...")

    if write:
        rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
        with open(write, "w", encoding="utf-8") as f:
            for r in rows:
                t, s = event_nl(r)
                r.setdefault("nl", t)
                r.setdefault("nl_source", s)
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"\n[saved] {write}  (nl / nl_source backfilled, existing values untouched)")


if __name__ == "__main__":
    main()
