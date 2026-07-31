#!/usr/bin/env python
"""Assemble the 100%-recoverable benchmark graded_hs_v2.jsonl:
  keep the recoverable instances from graded_hs_all.jsonl (battery, faultidle, zoneharm, fault_sp3)
  + replace fault_sp0 with regenerated fault_sp1 (Replace-required, completes)
  + replace zoneblk_sev0.9 with regenerated zone_off0 (recoverable under strong recovery)
Then verify every instance has >=1 completing macro (oracle completes 100%)."""
# =============================================================================
# assemble_v2.py — "100% 복구 가능한" 최종 벤치마크 graded_hs_v2.jsonl 조립 스크립트
# -----------------------------------------------------------------------------
# [이 파일이 하는 일]
#   여러 oracle 결과 파일을 합쳐 하나의 깨끗한 벤치마크 데이터셋을 만든다.
#   구체적으로:
#     1) base 파일(graded_hs_all.jsonl)에서 "복구 불가능(non-recoverable)"한 사례들을 뺀다.
#     2) 뺀 자리를 새로 재생성한 사례 파일(fault_sp1, zone_off0)로 채운다.
#     3) 결과를 instance 단위로 묶어 graded_hs_v2.jsonl로 저장한다.
#     4) 마지막에 모든 instance가 macro 중 최소 1개는 완주(complete)하는지 검증한다.
#        (= oracle가 100% 복구할 수 있는 사례들로만 데이터셋이 이뤄졌는지 확인)
#
# [프로젝트 맥락]
#   check_completion.py가 "진단"이라면, 이 스크립트는 그 진단을 통과하도록 데이터셋을
#   실제로 "조립"하는 단계다. 복구 불가능 사례가 섞이면 surrogate/LLM 비교 실험의 채점이
#   왜곡되므로, 여기서 오직 복구 가능한 사례만 남기는 것이 핵심이다.
#
# [실행 방법]
#   python assemble_v2.py
#   (경로는 아래 BASE/ADD/OUT 상수에 고정되어 있어 인자 없이 실행한다.
#    보통 oracle/ 상위 폴더에서 실행해야 상대경로가 맞는다.)
#   -> 성공(100% 복구)하면 종료코드 0, 아니면 1로 끝난다.
#
# [문법 참고 — 처음 보는 사람을 위해]
#   - OrderedDict: 삽입한 순서를 기억하는 dict. 여기선 "처음 등장한 순서대로" instance 목록을
#     중복 없이 뽑는 용도(dict의 key는 중복을 자동 제거하기 때문).
#   - str.startswith(튜플): 문자열이 튜플 안 접두어 중 하나로라도 시작하면 True.
#   - 리스트 컴프리헨션 [x for x in ... if 조건]: 조건에 맞는 값만 모아 새 리스트 생성.
#   - sys.exit(코드): 프로그램을 즉시 종료(0=성공, 그 외=실패). CI/자동화에서 통과 판정에 쓴다.
# =============================================================================
import json, sys
from collections import defaultdict, OrderedDict

BASE = "oracle/out/graded_hs_all.jsonl"  # 시작점이 되는 전체 oracle 결과 파일.
ADD = ["oracle/out/fix100/fault_sp1.jsonl", "oracle/out/fix100/zone_off0.jsonl"]  # 뺀 자리를 채울 재생성 파일들.
OUT = "oracle/out/graded_hs_v2.jsonl"  # 최종 출력 벤치마크 파일 경로.

# instances to DROP from base (non-recoverable), replaced by the regenerated ones
# base에서 제거할 instance들의 이름 접두어. 이 접두어로 시작하는 사례는 복구 불가라 빼고,
# 위 ADD 파일의 재생성 사례로 대체한다.
DROP_PREFIXES = ("fault_s1_sev1.0_sp0", "fault_s2_sev1.0_sp0",
                 "zoneblk_s1_sev0.9_sp3", "zoneblk_s2_sev0.9_sp3")


