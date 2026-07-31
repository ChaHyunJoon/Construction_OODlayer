#!/usr/bin/env python
"""
llm_producer.py -- the LLM sitting in the SAME decision slot the surrogate occupies.

    OOD event  ->  producer  ->  one of 5 recovery macros
                   ^^^^^^^^
              surrogate (0.1 ms, learned)   or   LLM (seconds, reads the sentence)

This module is the LLM half. `c1_novel_kind.py` scores it against the surrogate on a kind it has
never seen (claim C1); `assimilation_stream.py` calls it as the fallback branch of a router
(claims C3/C4). Both get the identical producer so the two experiments cannot silently diverge.

THREE INPUT ARMS -- the whole point of having a module instead of an inline prompt
=================================================================================
  "nl"        the natural-language observation ALONE.
              This is the literal reading of "the LLM interprets the situation in language".
              Its ceiling on this dataset is NOT zero -- see nl_events.nl_partition_ceiling --
              because fault/faultidle and zoneblk/zoneharm are given identical sentences on
              purpose. Score this arm against that ceiling, not against 0.

  "nl+state"  the sentence PLUS the six kind-agnostic physical descriptors
              (harm / work_at_risk / resource_loss / recovery_capacity / progress / slack).
              This is the DEPLOYABLE form: a novel event still has these six numbers, because
              features_agnostic computes them without ever reading a class name. No closed
              vocabulary is handed over.

  "feat"      the parsed schema fields (kind=battery, soc=0.55, spare_count=8, ...).
              Included as the CONTROL, not as the proposal: on a genuinely new OOD these fields
              would not exist. Comparing "nl" / "nl+state" against "feat" decomposes the LLM's
              contribution into "language understanding" vs "prior over the known schema".

WHAT IS DELIBERATELY NOT GIVEN TO THE LLM
    · the per-kind valid-action mask (it is derived from the class name -> leakage).
      The full 5-macro repertoire is always offered; the choice is gated against the valid mask
      AFTERWARDS, exactly as `openworld_experiments.pick_with_gate` gates the surrogate. Same
      post-processing on both sides, so the comparison is fair.
    · anything from OOD_TRUTH_LOG's truth half, any `closed`/`makespan`/`complete` outcome.

CACHING / COST
    Every completion is cached on disk by (model, arm, prompt) in `llm_cache/`. Re-running an
    experiment is free and reproducible; `LLM_OFFLINE=1` forbids new calls entirely so a result
    can be re-derived with no API access at all. `Producer.stats` counts real calls and tokens.

────────────────────────────────────────────────────────────────────────────────────────────
[한국어 설명]
이 파일 = surrogate 가 앉아 있는 바로 그 결정 자리에 LLM 을 앉힌 것.

입력 arm 3가지:
  nl        : 자연어 문장만. (선생님 설계의 문자 그대로) 단, 이 데이터셋에서 이 arm 의 상한은 0 이 아니다
              -- fault/faultidle, zoneblk/zoneharm 문장이 일부러 같기 때문. 상한과 비교해야 공정.
  nl+state  : 문장 + 종류 이름이 아닌 물리 서술자 6개. 실제 배포 가능한 형태(새 종류에도 계산됨).
  feat      : 정제된 스키마 필드(kind=..., soc=...). 대조군. 진짜 새 사건엔 이 필드가 없다.
              nl 계열 vs feat 를 비교하면 "LLM 의 이득이 언어이해인가 스키마 사전지식인가"가 분해된다.

LLM 에게 절대 주지 않는 것: kind 별 valid mask(종류 이름에서 나온 것 = 누수), 정답/시뮬 결과.
대신 5개 매크로 전체를 항상 보여주고, 고른 뒤에 valid mask 로 거른다 -- surrogate 와 똑같은 후처리.

캐시: 모든 응답을 llm_cache/ 에 저장. 재실행 공짜·재현 가능. LLM_OFFLINE=1 이면 새 호출 금지.

[문법 참고]
  - os.environ.get("X", "0") == "1" : 환경변수로 켜고 끄는 스위치 관용구.
  - json.dump(..., ensure_ascii=False) : 한글/기호를 \\uXXXX 로 escape 하지 않고 그대로 저장.
  - re.search(pat, s, re.I) : 대소문자 무시 정규식 검색.
────────────────────────────────────────────────────────────────────────────────────────────
"""
import hashlib
import json
import math
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from features_agnostic import STATE_DESCRIPTORS, descriptors_from_row
from nl_events import event_nl, nl_for_producer

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.join(HERE, "llm_cache")

MACRO_NAME = {0: "NOOP", 1: "Replace", 2: "Deprioritize", 3: "ForbidZone", 4: "ReformTeam"}
NAME2ID = {v.lower(): k for k, v in MACRO_NAME.items()}

