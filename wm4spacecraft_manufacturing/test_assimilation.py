#!/usr/bin/env python
"""
test_assimilation.py -- C1/C3/C4 하니스의 자기점검. API 호출 0회, 몇 초면 끝난다.

무엇을 지키는가 (전부 "조용히 깨지면 실험이 무효가 되는" 종류의 불변식):

  T1  NL 출처가 정직하게 표시되는가        -- 복원본을 캡처본으로 둔갑시키면 안 된다
  T2  식별자 마스킹이 동작하는가            -- 안 하면 "상한 0" 이라는 가짜 결론이 난다
  T3  NL-only 상한이 0 보다 큰가            -- 이 데이터셋은 무해/유해에 같은 문장을 준다
  T4  파서가 어휘 밖 응답을 잡아내는가      -- "못 알아들음"과 "restraint 선택"이 섞이면 안 된다
  T5  few-shot demo 에 held-out 종류가 없는가 -- 있으면 그 순간 '처음 보는 종류'가 아니다 (누수)
  T6  mock 캐시가 실제 모델 캐시와 분리되는가 -- 섞이면 가짜 답이 실측치로 표에 실린다
  T7  프롬프트에 정답/시뮬결과가 안 새는가   -- closed/makespan/complete/valid_mask 누수 검사
  T8  게이트 갱신이 실제로 낯섦 점수를 낮추는가 -- 이게 없으면 C4 는 원리적으로 성립 불가

실행:  python test_assimilation.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np

from e1_analyze import load
from features_agnostic import STATE_DESCRIPTORS, descriptors_from_row
from llm_producer import (MACRO_NAME, Producer, build_demos, parse_macro,
                          render_prompt, render_state)
from nl_events import (event_nl, nl_partition_ceiling, nl_semantic_key,
                       provenance_summary)
from openworld_experiments import fit_novelty, load_df, novelty_of, valid_macros_of
from verify import oracle_best_macro

DATA = sys.argv[1] if len(sys.argv) > 1 else "oracle/out/openworld_merged.jsonl"
PASS, FAIL = [], []


def check(name, ok, detail=""):
    (PASS if ok else FAIL).append(name)
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  -- {detail}" if detail else ""))


def main():
    df = load_df(DATA)
    by_inst = {i: g for i, g in df.groupby("instance")}
    print(f"[data] {DATA}: {len(df)} rows, {len(by_inst)} instances\n")

    # T1 -----------------------------------------------------------------------------------
    prov = provenance_summary(df)
    row = df.iloc[0].to_dict()
    _, src = event_nl(row)
    has_nl = isinstance(row.get("nl"), str) and row.get("nl", "").strip()
    check("T1 NL 출처 표시가 실제 데이터와 일치",
          (src == "captured") == bool(has_nl),
          f"grade={prov['grade']} captured={prov['captured']}/{prov['n_rows']}")

    # T2 -----------------------------------------------------------------------------------
    a = nl_semantic_key("Robot R12 has broken down at (3.10, -4.00) and cannot move")
    b = nl_semantic_key("Robot R77 has broken down at (-1.00, 8.20) and cannot move")
    keep = nl_semantic_key("battery ... about 12% charge") != nl_semantic_key("battery ... about 45% charge")
    check("T2 식별자(로봇번호·좌표)는 마스킹되고 결정에 쓰이는 수치는 남는다", a == b and keep)

    # T3 -----------------------------------------------------------------------------------
    ceil = nl_partition_ceiling(df)
    check("T3 NL-only 상한이 0 보다 크다(무해/유해가 같은 문장이므로)",
          ceil["ceiling"] > 1e-9,
          f"ceiling={ceil['ceiling']:.3f} over {ceil['n_groups']} sentence groups")

    # T4 -----------------------------------------------------------------------------------
    m1, ok1, _ = parse_macro("MACRO: Replace\nWHY: lost a robot.")
    m2, ok2, _ = parse_macro("MACRO: Teleport\nWHY: nonsense.")
    m3, ok3, _ = parse_macro("I think Deprioritize is best here.")
    check("T4 파서: 정상/어휘밖/자유형식을 구분",
          (m1 == 1 and ok1) and (not ok2 and m2 == 0) and (m3 == 2 and ok3))

    # T5 -----------------------------------------------------------------------------------
    best = {i: oracle_best_macro(g, 3.0) for i, g in by_inst.items()}
    kind_of = {i: str(g.kind.iloc[0]) for i, g in by_inst.items()}
    held = sorted(set(kind_of.values()))[0]
    tr = [i for i in by_inst if kind_of[i] != held]
    demos = build_demos(df, list(by_inst), best, "nl+state", k=8, exclude_kinds=(held,))
    # demo 문자열 안에 held-out 종류의 사건이 들어갔는지 간접 확인: 그 종류 instance 의 상태 문자열과 대조
    held_states = {render_state(by_inst[i].iloc[0], "nl+state") for i in by_inst if kind_of[i] == held}
    leaked = [d for d in demos if d[0] in held_states]
    check("T5 few-shot demo 에 held-out 종류가 없다(누수 방지)",
          len(demos) > 0 and not leaked,
          f"held={held}, demos={len(demos)}, leaked={len(leaked)}")

    # T6 -----------------------------------------------------------------------------------
    p_mock = Producer(model="gpt-4o-mini", mock=True)
    p_real = Producer(model="gpt-4o-mini", mock=False, offline=True)
    check("T6 mock 캐시가 실제 모델 캐시와 다른 파일",
          os.path.abspath(p_mock.cache_path) != os.path.abspath(p_real.cache_path),
          os.path.basename(p_mock.cache_path) + " vs " + os.path.basename(p_real.cache_path))

    # T7 -----------------------------------------------------------------------------------
    g = by_inst[sorted(by_inst)[0]]
    banned_vals = []
    for arm in ("nl", "nl+state", "feat"):
        pr = render_prompt(g.iloc[0], arm)
        low = pr.lower()
        for word in ("closed", "makespan", "complete", "valid_mask", "oracle_best", "label_seconds"):
            if word in low:
                banned_vals.append((arm, word))
    check("T7 프롬프트에 정답/시뮬결과 필드가 없다", not banned_vals, str(banned_vals))

    # T8 -----------------------------------------------------------------------------------
    # 새 종류를 학습풀에 넣기 전/후로 그 종류의 낯섦 점수가 실제로 내려가는가.
    novel = sorted(set(kind_of.values()))[-1]
    known = [i for i in by_inst if kind_of[i] != novel]
    nov = [i for i in by_inst if kind_of[i] == novel]
    D = lambda ids: np.asarray([[descriptors_from_row(by_inst[i].iloc[0])[k]
                                 for k in STATE_DESCRIPTORS] for i in ids], float)
    mu, sd, cal = fit_novelty(D(known))
    before = np.mean([novelty_of(mu, sd, D([i])[0]) for i in nov[len(nov) // 2:]])
    mu2, sd2, cal2 = fit_novelty(D(known + nov[:len(nov) // 2]))     # 절반을 동화한 뒤
    after = np.mean([novelty_of(mu2, sd2, D([i])[0]) for i in nov[len(nov) // 2:]])
    check("T8 동화 후 그 종류의 낯섦 점수가 내려간다(C4 의 전제)",
          after < before,
          f"novel={novel}  before={before:.3f} -> after={after:.3f}")

    # T9 -----------------------------------------------------------------------------------
    # 주입기 문장은 "무슨 일이 있었는가" 뒤에 **"무엇을 하라"**를 붙인다. 그 뒷절이 곧 canonical
    # 정답이라, 그대로 주면 LLM 은 해석하지 않고 지시만 따라도 맞힌다(= 입력 쪽 정답 누수).
    # observation_only 가 네 템플릿 모두에서 지시 절만 정확히 떼는지 감시한다.
    from nl_events import observation_only
    fixtures = [
        ("Robot R1 has broken down at (-0.8, 0.7) and cannot move; dispatch the nearest "
         "backup robot to take over its remaining work.", "dispatch"),
        ("Robot R7's battery is critically flat at about 12% charge; it can no longer drive "
         "or carry — treat it as broken down and hand its work to a backup robot.", "treat it as"),
        ("Robot R7's battery is degraded and now at about 45% charge; it should avoid "
         "long-distance and heavy-payload hauls so it does not run flat.", "avoid"),
        ("A no-go exclusion zone has appeared at (3.39, 0.4) blocking a staging area; "
         "restage the affected assembly out of the restricted region.", "restage"),
    ]
    bad = []
    for raw, verb in fixtures:
        obs = observation_only(raw)
        if verb.lower() in obs.lower():
            bad.append(("지시 절이 남음", obs))
        if len(obs) < 25 or obs == raw:
            bad.append(("잘못 잘림", obs))
    # 진단 정보(충전 %, 위치)는 남아야 한다 -- 이걸 지우면 판단 근거까지 없애는 것.
    keep = observation_only(fixtures[1][0])
    if "12%" not in keep:
        bad.append(("진단 수치가 사라짐", keep))
    check("T9 관찰 문장에서 '무엇을 하라'만 제거되고 관찰 내용은 보존", not bad, str(bad[:2]))

    print(f"\n{len(PASS)} PASS / {len(FAIL)} FAIL")
    if FAIL:
        print("실패: " + ", ".join(FAIL))
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
