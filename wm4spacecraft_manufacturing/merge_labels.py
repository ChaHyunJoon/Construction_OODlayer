#!/usr/bin/env python
"""merge_labels.py -- 오라클 라벨 JSONL 을 합친다.

왜 스크립트인가: 손으로 cat 하면 **instance id 충돌**을 못 본다. 같은 id 가 두 파일에 있으면
groupby("instance") 가 서로 다른 세계의 팔을 한 instance 로 뭉쳐 랭킹이 조용히 망가진다.
여기서는 충돌을 에러로 만든다(--prefix 로 명시적으로 해소).

사용:
    python merge_labels.py --out oracle/out/n44_plus8.jsonl \
        oracle/out/graded_hs_n44.jsonl oracle/out/battgrid_0805_s1.jsonl

n44_plus78.jsonl (배포 surrogate 현재 학습셋, 68 instance) 재현 -- 두 단계, --prefix 유무가 다르다:
    1) fzgrid_0806/*.jsonl 은 서로 다른 격자칸이 같은 bare id(예: "ep_s1_M1_t1")를 재사용하므로
       --prefix 로 파일명(zone-frac::seed)을 접두어로 붙여 충돌을 해소한다:
         python merge_labels.py --prefix --out oracle/out/fzgrid_0806/merged.jsonl \
             oracle/out/fzgrid_0806/fz_zf09_s1.jsonl oracle/out/fzgrid_0806/fz_zf09_s2.jsonl \
             oracle/out/fzgrid_0806/fz_zf09_s3.jsonl oracle/out/fzgrid_0806/fz_zf05_s1.jsonl \
             oracle/out/fzgrid_0806/fz_zf05_s2.jsonl oracle/out/fzgrid_0806/fz_zf05_s3.jsonl
    2) n44_plus8.jsonl 의 id 는 bare(battery_*/zoneblk_*), 위에서 만든 merged.jsonl 의 id 는 이미
       "fz_zf05_s2::ep_s2_M1_t1" 식으로 접두됐다 -- 둘이 겹치지 않으므로 이번엔 --prefix 를 **안 쓴다**:
         python merge_labels.py --out oracle/out/n44_plus78.jsonl \
             oracle/out/n44_plus8.jsonl oracle/out/fzgrid_0806/merged.jsonl
    (검증: 위 두 명령을 그대로 실행하면 286행/68 instance, --out 파일이 현재 커밋된
    oracle/out/n44_plus78.jsonl 과 인스턴스 단위로 동일하다 -- 입력 파일 나열 순서만 다르면 행 순서만
    바뀌고 내용은 같다.)
"""
import argparse, io, json, os, sys
from collections import defaultdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--prefix", action="store_true",
                    help="instance id 앞에 파일 stem 을 붙여 충돌을 해소한다")
    ap.add_argument("inputs", nargs="+")
    a = ap.parse_args()

    seen = defaultdict(set)          # instance -> {source stem}
    rows = []
    for p in a.inputs:
        stem = os.path.splitext(os.path.basename(p))[0]
        with io.open(p, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                r = json.loads(line)
                inst = str(r.get("instance", ""))
                if a.prefix:
                    inst = "%s::%s" % (stem, inst)
                    r["instance"] = inst
                seen[inst].add(stem)
                rows.append(r)

    clash = {i: sorted(s) for i, s in seen.items() if len(s) > 1}
    if clash:
        print("ERROR: instance id 가 여러 파일에 있다 (%d 개). --prefix 로 해소하라." % len(clash),
              file=sys.stderr)
        for i, s in list(clash.items())[:5]:
            print("  %s <- %s" % (i, s), file=sys.stderr)
        return 2

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with io.open(a.out, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    print("wrote %d rows / %d instances -> %s" % (len(rows), len(seen), a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
