#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""구간 후보별로 대량 생성 전에 봐야 할 3가지를 잰다.

  1) fault 가 실제로 터지는가        (늦으면 solo 타깃이 없어 0건이 된다)
  2) tau_to_next > 0 인가            (0 이면 '에피소드'가 아니라 동시사건이다)
  3) 동점률                          (모든 팔 비용이 같으면 결정정보 0)
이 셋을 동시에 만족하는 구간만 대량 생성에 쓸 가치가 있다.
"""
import glob, json, math, os, collections

COST_FAIL, COST_UNC, EPS = 10000.0, 100.0, 1e-3


def sc(r):
    mk = r.get("makespan", float("nan"))
    try:
        mk = float(mk)
    except Exception:
        mk = float("nan")
    if r.get("complete"):
        return mk if math.isfinite(mk) else COST_FAIL
    return (COST_FAIL + COST_UNC * (int(r.get("total", 0)) - int(r.get("closed", 0)))
            + EPS * (mk if math.isfinite(mk) else 0.0))


def main():
    files = sorted(glob.glob(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "oracle", "probe_*.jsonl")))
    files = [f for f in files if ".probes." not in f]
    by_cfg = collections.defaultdict(list)
    for f in files:
        cfg = os.path.basename(f)[len("probe_"):-len(".jsonl")].rstrip("b")
        for line in open(f, encoding="utf-8"):
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("macro") is None or not r.get("fired"):
                continue
            by_cfg[cfg].append(r)

    print(f"{'cfg':>6} {'inst':>5} {'fault':>6} {'battery':>8} {'zone':>5} "
          f"{'tau>0':>6} {'tau중앙':>8} {'동점':>6} {'결정적':>6}")
    for cfg, rows in sorted(by_cfg.items()):
        g = collections.defaultdict(list)
        for r in rows:
            g[r["instance"]].append(r)
        kinds = collections.Counter(v[0].get("kind") for v in g.values())
        taus = [r.get("tau_to_next") for r in rows
                if isinstance(r.get("tau_to_next"), (int, float)) and r["tau_to_next"] > 0]
        n_tie = 0
        n = 0
        for inst, rs in g.items():
            if len(rs) < 2:
                continue
            n += 1
            c = [sc(r) for r in rs]
            n_tie += (max(c) - min(c)) <= 1e-9
        med = sorted(taus)[len(taus) // 2] if taus else 0
        print(f"{cfg:>6} {n:>5} {kinds.get('fault',0):>6} {kinds.get('battery',0):>8} "
              f"{kinds.get('zoneblk',0):>5} {len(taus):>6} {med:>8} "
              f"{n_tie:>6} {n-n_tie:>6}")
    print()
    print("판정 기준: fault>0 이고 tau>0 이 있고 결정적 instance 비율이 가장 높은 구간을 쓴다.")
    print("셋 중 하나라도 0 이면 그 구간으로 대량 생성하면 안 된다(9시간을 버리게 된다).")


if __name__ == "__main__":
    main()
