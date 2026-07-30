#!/usr/bin/env python
"""
anglicize_streams.py -- 이미 녹화된 스트림에 남은 **화면 표시용 한글 문구**를 영어로 바꾼다.

왜 필요한가
-----------
대시보드의 문구는 두 곳에서 온다.
  (1) dashboard.html 안의 문자열  -> 파일만 고치면 즉시 반영된다
  (2) 스트림 JSONL 안에 **기록된** 문자열 -> 녹화 시점의 코드가 만든 것이라, 코드를 고쳐도
      이미 만든 녹화에는 그대로 남는다. ROUTER 줄의 `reason` 이 그렇다.

24 개 녹화를 다시 돌리면 2.5 시간이므로, 표시용 문자열만 제자리에서 바꾼다.
**측정값은 건드리지 않는다** -- 바꾸는 것은 사람이 읽는 설명 문구 하나뿐이고, 그 문자열은
어떤 계산에도 쓰이지 않는다(대시보드가 화면에 그대로 찍기만 한다).

안전장치: 한 줄씩 바꾸고 **바꾼 줄이 여전히 유효한 JSON 인지 확인**한다. 하나라도 깨지면
그 파일은 원본을 유지하고 건너뛴다.

사용법:  python tools/monitor/anglicize_streams.py            # 검사만
         python tools/monitor/anglicize_streams.py --write    # 실제로 바꿈
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STREAMS = os.path.join(HERE, "streams")

# (녹화에 남은 한글, 대체할 영어). 코드 쪽 원본은 policy.jl 의 route() 에 있다.
SUBS = [
    (re.compile(r"\(참고용 판정 — 이 녹화는 DEMO_POLICY=([a-z]+) 고정 실행\)"),
     r"(advisory only — this recording enacted DEMO_POLICY=\1, fixed)"),
]
HANGUL = re.compile(r"[가-힣]")


def fix_file(path, write):
    changed, bad = 0, 0
    out = []
    for line in open(path, encoding="utf-8"):
        orig = line
        for pat, rep in SUBS:
            line = pat.sub(rep, line)
        if line != orig:
            try:
                json.loads(line)          # 바꾼 줄이 여전히 유효한 JSON 인가
                changed += 1
            except json.JSONDecodeError:
                line, bad = orig, bad + 1  # 깨졌으면 원본 유지
        out.append(line)
    left = sum(1 for l in out if HANGUL.search(l))
    if changed and write and not bad:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(out)
        os.replace(tmp, path)
    return changed, bad, left


def running_render_guard(files, force):
    """렌더가 도는 중에 스트림을 건드리면 **파일이 깨진다.**

    render_demo.jl 은 고정 이름 tractor__<case>.jsonl 에 프레임을 이어붙인다. 그 파일을 같은 순간에
    통째로 덮어쓰면 두 프레임이 한 줄에 섞여 들어간다. 실제로 그렇게 만들었다:
    fault_zone__dspy 의 10번째 줄이 `..."robot":"Constru{"now":12.525,...` 로 깨졌다
    (쓰던 중간에 새 프레임이 끼어든 흔적). 대시보드는 깨진 줄을 건너뛰므로 조용히 한 프레임을 잃는다
    -- 조용해서 더 나쁘다.

    그래서 **최근에 쓰인 파일이 있으면 멈춘다.** 렌더가 끝난 뒤에 돌리면 된다.
    """
    # 판정 방법을 두 번 바꿨다. 남기는 이유: 둘 다 그럴듯한데 둘 다 틀렸다.
    #   ① 파일 mtime 이 최근인가  -> 렌더는 프레임을 **띄엄띄엄**(수 초 간격) 쓰므로 그 사이에
    #                               그냥 통과한다. 실제로 통과해서 파일을 깨뜨렸다.
    #   ② julia 프로세스가 있는가 -> 대시보드 서버(server.jl)도 julia 다. 서버가 떠 있으면
    #                               영원히 막힌다. 데모 중에는 서버가 늘 떠 있으므로 쓸모없다.
    # 그래서 **파일이 실제로 자라는지**를 본다: 크기/수정시각을 두 번 재서 변하면 writer 가 있다.
    # 최근 30초 안에 수정된 파일도 위험 신호로 함께 본다(막 쓰고 잠깐 쉬는 구간).
    import time
    if force:
        return True

    def snap():
        s = {}
        for f in files:
            try:
                st = os.stat(f)
                s[f] = (st.st_size, st.st_mtime)
            except OSError:
                pass
        return s

    now = time.time()
    recent = [f for f in files if now - os.path.getmtime(f) < 30]
    a = snap()
    time.sleep(8)                      # 프레임 간격(수 초)보다 넉넉히 길게
    b = snap()
    growing = [f for f in a if f in b and a[f] != b[f]]

    hot = growing or recent
    if hot:
        print("!! 지금 쓰이고 있는 스트림이 있습니다:")
        for f in hot[:5]:
            why = "커지는 중" if f in growing else "방금 수정됨"
            print("     %-46s (%s)" % (os.path.basename(f), why))
        print("   렌더가 도는 중에 고치면 프레임이 섞여 파일이 깨집니다. 끝난 뒤 다시 실행하세요.")
        print("   (강행: --force)")
        return False
    return True


def main():
    write = "--write" in sys.argv
    files = sorted(glob.glob(os.path.join(STREAMS, "tractor__*.jsonl")))
    if write and not running_render_guard(files, "--force" in sys.argv):
        sys.exit(2)
    tot_c = tot_b = tot_l = 0
    for p in files:
        c, b, l = fix_file(p, write)
        tot_c += c; tot_b += b; tot_l += l
        if c or b or l:
            print("  %-46s changed=%-5d json깨짐=%-3d 남은한글줄=%d"
                  % (os.path.basename(p), c, b, l))
    print("\n%d files | 바꾼 줄 %d | JSON 깨진 줄 %d | 여전히 한글인 줄 %d"
          % (len(files), tot_c, tot_b, tot_l))
    if not write:
        print("--write 를 붙이면 실제로 적용합니다")
    sys.exit(1 if tot_b else 0)


if __name__ == "__main__":
    main()
