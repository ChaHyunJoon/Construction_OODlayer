#!/usr/bin/env python3
"""zone 스윕 로그를 **세 축**으로 집계한다 (2026-09-05).

🔴 왜 세 축인가. 완주율 하나로 채점하면 세계의 교착이 합성 레인의 실패로 집계된다.
이 스윕에서 미완주 10판 중 6판은 `n_blocked=0 project_blocked=false` 였다 — 즉 tool 은
존을 다 치웠고 빌드는 **그 뒤에** 얼었다(오라클 대조 12판으로 원인을 가름:
공간수리 <=> 교착, 4/4 완전분리). 그 6판을 모델 탓으로 세면 숫자가 거짓말을 한다.

  축1  존이 치워졌나        n_blocked==0 and not project_blocked
  축2  빌드가 완주했나      complete
  축3  tool 이 안 던졌나    steps=[..:threw(..)] 없음

읽는 것은 `render_demo.jl` 이 완주/미완주 양쪽에서 찍는 `[score]` 한 줄과 `[minted]` 줄이다.
사용법:  python3 tools/monitor/sweep50_tally.py [glob]   (기본 results/sweep50-z*.log)
"""
import re, os, sys, glob as globmod, statistics
from collections import Counter

PAT = sys.argv[1] if len(sys.argv) > 1 else "results/sweep50-z*.log"

def load(p):
    s = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '',
               open(p, 'rb').read().decode('utf-8', 'replace')).replace('\r', '\n')
    sc = re.search(r'^\[score\] (.*)$', s, re.M)
    if not sc:                       # 아직 안 끝난 판. 진행 중을 실패로 세면 분모가 부푼다.
        return None
    sc = sc.group(1)
    fld = lambda k, d="?": (re.search(rf'{k}=([A-Za-z0-9._-]+)', sc).group(1)
                            if re.search(rf'{k}=([A-Za-z0-9._-]+)', sc) else d)
    g = lambda pat, d="": (re.search(pat, s).group(1) if re.search(pat, s) else d)
    thr = re.search(r':threw\(([^)]{0,110})', s)
    e = thr.group(1) if thr else ""
    return dict(
        z=int(re.search(r'z(\d+)\.log$', p).group(1)),
        comp=fld('complete') == 'true', closed=fld('closed'),
        nblk=fld('n_blocked'), eng=fld('n_engulfed'), trap=fld('n_agent_trapped'),
        pblk=fld('project_blocked') == 'true',
        tool=g(r'\[minted\] lane=\S+ tool=([A-Za-z0-9_!]+)'),
        noop='tool=no_intervention' in s,
        retry=g(r'enact_retry=([a-z_/]+)', 'n/a'),
        staged=g(r'n_staging_moved=(\d+)', '?'),
        err=('eligible_successors(환각)' if 'eligible_successors' in e else
             'NamedTuple 필드 없음'      if 'no field' in e else
             '모델 자신의 단언'           if e else ''),
        errtxt=e[:70],
        kind=g(r'\[zone\] blocking zone on (\w+)'),
        r=g(r'r=([0-9.]+) -> nav_blocked'), navb=g(r'nav_blocked=(\d+)/'),
        t=g(r'(?m)^real\s*(\S+)'))

rows = sorted((r for r in (load(p) for p in globmod.glob(PAT)) if r), key=lambda r: r['z'])
n = len(rows)
if not n:
    sys.exit(f"채점할 판이 없다: {PAT}")
ax1 = sum(1 for r in rows if r['nblk'] == '0' and not r['pblk'])
ax2 = sum(1 for r in rows if r['comp'])
ax3 = sum(1 for r in rows if not r['err'])

def cause(r):
    if r['err'] == 'eligible_successors(환각)': return '환각 예외(회복 불가)'
    if r['err']:                                return '자기 단언 실패'
    return '세계 교착(수리 성공 후)'

print(f"채점된 판 {n}")
print(f"| 축 | 결과 |\n|---|---|")
print(f"| ① 존이 치워졌나 | **{ax1}/{n} ({100*ax1/n:.0f}%)** |")
print(f"| ② 빌드가 완주했나 | **{ax2}/{n} ({100*ax2/n:.0f}%)** |")
print(f"| ③ tool 이 안 던졌나 | **{ax3}/{n} ({100*ax3/n:.0f}%)** |")

print(f"\n**예외 유형** {dict(Counter(r['err'] for r in rows if r['err']))}")
print(f"**재시도 결과** {dict(Counter(r['retry'] for r in rows if r['err']))}")
print(f"**무개입** {[r['z'] for r in rows if r['noop']]}   "
      f"**존 남음(n_blocked>0)** {[(r['z'], r['nblk'], r['pblk']) for r in rows if r['nblk'] != '0']}   "
      f"**갇힘** {[(r['z'], r['trap']) for r in rows if r['trap'] not in ('0', '?')]}")

print(f"\n### 미완주 {n-ax2}판\n")
print("| 시드 | closed | project_blocked | staged | retry | 원인 | 예외 |")
print("|---|---|---|---|---|---|---|")
for r in rows:
    if r['comp']: continue
    print(f"| z{r['z']} | {r['closed']} | {r['pblk']} | {r['staged']} | `{r['retry']}` | "
          f"{cause(r)} | {('`'+r['errtxt']+'`') if r['errtxt'] else '—'} |")

secs = []
for r in rows:
    m = re.match(r'(\d+)m([\d.]+)s', r['t'] or '')
    if m: secs.append(int(m.group(1))*60 + float(m.group(2)))
if secs:
    print(f"\n판당 {statistics.mean(secs)/60:.2f}분 (min {min(secs)/60:.2f} / max {max(secs)/60:.2f}), "
          f"총 {sum(secs)/3600:.2f}시간")
print(f"존 배치 kind={dict(Counter(r['kind'] for r in rows))} "
      f"r∈[{min(float(r['r']) for r in rows if r['r'])}, {max(float(r['r']) for r in rows if r['r'])}] "
      f"nav_blocked={dict(sorted(Counter(r['navb'] for r in rows).items()))}")
print(f"서로 다른 tool 이름 {len(set(r['tool'] for r in rows if r['tool']))}개")
print(f"\n### 전체\n")
print("| 시드 | 완주 | closed | n_blocked | engulfed | 예외 | 존 kind | r | nav_blocked | tool |")
print("|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    print(f"| z{r['z']} | {'✅' if r['comp'] else '❌'} | {r['closed']} | {r['nblk']} | {r['eng']} | "
          f"{'⚠️' if r['err'] else '—'} | {r['kind']} | {r['r']} | {r['navb']} | `{r['tool'] or 'no_intervention'}` |")
