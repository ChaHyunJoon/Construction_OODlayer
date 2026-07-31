#!/usr/bin/env python
"""Summarize per-instance recoverability of an oracle jsonl: does >=1 macro complete?
Usage: python check_completion.py <file.jsonl> [more.jsonl ...]"""
# =============================================================================
# check_completion.py — oracle 결과(jsonl)의 "복구 가능성(recoverability)" 요약 스크립트
# -----------------------------------------------------------------------------
# [이 파일이 하는 일]
#   oracle가 만든 결과 파일(.jsonl)을 읽어서, 각 OOD "instance(사례)"마다
#   5개 macro(복구 행동) 중 최소 1개라도 빌드를 "완주(complete)"시키는지 확인한다.
#   최소 1개라도 완주하면 그 사례는 "복구 가능(recoverable)"으로 센다.
#
# [프로젝트 맥락]
#   ConstructionBots는 여러 로봇이 우주선을 조립하는 TAMP 시뮬레이터다.
#   빌드 도중 예상 밖 사건(OOD: 로봇 고장/배터리 방전/통행금지 구역 등)이 터지면
#   LLM/surrogate "re-spec" 레이어가 복구 macro(NOOP/Replace/Deprio/Forbid/Reform)를 고른다.
#   이 스크립트는 벤치마크 데이터셋이 "애초에 복구 가능한 사례들로만" 이루어졌는지
#   눈으로 확인하기 위한 진단용 도구다.
#
# [실행 방법]
#   python check_completion.py <file.jsonl> [more.jsonl ...]
#   -> 여러 개의 jsonl 경로를 한 번에 받아 각각 요약을 출력한다.
#
# [문법 참고 — 처음 보는 사람을 위해]
#   - defaultdict(list): 없는 key를 처음 접근할 때 자동으로 빈 리스트를 만들어 주는 dict.
#     그래서 by[key].append(...)를 곧바로 써도 KeyError가 안 난다.
#   - json.loads(문자열): JSON 한 줄을 파이썬 dict로 변환. (jsonl = 한 줄에 JSON 하나)
#   - for l in open(path): 파일을 한 줄씩 순회. 각 줄 l은 문자열이다.
#   - f"...{변수}...": f-string(문자열 안에 변수/식을 {}로 끼워 넣는 문법).
#   - any(...): 반복 가능한 값 중 하나라도 참이면 True. (여기선 True를 1로 더해 개수 셈)
# =============================================================================
import sys, json
from collections import defaultdict
# macro id(정수) -> 사람이 읽는 이름. 출력할 때 숫자 대신 이 이름을 보여준다.
MN = {0: "NOOP", 1: "Replace", 2: "Deprio", 3: "Forbid", 4: "Reform"}
# sys.argv[1:] = 커맨드라인으로 넘어온 파일 경로들(첫 원소 argv[0]은 스크립트 이름이라 건너뜀).
for path in sys.argv[1:]:
    by = defaultdict(list)  # instance 이름 -> 그 사례의 결과 row(dict) 리스트로 묶는다.
    for l in open(path):    # jsonl 파일을 한 줄씩 읽는다.
        if l.strip():       # 빈 줄(공백만 있는 줄)은 건너뛴다.
            r = json.loads(l); by[r["instance"]].append(r)  # 한 줄 파싱 후 해당 instance 그룹에 추가.
    n_rec = 0  # 복구 가능한 사례 개수 카운터.
    print(f"\n=== {path} : {len(by)} instances ===")  # 이 파일의 총 instance 수 헤더 출력.
    # instance 이름 순으로 정렬해 하나씩 요약한다.
    for inst, rs in sorted(by.items()):
        rs = sorted(rs, key=lambda r: r["macro"])  # 같은 사례 내부는 macro id(0~4) 순으로 정렬.
        anyc = any(r["complete"] for r in rs)      # macro 중 하나라도 완주했으면 True.
        n_rec += anyc                              # True(=1)/False(=0)라서 그대로 개수에 더해짐.
        ov = rs[0].get("zone_overlap")             # 통행금지 구역이 겹친 비율(없으면 None).
        # 각 macro의 결과를 "이름:완주여부+closed수" 형태로 이어붙인 요약 문자열.
        #   'C' = 완주(complete), 'x' = 미완주. r['closed']는 닫힌 빌드스텝 수.
        cells = " ".join(f"{MN[r['macro']]}:{'C' if r['complete'] else 'x'}{r['closed']}" for r in rs)
        flag = "" if anyc else "  <-- NON-RECOVERABLE"  # 하나도 완주 못 하면 경고 표식.
        try:
            # sp=스페어 로봇 설정 수, ov=구역 겹침 비율(None이면 그대로, 아니면 소수 둘째자리 반올림).
            print(f"  {inst:<30} sp={rs[0]['n_spare_cfg']} ov={ov if ov is None else round(float(ov),2)}  "
                  f"{'REC' if anyc else 'NO '}  {cells}{flag}")
        except Exception:  # 어떤 key가 없어 포맷이 실패해도 스크립트가 죽지 않게 최소 정보만 출력.
            print(f"  {inst}: any={anyc}")
    # 이 파일 전체 요약: 복구 가능 비율. max(len(by),1)로 0으로 나누기(division by zero) 방지.
    print(f"  recoverable: {n_rec}/{len(by)} = {n_rec/max(len(by),1):.0%}")
