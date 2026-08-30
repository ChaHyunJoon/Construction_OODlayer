#!/usr/bin/env python3
"""
shadow_score.py -- STEP A: 새 시뮬 0회로 4 producer + 2 싼 기준선을 동일 사건·동일 분모 위에서 재채점.

매 결정 레코드는 `rule`/`surrogate`/`llm` 세 producer 가 **그 순간** 무엇을 골랐을지를 이미
shadow 로 함께 적어 둔다(같은 사건, 같은 상태). a*(기준 행동)는 상태(`truth`/`soc`/
`agent_pending`/`zone_primitives`)에서만 정해지고 어느 producer 를 채점하는지와 무관하므로,
세 producer + 실제 enacted `macro` 를 `reference_policy.score()` 로 다시 채점하면(재구현 금지)
언제나 같은 분모가 나온다 -- 이게 llm_ood_eval.py §1 표의 정책별 분모 불일치를 해소하는 원리다.

여기 더해 "이겨야 하는" 싼 기준선 둘을 얹는다:
  B1 kind->macro 룩업표. always_per_kind(e1_analyze.py:377-379)와 같은 방식(최빈 정답)이되,
     여기엔 훈련 폴드가 없으므로 leave-one-out 으로 대신한다(자기 자신은 절대 안 본다).
  B2 random-over-valid 의 해석적 기댓값(몬테카를로 아님).

실행: python reporting/shadow_score.py --in results/llm_ood_eval.jsonl --md artifacts_night/shadow.md
"""
import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

# 2026-08-18 폴더 분류 이후의 기준점 — HERE 는 이 파일 폴더(reporting/), 
# WM 은 wm4spacecraft_manufacturing/ 다. 데이터 폴더(results_4pol/ · artifacts_4pol/ ·
# dp_oracle/ · md/ · results/)는 전부 WM 기준이다. 코드 폴더 전부를 sys.path 에 올려
# 맨이름 import 를 유지한다(근거는 core/wmpath.py 머리말).
HERE = Path(__file__).resolve().parent
WM = HERE.parent
sys.path.insert(0, str(WM / "core"))
import wmpath                                            # noqa: E402,F401

import reference_policy                  # noqa: E402  (채점기 재사용 -- 재구현 금지)
from ood_sweep_report import wilson       # noqa: E402  (CI 재사용)
from stats_paired import cluster_bootstrap_ci     # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8")    # cp949 콘솔에서 한글/기호가 죽는 것 방지
except Exception:
    pass

DEFAULT_IN = WM / "results" / "llm_ood_eval.jsonl"
KINDS = ("BatteryTruth", "FaultTruth", "ZoneTruth")     # 2026-08-20 4팔 축소 이후 사건 종류는 이 셋뿐
PRODUCERS = [("rule", "rule"), ("surrogate", "surrogate"), ("llm", "llm"), ("macro (실제 enacted)", "macro")]

# 계획서 §3 에서 그대로 복사한 해석 한계 문단 -- 축약 금지, 출력에 그대로 남긴다.
INTERPRETATION_LIMIT = (
    '> 실행된 정책이 이후 세계를 갈라놓으므로 shadow 채점은 "이 상태에서 정책 X 는 a\\* 를 골랐겠는가"\n'
    "> (상태 조건부 결정 충실도)이지 **결과 비교가 아니다.** 완주·시간·에너지를 shadow 로 말하면 안 된다."
)