# 같은 문구를 dspy_real_experiment.py 가 쓰던 것과 맞춘다. 행동 어휘 설명은 시스템의 DSL 문서이지
# 사건 종류에 대한 힌트가 아니므로, 새 종류 실험에서도 주는 것이 맞다.
MACRO_DOC = """You are the recovery controller of a multi-robot LEGO-assembly build. Something
unexpected has happened. Choose EXACTLY ONE recovery macro from this fixed repertoire:

- NOOP          : do nothing. Free (cost 0). Correct whenever the disruption is absorbed by slack
                  or spare capacity and intervening would burn a scarce resource for nothing.
- Replace       : swap the affected robot for a spare from the depot pool. Cost 1.0. Correct for a
                  genuine loss of a robot that still owed work, WHEN spares remain.
- Deprioritize  : lower the affected robot's task priority / route heavy work away from it.
                  Cheap (cost 0.3). The middle option for a degraded-but-alive robot.
- ForbidZone    : declare a no-go region and re-route / re-stage the build around it. Cost 1.0.
                  Correct when a spatial region has become unusable and it blocks pending work.
- ReformTeam    : re-form the multi-robot transport team geometrically. Cost 1.0.

An intervention must recover MORE than it costs, otherwise NOOP is the right call. Restraint is a
real answer, not a failure to answer."""

ANSWER_FORMAT = """Answer in exactly two lines:
MACRO: <one of NOOP|Replace|Deprioritize|ForbidZone|ReformTeam>
WHY: <one sentence>"""


# ==========================================================================================
#  프롬프트 렌더링 (arm 별로 "무엇을 보여줄지"가 갈리는 유일한 지점)
# ==========================================================================================
def _fmt(v, nd=2):
    try:
        f = float(v)
        return "n/a" if not math.isfinite(f) else f"{f:.{nd}f}"
    except (TypeError, ValueError):
        return "n/a"


def render_state(row, arm):
    """한 행(결정 시점 상태) -> arm 에 맞는 상태 설명 문자열.

    문장은 `nl_for_producer` 를 거친다: LLM_NL_MODE=observation 이면 주입기 문장 끝의 **지시 절**
    ("dispatch the nearest backup robot…", "restage the affected assembly…")을 떼어낸다.
    그 절이 곧 canonical 정답이라, 붙어 있으면 우리가 재는 것은 해석 능력이 아니라 지시 준수다.
    기본값은 raw(기존 동작) -- 자세한 이유는 nl_events.observation_only 참조.
    """
    if arm == "nl":
        return "OBSERVATION: " + nl_for_producer(event_nl(row)[0])

    if arm == "nl+state":
        d = descriptors_from_row(row)
        lines = ["OBSERVATION: " + nl_for_producer(event_nl(row)[0]),
                 "",
                 "MEASURED STATE (computed by the monitor without classifying the event;",
                 "each is in [0,1] and means the same thing for any kind of disruption):"]
        # 설명 문구는 정의와 함께 바뀌어야 한다. work_at_risk 의 분모가 "남은 일 전체"에서
        # "로봇 한 대 평균 몫"으로 바뀌었으므로, 옛 문구를 두면 LLM 이 0.35 를 "전체의 35%"로
        # 읽어 과대평가한다(숫자만 고치고 설명을 안 고치면 새로운 오해를 만든다).
        doc = {
            "harm": "how damaging the event is (1 = maximally damaging)",
            "work_at_risk": ("how much work this event threatens, measured in units of ONE "
                             "ROBOT'S AVERAGE SHARE of the remaining work (1.0 = this agent "
                             "alone was holding a full average robot's worth of work; 0 = none)"),
            "resource_loss": "fraction of fleet execution capacity removed",
            "recovery_capacity": "spare provisioning relative to the active fleet",
            "progress": "build progress when the event fired",
            "slack": "remaining parallelism (active fleet vs reference fleet)",
        }
        for k in STATE_DESCRIPTORS:
            lines.append(f"  {k:<18} = {_fmt(d[k])}   ({doc[k]})")
        return "\n".join(lines)

    if arm == "feat":
        # 대조군: 이미 알려진 스키마로 파싱된 필드들. 진짜 새 사건에는 존재하지 않는 정보다.
        g = lambda k, d=None: row.get(k, d)
        parts = [f"kind={g('kind')}", f"severity={_fmt(g('severity'))}",
                 f"spares_left={int(float(g('spare_count', 0) or 0))}",
                 f"agents_pending={int(float(g('agent_pending', -1) or -1))}",
                 f"progress={_fmt(g('progress', 0.0))}",
                 f"n_active={int(float(g('n_active', 0) or 0))}"]
        soc, zov = g("soc"), g("zone_overlap")
        try:
            if soc is not None and math.isfinite(float(soc)):
                parts.insert(1, f"SoC={_fmt(soc)}")
        except (TypeError, ValueError):
            pass
        try:
            if zov is not None and float(zov) >= 0.0:
                parts.insert(1, f"zone_overlap={_fmt(zov)}")
        except (TypeError, ValueError):
            pass
        return "EVENT RECORD: " + ", ".join(parts)

    raise ValueError(f"unknown arm {arm!r}")


