#!/usr/bin/env python
"""
diag_stall.py -- 완주 실패의 **죽는 방식**을 모니터 스트림에서 특징짓는다 (새 시뮬 불필요).

왜 이 도구가 필요한가.
  오라클 덤프의 raw_* 는 **결정 순간**의 스냅샷이라 "그 뒤에 무슨 일이 있었는지"를 말해주지 않는다.
  모니터 스트림은 프레임마다 로봇의 mode/pos/action 을 남기므로, 정지 직전 구간을 보면
  "누가, 어디서, 무엇을 하다가 멈췄는가"를 직접 읽을 수 있다.

지금 답하려는 질문(2026-08-04): nominal 은 100% 완주하고 fault/battery 는 38% 완주하는데
zone 사건만 0% 다. **zone 이 무엇을 막아서 빌드가 죽는가?**

가설과 판정 기준
  H1 rim-wait : TangentBug 가 구역 경계에서 영구 대기한다.
        -> 얼어붙은 로봇의 상당수가 |dist(로봇, 구역중심) - 구역반지름| < 로봇반지름 근처에 몰린다.
  H2 목표가 구역 안 : 가야 할 목표 자체가 구역 안이라 도달 불가.
        -> 얼어붙은 로봇의 목표(action)가 구역 내부를 가리킨다(스트림에 goal 이 있으면).
  H3 팀 교착   : 구역과 무관하게 운반팀이 형성 실패로 멈춘다(fault/battery 판과 같은 사인).
        -> 얼어붙은 로봇이 구역에서 멀고 CARRY/전이 대기 상태에 몰린다.

  세 가설은 배타적이지 않다. 이 스크립트는 **어디에 얼마나 몰렸는지 세기만** 하고 결론은 사람이 낸다.

  python diag_stall.py tools/monitor/streams/tractor__zonecore_gpt41.jsonl
"""
import sys, os, json, math, argparse, collections

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROBOT_R = 0.14   # default_robot_radius() (tractor twin). rim 근접 판정의 자 단위.


def load(path):
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return out


def _pos(r):
    p = r.get("pos")
    if isinstance(p, (list, tuple)) and len(p) >= 2:
        try:
            return float(p[0]), float(p[1])
        except (TypeError, ValueError):
            return None
    return None


def zones_of(frame):
    """프레임에 실려 있는 활성 구역들 -> [(cx, cy, r, key)]."""
    out = []
    for o in (frame.get("ood") or []):
        if str(o.get("kind")) != "zone":
            continue
        c = o.get("center")
        rad = o.get("radius")
        if isinstance(c, (list, tuple)) and len(c) >= 2 and rad is not None:
            try:
                out.append((float(c[0]), float(c[1]), float(rad), str(o.get("zone"))))
            except (TypeError, ValueError):
                pass
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("--tail", type=int, default=8, help="정지 판정에 쓸 마지막 프레임 수")
    ap.add_argument("--eps", type=float, default=1e-3, help="이 거리 미만 움직임 = 정지")
    a = ap.parse_args()

    fr = load(a.stream)
    if not fr:
        print("빈 스트림"); return
    print(f"프레임 {len(fr)}   closed {fr[0].get('n_closed')} -> {fr[-1].get('n_closed')}")

    tail = fr[-a.tail:] if len(fr) >= a.tail else fr
    print(f"정지 판정 구간: 마지막 {len(tail)} 프레임 "
          f"(closed {tail[0].get('n_closed')} -> {tail[-1].get('n_closed')})")

    zs = zones_of(fr[-1])
    print(f"활성 구역 {len(zs)}: " + (", ".join(f"{k}@({cx:.2f},{cy:.2f}) r={r:.3f}"
                                               for cx, cy, r, k in zs) or "(없음)"))

    # 로봇별 tail 구간 이동량
    track = collections.defaultdict(list)
    for f in tail:
        for r in (f.get("robots") or []):
            p = _pos(r)
            if p:
                track[str(r.get("id"))].append((p, str(r.get("mode")), str(r.get("action") or "")))

    # 스트림 **전체**에서의 이동량도 잰다. 이게 없으면 주차된 예비 로봇(처음부터 끝까지 안 움직임)이
    # "얼어붙음"으로 잡혀 신호를 덮는다 — 실제로 **완주한 대조군에서도 8대가 얼어붙음**으로 나왔다.
    # 진짜 신호는 "움직이다가 멈춘" 로봇이다.
    whole = collections.defaultdict(list)
    for f in fr:
        for r in (f.get("robots") or []):
            pp = _pos(r)
            if pp:
                whole[str(r.get("id"))].append(pp)

    frozen, moving, parked = [], [], []
    for rid, seq in track.items():
        if len(seq) < 2:
            continue
        d = sum(math.dist(seq[i][0], seq[i + 1][0]) for i in range(len(seq) - 1))
        if d >= a.eps:
            moving.append((rid, d, seq[-1]))
            continue
        w = whole.get(rid, [])
        dw = sum(math.dist(w[i], w[i + 1]) for i in range(len(w) - 1)) if len(w) > 1 else 0.0
        (parked if dw < a.eps else frozen).append((rid, d, seq[-1]))

    print(f"\n로봇 {len(track)}대  ·  움직임 {len(moving)}  ·  "
          f"**움직이다 멈춤 {len(frozen)}**  ·  처음부터 정지(주차 예비 등) {len(parked)}")

    modes = collections.Counter(s[2][1] for s in frozen)
    print("얼어붙은 로봇의 mode 분포:", dict(modes) or "(없음)")

    if zs and frozen:
        near_rim, inside, outside = 0, 0, 0
        rows = []
        for rid, d, (p, mode, act) in frozen:
            best = min(zs, key=lambda z: abs(math.dist(p, (z[0], z[1])) - z[2]))
            cx, cy, rr, key = best
            dist = math.dist(p, (cx, cy))
            gap = dist - rr                       # 음수 = 구역 안
            if abs(gap) < ROBOT_R:
                near_rim += 1; tag = "RIM"
            elif gap < 0:
                inside += 1; tag = "INSIDE"
            else:
                outside += 1; tag = "outside"
            rows.append((tag, rid, dist, gap, mode, act))
        n = len(frozen)
        print(f"\n구역 기준 위치:  RIM 근접 {near_rim} ({100*near_rim/n:.0f}%)  ·  "
              f"구역 안 {inside}  ·  구역 밖 {outside}")
        print("\n  판정        로봇                       d(중심)   여유    mode     action")
        for tag, rid, dist, gap, mode, act in sorted(rows, key=lambda t: abs(t[3]))[:14]:
            short = rid.split("(")[-1].rstrip(")")
            print(f"  {tag:<9} bot#{short:<20} {dist:7.3f} {gap:+7.3f}  {mode:<8} {act[:44]}")

        print("\n판정 힌트:")
        if near_rim >= max(1, n // 2):
            print("  H1(rim-wait) 지지 — 얼어붙은 로봇의 절반 이상이 구역 경계에 몰려 있다.")
        elif outside >= max(1, n // 2):
            print("  H3(팀 교착) 쪽 — 얼어붙은 로봇 대부분이 구역과 무관한 곳에 있다.")
        else:
            print("  혼재 — 단일 원인으로 보기 어렵다.")
    elif frozen:
        print("\n활성 구역이 스트림에 없어 위치 판정 생략(H3만 가능).")

    acts = collections.Counter(s[2][2].split("·")[0].strip() for s in frozen)
    print("\n얼어붙은 로봇이 물고 있던 작업 종류:", dict(acts) or "(없음)")


if __name__ == "__main__":
    main()