def load_rows_and_decisions(paths):
    """여러 결과 jsonl(case 별) 을 합쳐 (판 목록, 결정 목록 하나) 로 돌려준다.

    각 결정에 `_board = (case, ood_seed, policy)` 를 찍어 둔다 -- 같은 판 안의 결정은
    같은 사건 스트림·같은 정책·같은 상태 궤적을 공유해 서로 독립이 아니다. 이 키가
    없으면 군집 부트스트랩 CI(group_by_board)가 판 경계를 못 찾는다."""
    rows, decisions = [], []
    for p in paths:
        with open(p, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    r = json.loads(line)
                    rows.append(r)
                    board = (r.get("case"), r.get("ood_seed"), r.get("policy"))
                    for d in (r.get("decisions") or []):
                        d["_board"] = board
                        decisions.append(d)
    return rows, decisions


def score_producer(decisions, field):
    """decisions 의 macro 를 producer 필드로 갈아 끼운 얕은 복사본으로 reference_policy.score 재사용.

    reference_policy.score() 는 내부에서 고정된 키만 담은 새 dict 를 만들어 돌려주므로
    (재구현 금지 -- 손댈 수 없다) `_board` 가 그 안에서 유실된다. decisions 순서와
    반환된 rows 순서가 1:1 이라는 score() 의 계약(각 ev 마다 정확히 한 row)에 기대어
    사후에 다시 붙인다."""
    n, c, rows = reference_policy.score([dict(d, macro=d.get(field)) for d in decisions])
    for d, r in zip(decisions, rows):
        r["_board"] = d.get("_board")
    return n, c, rows


def group_by_board(scored):
    """채점된 결정들을 판(board) 단위 군집으로 묶는다. 반환: list[list[bool]].

    `_board` 키가 (case, ood_seed, policy) 를 담는다. 같은 판 안의 결정은 서로 독립이 아니다
    -- 같은 스트림·같은 정책·같은 상태 궤적이다. 그래서 CI 는 결정이 아니라 판을 재표집해야 한다.
    """
    buckets = {}
    for d in scored:
        buckets.setdefault(d.get("_board"), []).append(bool(d.get("correct")))
    return list(buckets.values())


def per_kind(rows):
    """score() 의 rows 를 truth kind 별 [n, correct] 로 묶는다(채점된 것만)."""
    out = defaultdict(lambda: [0, 0])
    for r in rows:
        if r["correct"] is not None:
            out[r["truth"]][0] += 1
            out[r["truth"]][1] += int(r["correct"])
    return out


def baseline_b1(scored_rows):
    """B1: leave-one-out kind->최빈 a* 룩업. 결정 i 의 예측은 같은 kind 인 **다른** 채점된
    결정들만의 최빈 a* 다(자기 자신을 포함하면 트리비얼하게 이겨버린다)."""
    by_kind = defaultdict(list)
    for i, r in enumerate(scored_rows):
        by_kind[r["truth"]].append(i)
    correct, pk = 0, defaultdict(lambda: [0, 0])
    for i, r in enumerate(scored_rows):
        others = [scored_rows[j]["reference"] for j in by_kind[r["truth"]] if j != i]
        pred = Counter(others).most_common(1)[0][0] if others else None
        ok = int(pred == r["reference"])
        pk[r["truth"]][0] += 1
        pk[r["truth"]][1] += ok
        correct += ok
    return correct, len(scored_rows), pk


def baseline_b2(decisions, rows):
    """B2: valid 위 균등추첨의 해석적 기댓값 = mean(1/|valid| if a* in valid else 0) (몬테카를로 아님)."""
    total, n, pk = 0.0, 0, defaultdict(lambda: [0, 0.0])
    for ev, r in zip(decisions, rows):
        if r["correct"] is None:
            continue
        n += 1
        valid = list(ev.get("valid") or [])
        contrib = (1.0 / len(valid)) if (valid and r["reference"] in valid) else 0.0
        total += contrib
        pk[r["truth"]][0] += 1
        pk[r["truth"]][1] += contrib
    return total, n, pk


def novelty_gate_replay(rows, decisions):
    """산출4: novelty 게이트의 사후 재생.

    🔴 **2026-08-29 (Ruling R14): 이 산출은 입력이 없다.** 옛 docstring 은 현재형으로
    *"router_novel/router_p 는 라우터 on/off 와 무관하게 매 결정에서 계산·기록된다"* 라고
    적었는데, T12(`23655a6a`)가 결정 행에서 그 두 열을 지웠고 §B-1 이 그것을 만들던 novelty 축
    자체를 지웠다. 그래서 새 산출물에서 `ps` 는 언제나 비고 `n_novel` 은 언제나 0 이다 —
    그 0 은 **"낯선 사건이 없었다" 가 아니라 "그 축이 없다"** 로 읽어야 한다.
    옛(2026-08-29 이전) 녹화에 대해서는 그대로 동작한다.

    🔴 **로직은 손대지 않았다** — 이 함수를 어떻게 할지(지운다 / 다른 신뢰도 축으로 갈아끼운다)는
    갭 원장 §F 로 사용자에게 에스컬레이션돼 있다. 여기서는 거짓 현재형 주장만 걷어낸다.
    (`sweep/llm_ood_eval.py` 의 risk-coverage 도 같은 §F 항목이다.)
    """
    ps = [d.get("router_p") for d in decisions if d.get("router_p") is not None]
    n_novel = sum(1 for d in decisions if d.get("router_novel"))
    return dict(n=len(decisions), n_novel=n_novel, router_flags=Counter(str(r.get("router")) for r in rows),
                p_min=min(ps) if ps else None, p_max=max(ps) if ps else None,
                p_mean=(sum(ps) / len(ps)) if ps else None)


def fmt(k, n):
    return "n/a" if not n else "%.1f%% (%d/%d)" % (100 * k / n, k, n)


def build_report(rows, decisions):
    base_rows = reference_policy.score(decisions)[2]     # a* 는 producer 와 무관 -- 분모 공유의 근거
    scored_rows = [r for r in base_rows if r["correct"] is not None]
    N = len(scored_rows)
    L = ["# Shadow Score -- STEP A (새 시뮬 0회, 동일 사건·동일 분모)", "",
         "입력: %d rows / %d decisions. 공유 분모 N = %d (kind 는 알지만 필수 상태 필드가 없거나 "
         "실측 격자가 없어 unscored 로 빠진 사건은 제외)." % (len(rows), len(decisions), N), "",
         "## 산출 1 -- producer 4개 (동일 사건·동일 분모 N=%d)" % N, "",
         "| producer | n | 옳은 결정 (Wilson, 결정단위) | 95% CI (군집 부트스트랩, 판단위) |",
         "|---|---|---|---|"]
    for label, field in PRODUCERS:
        s, c, prows = score_producer(decisions, field)
        lo, hi = wilson(c, s)
        rows_scored = [r for r in prows if r["correct"] is not None]
        _, clo, chi = cluster_bootstrap_ci(group_by_board(rows_scored), reps=10000, seed=0)
        L.append("| `%s` | %d | %s [%.2f, %.2f] | [%.2f, %.2f] |"
                 % (label, s, fmt(c, s), lo, hi, clo, chi))
    L += ["", "| producer | Battery | Fault | Zone |", "|---|---|---|---|"]
    for label, field in PRODUCERS:
        pk = per_kind(score_producer(decisions, field)[2])
        cells = [fmt(pk[k][1], pk[k][0]) for k in KINDS]           # pk[kind] = [n, correct]
        L.append("| `%s` | %s | %s | %s |" % (label, *cells))

    b1c, b1n, b1pk = baseline_b1(scored_rows)
    L += ["", "## 산출 2 -- B1 kind->macro 룩업표 (leave-one-out, 자기 자신 제외)", "",
          "| kind | n | 옳음 | rate |", "|---|---|---|---|"]
    for k in KINDS:
        n, c = b1pk[k]
        L.append("| %s | %d | %d | %s |" % (k.replace("Truth", ""), n, c, fmt(c, n)))
    L.append("| **합계** | **%d** | **%d** | **%s** |" % (b1n, b1c, fmt(b1c, b1n)))

    b2t, b2n, b2pk = baseline_b2(decisions, base_rows)
    L += ["", "## 산출 3 -- B2 random-over-valid (해석적 기댓값, 몬테카를로 아님)", "",
          "| kind | n | 기댓값 합 | rate |", "|---|---|---|---|"]
    for k in KINDS:
        n, t = b2pk[k]
        L.append("| %s | %d | %.2f | %.1f%% |" % (k.replace("Truth", ""), n, t, 100 * t / n if n else 0))
    L.append("| **합계** | **%d** | **%.2f** | **%.1f%%** |" % (b2n, b2t, 100 * b2t / b2n if b2n else 0))
    L += ["", "Fault 는 `valid` 가 기록되지 않아(정책 서버가 fault 에는 legal-macro 메뉴를 안 실어 보냄, "
          "`policy.jl:248` 의 kind 분기가 battery/zone 만 채운다) B2 기여가 언제나 0 이다 -- 이건 이 "
          "스크립트의 버그가 아니라 원본 로그의 공백이다. Zone 은 `valid=[NOOP, RelocateBuild]` 이므로 "
          "기댓값 50%가 바닥선 -- surrogate 의 zone 7/7 은 이 50% 에 견줘 읽어야 한다."]

    ng = novelty_gate_replay(rows, decisions)
    L += ["", "## 산출 4 -- novelty 게이트 사후 재생", "",
          "router flag (판 단위, DEMO_ROUTER): %s" % dict(ng["router_flags"]), "",
          "router_p: n=%d, mean=%.3f, range=[%.3f, %.3f]" %
          (len(decisions), ng["p_mean"] or 0, ng["p_min"] or 0, ng["p_max"] or 0), "",
          '"라우터가 켜졌다면 LLM 으로 올라갔을 결정" 비율 (router_novel==True, 사후 재생): %s' %
          fmt(ng["n_novel"], ng["n"])]

    L += ["", "## 해석 한계", "", INTERPRETATION_LIMIT, ""]
    return L


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--in", dest="inputs", nargs="+", default=[str(DEFAULT_IN)],
                     help="결정 로그 jsonl(들). case 별 파일을 여러 개 받으면 합산한다.")
    ap.add_argument("--md", default="", help="markdown 조각을 쓸 경로")
    args = ap.parse_args()

    paths = [Path(p) for p in args.inputs]
    for p in paths:
        if not p.exists():
            print("입력 파일이 없다: %s" % p)
            return 1
    rows, decisions = load_rows_and_decisions(paths)
    if not decisions:
        print("결정이 0개다: %s" % paths)
        return 1

    text = "\n".join(build_report(rows, decisions)) + "\n"
    print(text)
    if args.md:
        out = Path(args.md)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8")
        print("markdown -> %s" % out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