def render_prompt(row, arm, demos=()):
    """최종 사용자 프롬프트. demos = [(state_str, macro_name), ...] 형태의 few-shot 예시(선택)."""
    blocks = [MACRO_DOC]
    if demos:
        blocks.append("Worked examples from PAST incidents (their correct macro was established by "
                      "simulating every candidate):")
        for st, ans in demos:
            blocks.append(f"---\n{st}\nMACRO: {ans}")
        blocks.append("---")
    blocks.append("NOW, the current incident:\n\n" + render_state(row, arm))
    blocks.append(ANSWER_FORMAT)
    return "\n\n".join(blocks)


# ==========================================================================================
#  응답 파싱
# ==========================================================================================
def parse_macro(text):
    """모델 출력 -> (macro_id, 어휘 안에 있었는가, 한 줄 이유).

    어휘 밖 응답은 NOOP 으로 강제한다(dspy_real_experiment 와 같은 규칙). 다만 그 사실을 flag 로
    돌려주므로, "LLM 이 못 알아들었다" 와 "LLM 이 restraint 를 골랐다" 가 섞이지 않는다.
    """
    t = str(text or "")
    m = re.search(r"MACRO\s*:\s*([A-Za-z]+)", t, re.I)
    tok = (m.group(1) if m else "").strip().lower()
    if tok not in NAME2ID:                      # 형식이 어긋나면 본문 어디든 이름이 있는지 훑는다
        for nm, mid in NAME2ID.items():
            if re.search(r"\b" + nm + r"\b", t, re.I):
                tok = nm
                break
    why = ""
    w = re.search(r"WHY\s*:\s*(.+)", t, re.I)
    if w:
        why = w.group(1).strip()[:300]
    if tok in NAME2ID:
        return NAME2ID[tok], True, why
    return 0, False, why