# jsonl 파일 한 개를 읽어 dict들의 리스트로 반환. 빈 줄은 건너뛴다.
def load(path):
    return [json.loads(l) for l in open(path) if l.strip()]


# base를 읽되, DROP_PREFIXES로 시작하는(=복구 불가) 사례의 row는 제외하고 남긴다.
rows = [r for r in load(BASE) if not r["instance"].startswith(DROP_PREFIXES)]
n_base = len(set(r["instance"] for r in rows))  # set으로 중복 제거 -> 남은 base 사례 "개수".
added = []  # 새로 추가된 instance 이름을 기록(마지막 출력용).
for p in ADD:
    ar = load(p)                                   # 재생성 파일 하나를 읽고,
    rows += ar                                     # 전체 row 목록에 이어붙이고,
    added += sorted(set(r["instance"] for r in ar))  # 그 파일이 추가한 instance 이름들을 모은다.
# write, grouped by instance (stable order: base order then added)
# 출력 순서 정하기: instance가 "처음 등장한 순서"를 유지한다(base 먼저, 그다음 added).
# OrderedDict의 key는 중복을 자동 제거하므로, 같은 instance가 여러 row여도 이름은 한 번만 남는다.
order = list(OrderedDict((r["instance"], None) for r in rows).keys())
by = defaultdict(list)  # instance 이름 -> 그 사례의 row 리스트.
for r in rows:
    by[r["instance"]].append(r)
with open(OUT, "w") as f:
    for inst in order:                                   # 정해진 순서대로 instance를 돌며,
        for r in sorted(by[inst], key=lambda r: r["macro"]):  # 내부는 macro id 순으로 정렬해
            f.write(json.dumps(r) + "\n")                # 한 줄에 JSON 하나씩(jsonl) 기록.

# verify recoverability
# 여기서부터는 방금 만든 데이터셋이 정말 "100% 복구 가능"한지 재검증한다.
MN = {0: "NOOP", 1: "Replace", 2: "Deprio", 3: "Forbid", 4: "Reform"}  # macro id -> 이름.
n_rec = 0  # 복구 가능한 사례 개수.
print(f"assembled {OUT}: {len(by)} instances, {len(rows)} rows")
print(f"  kept {n_base} recoverable base instances; added {added}")
print(f"\n{'instance':<30}{'sp':>3} {'ov':>6}  status  best/per-macro")  # 표 헤더.
for inst in order:
    rs = sorted(by[inst], key=lambda r: r["macro"])  # 사례 내부를 macro 순으로 정렬.
    anyc = any(r["complete"] for r in rs)            # 하나라도 완주하면 True.
    n_rec += anyc                                    # True=1로 개수에 누적.
    ov = rs[0].get("zone_overlap")                   # 구역 겹침 비율(없으면 None).
    # macro별 결과 요약: "이름:C또는x + closed수". C=완주, x=미완주.
    cells = " ".join(f"{MN[r['macro']]}:{'C' if r['complete'] else 'x'}{r['closed']}" for r in rs)
    flag = "" if anyc else "  <-- NON-RECOVERABLE"   # 복구 불가 사례면 경고 표식.
    ovs = "-" if ov is None else f"{float(ov):.2f}"  # 겹침 비율을 표에 예쁘게(None이면 "-").
    print(f"  {inst:<30}{rs[0]['n_spare_cfg']:>3} {ovs:>6}  {'REC' if anyc else 'NO ':<5} {cells}{flag}")
print(f"\nORACLE COMPLETION (>=1 macro completes): {n_rec}/{len(by)} = {n_rec/len(by):.0%}")
# 모든 사례가 복구 가능하면 성공(0), 하나라도 아니면 실패(1)로 종료.
# -> 자동화 파이프라인에서 "데이터셋이 조건을 만족했는가"를 종료코드로 판단할 수 있다.
sys.exit(0 if n_rec == len(by) else 1)
