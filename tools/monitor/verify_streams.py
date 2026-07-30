#!/usr/bin/env python
"""
verify_streams.py -- 녹화 스트림 무결성 검사.

무엇을 잡는가
-------------
  V1  JSONL 각 줄이 유효한 JSON 인가
      깨진 줄은 대시보드(parseJSONL)가 **조용히 건너뛴다**. 그래서 프레임이 하나 사라져도
      화면상으로는 티가 안 난다 -- 조용해서 더 위험하다. 실제로 렌더가 도는 중에 파일을
      cp 로 덮어써서 두 프레임이 한 줄에 섞인 적이 있다(fault_zone__dspy 10번째 줄).
  V2  화면에 표시되는 한글이 남아 있는가 (UI 는 영어로 통일)
  V3  프레임이 아예 없는(0바이트/빈) 파일인가
  V4  결정(respec_history)이 있는 녹화에 router 판정이 실려 있는가
      -- 없으면 라우터 배선 이전의 옛 녹화다(치명적이진 않지만 화면에서 ROUTER 줄이 빈다)

사용법:  python tools/monitor/verify_streams.py [glob]
         python tools/monitor/verify_streams.py "tractor__*__*.jsonl"
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STREAMS = os.path.join(HERE, "streams")
HANGUL = re.compile(r"[가-힣]")

pat = sys.argv[1] if len(sys.argv) > 1 else "tractor__*.jsonl"
files = sorted(glob.glob(os.path.join(STREAMS, pat)))

bad_total = 0
print("%-46s %7s %7s %7s %s" % ("stream", "frames", "broken", "hangul", "router"))
print("-" * 92)
for p in files:
    frames = broken = han = 0
    hist = None
    for line in open(p, encoding="utf-8"):
        if not line.strip():
            continue
        if HANGUL.search(line):
            han += 1
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            broken += 1
            continue
        frames += 1
        if d.get("respec_history"):
            hist = d["respec_history"]

    if hist is None:
        router = "-"                      # OOD 가 없는 케이스(none)
    else:
        has = all((h.get("input") or {}).get("router") for h in hist)
        router = "ok" if has else "MISSING"

    flag = ""
    if broken or han or frames == 0 or router == "MISSING":
        flag = "   <-- 확인 필요"
        bad_total += 1
    print("%-46s %7d %7d %7d %s%s"
          % (os.path.basename(p), frames, broken, han, router, flag))

print()
if bad_total == 0:
    print("%d files — 이상 없음" % len(files))
else:
    print("%d files — 문제 %d 건" % (len(files), bad_total))
sys.exit(1 if bad_total else 0)