# ==========================================================================================
#  Producer
# ==========================================================================================
class Producer:
    """캐시가 달린 LLM 결정기. 같은 프롬프트는 두 번 호출하지 않는다.

    사용:
        p = Producer(model="gpt-4o-mini")
        out = p.decide(row, arm="nl+state", valid={0,1,2})
        out["macro"]  # 0..4, valid 로 이미 게이팅된 값
    """

    def __init__(self, model=None, temperature=0.0, max_tokens=200, cache_dir=CACHE_DIR,
                 offline=None, mock=None):
        self.model = model or os.environ.get("LLM_MODEL", "gpt-4o-mini")
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.offline = os.environ.get("LLM_OFFLINE", "0") == "1" if offline is None else offline
        # mock = API 없이 파이프라인만 돌려보는 모드. 규칙 기반으로 답한다(실험 수치로 쓰면 안 됨).
        self.mock = os.environ.get("LLM_MOCK", "0") == "1" if mock is None else mock
        # 가짜 응답은 **반드시 별도 파일**에 담는다. 같은 파일에 섞으면 다음 실제 실행이 캐시 적중으로
        # 가짜 답을 읽고, 그게 실측치인 것처럼 표에 실린다(실제로 한 번 그렇게 오염됐다).
        tag = ("mock_" if self.mock else "") + self.model.replace("/", "_")
        self.cache_path = os.path.join(cache_dir, f"{tag}.json")
        os.makedirs(cache_dir, exist_ok=True)
        self.cache = {}
        if os.path.exists(self.cache_path):
            try:
                self.cache = json.load(open(self.cache_path, encoding="utf-8"))
            except Exception:
                self.cache = {}
        self.stats = {"calls": 0, "cache_hits": 0, "tokens": 0, "seconds": 0.0,
                      "out_of_vocab": 0, "gated_away": 0, "misses_offline": 0}
        self._client = None
        self._dirty = 0

    # ---- 저수준 호출 --------------------------------------------------------------------
    def _key(self, prompt):
        h = hashlib.sha256(prompt.encode("utf-8")).hexdigest()[:32]
        return f"{self.model}|{self.temperature}|{h}"

    def _client_or_die(self):
        if self._client is None:
            from openai import OpenAI
            self._client = OpenAI()
        return self._client

    def _mock_answer(self, prompt):
        """API 없이 배선을 점검하기 위한 결정적 가짜 응답. 실험 결과로 인용 금지."""
        p = prompt.lower()
        if "exclusion zone" in p:
            return "MACRO: ForbidZone\nWHY: mock rule -- spatial event."
        if "critically flat" in p or "broken down" in p:
            return "MACRO: Replace\nWHY: mock rule -- robot lost."
        if "degraded" in p:
            return "MACRO: Deprioritize\nWHY: mock rule -- soft degradation."
        return "MACRO: NOOP\nWHY: mock rule -- default restraint."

    def complete(self, prompt):
        """프롬프트 -> 모델 텍스트. 캐시 우선. (cached 여부도 함께 반환)"""
        k = self._key(prompt)
        if k in self.cache:
            self.stats["cache_hits"] += 1
            return self.cache[k], True
        if self.mock:
            txt = self._mock_answer(prompt)
            self.cache[k] = txt
            return txt, False
        if self.offline:
            self.stats["misses_offline"] += 1
            raise RuntimeError(
                "LLM_OFFLINE=1 인데 캐시에 없는 프롬프트입니다. 먼저 온라인으로 한 번 돌려 캐시를 채우세요.\n"
                f"  cache: {self.cache_path}")
        t0 = time.time()
        r = self._client_or_die().chat.completions.create(
            model=self.model, temperature=self.temperature, max_tokens=self.max_tokens,
            messages=[{"role": "user", "content": prompt}])
        txt = r.choices[0].message.content or ""
        self.stats["calls"] += 1
        self.stats["seconds"] += time.time() - t0
        try:
            self.stats["tokens"] += int(r.usage.total_tokens)
        except Exception:
            pass
        self.cache[k] = txt
        self._dirty += 1
        if self._dirty >= 5:                    # 중간에 죽어도 지금까지 쓴 돈은 남게 주기적으로 저장
            self.save()
        return txt, False

    def save(self):
        tmp = self.cache_path + ".tmp"
        json.dump(self.cache, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=0)
        os.replace(tmp, self.cache_path)
        self._dirty = 0

    # ---- 결정 --------------------------------------------------------------------------
    def decide(self, row, arm="nl+state", valid=None, demos=()):
        """한 사건에 대해 macro 를 고른다.

        valid : 이 상태에서 실행 가능한 macro 집합. 프롬프트에는 **넣지 않고**, 고른 뒤 거르는 데만 쓴다
                (surrogate 의 pick_with_gate 와 같은 위치의 후처리).
        """
        prompt = render_prompt(row, arm, demos)
        txt, cached = self.complete(prompt)
        mid, in_vocab, why = parse_macro(txt)
        if not in_vocab:
            self.stats["out_of_vocab"] += 1
        raw = mid
        if valid and mid not in valid:
            self.stats["gated_away"] += 1
            # 게이트 밖이면 valid 중 가장 싼 것(=NOOP 이 있으면 NOOP)으로 떨어뜨린다.
            mid = 0 if 0 in valid else min(valid)
        return {"macro": int(mid), "raw_macro": int(raw), "in_vocab": in_vocab,
                "why": why, "cached": cached, "text": txt, "prompt": prompt}


def build_demos(df, instances, best_of, arm, k=8, seed=0, exclude_kinds=()):
    """few-shot 예시를 학습 instance 에서만 뽑는다.

    exclude_kinds 를 반드시 쓸 것: held-out 종류의 예시가 demo 로 들어가면 그 순간 "처음 보는 종류"가
    아니게 된다(가장 흔한 누수 경로). c1_novel_kind.py 는 항상 held-out 종류를 여기서 제외한다.
    """
    import numpy as np
    rng = np.random.default_rng(seed)
    by_inst = {i: g for i, g in df.groupby("instance")}
    pool = [i for i in instances
            if str(by_inst[i].kind.iloc[0]) not in set(exclude_kinds)]
    if not pool:
        return []
    idx = rng.permutation(len(pool))[:k]
    out = []
    for j in idx:
        i = pool[int(j)]
        g = by_inst[i]
        out.append((render_state(g.iloc[0], arm), MACRO_NAME[int(best_of[i])]))
    return out


if __name__ == "__main__":
    # 배선 점검: 각 arm 의 프롬프트가 실제로 어떻게 생겼는지 눈으로 확인한다(호출 없음).
    from e1_analyze import load
    path = sys.argv[1] if len(sys.argv) > 1 else "oracle/out/openworld_merged.jsonl"
    df = load(path)
    df = df[df.fired == True]
    row = df[df.kind.astype(str) == "battery"].iloc[0]
    for arm in ("nl", "nl+state", "feat"):
        print("=" * 92)
        print(f"ARM = {arm}")
        print("=" * 92)
        print(render_state(row, arm))
        print()
