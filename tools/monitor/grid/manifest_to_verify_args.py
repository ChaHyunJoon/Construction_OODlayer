#!/usr/bin/env python3
"""manifest_to_verify_args.py <jobs.jsonl> — 계획 판 한 줄을 검증기 인자 한 줄로 편다 (Task 9 Step 4).

출력(탭 구분): `run_key<TAB>stream<TAB>--expect-ctx k=v …<TAB>--require-decisions 1|""`
  · `--expect-ctx` 는 manifest 의 model·seed·zone_seed·event·campaign_id·config_digest 로 만든다
    (`verify_retry_chain.py` 는 비문자열 값을 `json.dumps` 로 비교한다 — seed=3, zone=true).
  · LM 결정이 기대되는 판(router × zone·all3, `lm_expected`)에만 `--require-decisions 1` 을 준다.
반복 대상은 스트림 glob 이 아니라 **이 manifest** 다 — 스트림이 없는 판도 한 줄이 나온다.
"""
import json
import sys

KEYS = ("model", "seed", "zone_seed", "event", "campaign_id", "config_digest")


def _s(v):
    return v if isinstance(v, str) else json.dumps(v)


def lines(path):
    with open(path) as f:
        for raw in f:
            if not raw.strip():
                continue
            j = json.loads(raw)
            ctx = j["expect_ctx"]
            args = " ".join("--expect-ctx %s=%s" % (k, _s(ctx[k])) for k in KEYS if k in ctx)
            yield "\t".join((j["run_key"], j["stream"], args,
                             "--require-decisions 1" if j.get("lm_expected") else ""))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    for line in lines(sys.argv[1]):
        print(line)
