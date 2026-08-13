#!/usr/bin/env python
"""
overnight_mdp.py -- MDP 로드맵 STEP 2~5 의 분석 단계를 한 번에 수행하는 야간 파이프라인.
  (설계: MDP_DESIGN_FROM_SCRATCH.md.  STEP 6 은 별도 Julia 시뮬이 필요해 overnight.sh 가 돌린다.)

단계
  A. 집계    : mcds_*.jsonl (rollout 단위) -> (instance, macro) 당 Q̂ / SE / P(complete)
  B. 선별    : admissibility 를 **P(complete) 격차**로도 건다 (STEP 2 의 교훈)
  C. T1      : 조건부 라벨분산 검정 — φ 가 충분통계인가를 반증 가능하게 측정
  D. T2      : 이력 추가 regret 검정 (이 데이터에서 가능한 범위까지만; 불가하면 그 이유를 적는다)
  E. Router  : §9 VoI 정지규칙 — surrogate 로 끝낼지, 비싼 오라클을 부를지를 **유도된 규칙**으로 결정

설계 원칙: 모든 단계는 독립적으로 try/except 로 감싸 실패해도 다음 단계로 넘어가고, 부분 결과를
JSON 으로 남긴다. 사람이 자는 동안 도는 스크립트가 한 군데서 멈춰 전부 날리면 안 된다.

실행: python overnight_mdp.py [--glob=oracle/out/mcds_*.jsonl] [--out=artifacts_mdp]
"""
import sys, os, json, glob, math, traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np
import objective          # 목적함수 상수·J 의 단일 진실원 (objective.json; spec §5)

HERE = os.path.dirname(os.path.abspath(__file__))
OUTDIR = os.path.join(HERE, "artifacts_mdp")

# 유한벌점 SSP 비용 — gen_oracle_mc.jl 의 scalar_cost 와 **같은 정의**여야 한다.
# [2026-08-13] 그 "같아야 한다"를 주석이 아니라 코드로 만든다: 값의 출처는 objective.json 하나다.
# 이 세 상수는 하위호환용 별칭이고(이름으로 읽는 코드가 있을 수 있다), J 는 objective 가 계산한다.
COST_FAIL = float(objective.load()["C_fail"])
COST_UNCLOSED = float(objective.load()["C_unclosed"])
COST_TIE_EPS = float(objective.load()["tie_eps"])


def scalar_cost(r):
    """행 하나의 J (spec §3). gen_oracle_mc.scalar_cost 와 **같은 함수**를 부른다.

    [2026-08-13] 예전에는 이 식을 여기 통째로 복붙해 두었다(리터럴 상수 포함) — 목적함수
    상수의 다섯 번째 복사본이었고, 이름이 `scalar_cost` 라 cost_lex_key 를 찾는 감사에도
    안 잡혔다. 달라진 동작 두 가지, 둘 다 spec §5 가 요구하는 방향이다:
      - 완주 런에 w_E·energy_J 가 더해진다(§3.1). energy_J 가 없으면 ObjectiveError —
        구세대 mcds 덤프에 신세대 J 를 적용하려는 시도이므로 조용히 넘기지 않는다(§7).
      - 완주인데 makespan 이 비유한이면 예전엔 조용히 COST_FAIL 을 돌려줬다. 이제는
        ObjectiveError 다 — "완주했다는데 시간이 없다"는 장부 모순이지 비용이 아니다."""
    return objective.J_row(r)


def _is_state_feature(k):
    """φ 에 넣어도 되는(=결정 시점에 관측 가능한) 특징인가.

    에피소드 행의 `next_*` 는 s_{t+1} 스냅샷이라 **결정을 내린 뒤에야** 관측된다.
    φ 에 넣으면 모델이 미래를 보고 답을 맞히게 되어 T1 도 Router 도 무의미해진다.
    """
    return not str(k).startswith("next_")


# φ 에서 제외할 열. **한 곳에만 정의한다** — 예전에 이 집합을 두 함수 안에 각각 복제했다가
# 한쪽만 고쳐서 두 단계가 서로 다른 φ 로 돌아간 적이 있다.
BAN = {"q_cost", "q_se", "closed", "complete", "makespan", "total", "p_complete",
       "n_rollout", "hz_break", "hz_cell", "hz_zone", "hz_pending", "hz_sim_s",
       "hz_events_mean", "label_seconds", "min_soc", "n_stalled", "rollout", "hz_seed",
       "ctrl_complete", "ctrl_closed", "ctrl_makespan", "seed",
       # --- 결정 이후에만 알 수 있는 값 (미래 누출) -----------------------------------------
       "tau_to_next", "n_decisions", "done", "closed_at_decision", "episode",
       # --- 이력 요약은 상태가 아니다 -------------------------------------------------------
       # decision_idx = "이 에피소드에서 몇 번째 결정인가" = 과거 사건 수의 요약. φ 에 두면
       # T2("이력을 더하면 나아지는가")가 이미 이력을 쥔 채 시작하게 되어 검정이 무의미해진다.
       "decision_idx", "target_id", "xt_found"}
T2_BAN = BAN

# φ 에 결측이 있을 때 채우는 값. **0.0 이 아니라 -1.0** 이다.
# 이유: 이 코드베이스의 "해당없음" 규약이 -1 이고(agent_pending, xt_*), 무엇보다 0.0 은
# 어떤 열에서는 **유효한 값**이다 — soc=0.0 은 "배터리 방전" 이라는 뜻이라, 결측을 0 으로
# 채우면 모델에게 "이 로봇은 방전됐다"고 거짓말하게 된다.
NA_FILL = -1.0


def phi_columns(rows, extra_ban=()):
    """φ 열 목록을 **모든 행의 합집합**에서 만든다.

    왜 합집합인가 (2026-08-02 에 실제로 밟은 버그):
      예전에는 `rows[0].items()` 한 행만 보고 열을 정했다. 그런데 첫 instance 가 zoneblk
      사건이라 배터리 계층이 꺼져 있으면 그 행에는 `soc`/`xg_soc_*` 가 아예 없다.
      그러면 66행 중 38행이 갖고 있는 **함대 SoC 블록 전체가 φ 에서 조용히 사라진다**.
      배터리 OOD 의 정답을 가르는 바로 그 양이 빠진 채로 T1/Router 를 돌린 셈이다.
      열 목록이 "첫 행이 무엇이냐"에 따라 달라지면 실험은 재현되지 않는다.
    """
    ban = set(BAN) | set(extra_ban)
    seen = {}
    for r in rows:
        for k, v in r.items():
            if k in ban or k == "macro" or not _is_state_feature(k):
                continue
            if str(k).startswith("hist_"):
                continue
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                seen[k] = seen.get(k, 0) + 1
    return sorted(seen), seen


def design_matrix(rows, cols):
    """행렬 X = [φ | a]. 결측은 NA_FILL, 비유한값도 NA_FILL 로 접는다."""
    X = np.array([[_num(r.get(c)) for c in cols] + [float(r["macro"])] for r in rows], float)
    return np.nan_to_num(X, nan=NA_FILL, posinf=NA_FILL, neginf=NA_FILL)


def _num(v):
    if v is None or isinstance(v, bool) or not isinstance(v, (int, float)):
        return NA_FILL
    return float(v) if math.isfinite(float(v)) else NA_FILL


# ==========================================================================================
#  X_C (커밋먼트) / X_G (기하) 서술자  — 2026-08-02
# ==========================================================================================
# 왜: 96 instance T1 에서 φ 가 완주 여부조차 다수결 기준선만큼(0.755 vs 0.745)밖에 못 맞혔다.
# 당시 φ 15개는 전부 집계 스칼라였고, 설계 §2 가 상태의 필수 블록이라 못 박은 X_C(누가 무엇에
# 묶였고 얼마나 진행됐나)와 X_G(로봇·부품이 물리적으로 어디 있나)가 통째로 빠져 있었다.
# 같은 "로봇 1대 고장"이라도 그 로봇이 유휴인지 화물을 절반 옮긴 상태인지에 따라 NOOP 의 값이
# 완전히 달라지는데, 그 차이를 담은 축이 φ 에 없었다.
#
# 원칙: Julia 는 원자료(raw_*)만 덤프하고, 서술자는 **여기서** 계산한다. 정의를 바꿔도 재시뮬이
# 아니라 재계산이면 된다.
_MODE_ORD = {"IDLE": 0.0, "TRANSIT": 1.0, "MANIPULATE": 2.0, "CARRY": 3.0}


def _fin(a):
    a = np.asarray(a, float)
    return a[np.isfinite(a)]


def derive_state_descriptors(r):
    """raw_* 평행벡터 -> 결정 시점에 관측 가능한 스칼라 서술자. 없으면 빈 dict(구 데이터 호환)."""
    rid = r.get("raw_robot_id") or []
    if not rid:
        return {}
    n = len(rid)
    d = {}
    mode = r.get("raw_robot_mode") or []
    rx = np.asarray(r.get("raw_robot_x") or [np.nan] * n, float)
    ry = np.asarray(r.get("raw_robot_y") or [np.nan] * n, float)
    gx = np.asarray(r.get("raw_robot_goal_x") or [np.nan] * n, float)
    gy = np.asarray(r.get("raw_robot_goal_y") or [np.nan] * n, float)
    soc = np.asarray(r.get("raw_robot_soc") or [np.nan] * n, float)
    spares = set(r.get("raw_spare_id") or [])

    # ---- X_C: 함대가 지금 얼마나 "묶여" 있는가 = 개입이 깨뜨릴 커밋먼트의 총량 ----------------
    if mode:
        d["xc_idle_frac"] = float(np.mean([m == "IDLE" for m in mode]))
        d["xc_carry_frac"] = float(np.mean([m == "CARRY" for m in mode]))
        d["xc_transit_frac"] = float(np.mean([m == "TRANSIT" for m in mode]))
        d["xc_manip_frac"] = float(np.mean([m == "MANIPULATE" for m in mode]))
    # 남은 이동거리 합 = 이미 착수한 일의 잔여량(전환비용의 직접 대리치)
    dist = np.hypot(gx - rx, gy - ry)
    fd = _fin(dist)
    d["xc_inflight_dist_sum"] = float(fd.sum()) if fd.size else 0.0
    d["xc_inflight_dist_max"] = float(fd.max()) if fd.size else 0.0
    d["xc_n_committed"] = float(fd.size)

    # ---- 사건 대상 로봇 본인의 커밋먼트 — 무해/유해를 가르는 **핵심 축** ----------------------
    tgt = int(r.get("target_id", -1) or -1)
    ti = rid.index(tgt) if tgt in rid else -1
    d["xt_found"] = 1.0 if ti >= 0 else 0.0
    d["xt_mode"] = _MODE_ORD.get(mode[ti], -1.0) if (ti >= 0 and ti < len(mode)) else -1.0
    d["xt_dist_to_goal"] = float(dist[ti]) if (ti >= 0 and np.isfinite(dist[ti])) else -1.0
    d["xt_soc"] = float(soc[ti]) if (ti >= 0 and np.isfinite(soc[ti])) else -1.0
    # 이 로봇이 빠지면 같은 팀의 다른 로봇도 멈춘다 -> 같은 목표를 공유하는 로봇 수 = 파급 규모
    if ti >= 0 and np.isfinite(gx[ti]):
        same = np.isclose(gx, gx[ti], atol=1e-6) & np.isclose(gy, gy[ti], atol=1e-6)
        d["xt_team_size"] = float(np.sum(same))
    else:
        d["xt_team_size"] = -1.0
    # 교체 로봇이 와야 할 거리 = 개입의 실제 지연 비용
    if ti >= 0 and spares:
        si = [j for j, i2 in enumerate(rid) if i2 in spares]
        sd = _fin([np.hypot(rx[j] - rx[ti], ry[j] - ry[ti]) for j in si])
        d["xt_spare_dist_min"] = float(sd.min()) if sd.size else -1.0
    else:
        d["xt_spare_dist_min"] = -1.0

    # ---- X_G: 함대 SoC 분포 + 공간 분산 (지금까지는 사건 당사자 soc 하나뿐이었다) --------------
    fs = _fin(soc)
    if fs.size:
        d["xg_soc_min"] = float(fs.min())
        d["xg_soc_p25"] = float(np.percentile(fs, 25))
        d["xg_soc_mean"] = float(fs.mean())
    frx, fry = _fin(rx), _fin(ry)
    if frx.size and fry.size:
        d["xg_spread"] = float(np.hypot(frx.std(), fry.std()))

    # ---- X_A: 부품이 물리적으로 어디 있고 얼마나 제자리에 놓였나 (Ryan 질문 (c)) --------------
    cp = r.get("raw_cargo_placed")
    if cp:
        d["xa_placed_frac"] = float(np.mean([bool(x) for x in cp]))
        d["xa_n_cargo"] = float(len(cp))
        cx, cy = _fin(r.get("raw_cargo_x") or []), _fin(r.get("raw_cargo_y") or [])
        if cx.size and cy.size:
            d["xa_cargo_spread"] = float(np.hypot(cx.std(), cy.std()))
    for k in ("raw_n_carry", "raw_n_transit", "raw_n_manip"):
        if k in r:
            d["xc_" + k[4:]] = float(r[k])
    return d


def banner(t):
    print("\n" + "=" * 96 + f"\n{t}\n" + "=" * 96, flush=True)


def stage(name, fn, results):
    """한 단계를 돌리고 실패해도 파이프라인을 죽이지 않는다."""
    banner(name)
    try:
        out = fn()
        results[name] = out
        return out
    except Exception:
        print(f"!! STAGE FAILED: {name}")
        traceback.print_exc()
        results[name] = {"error": traceback.format_exc()}
        return None


# ==========================================================================================
#  A. 집계
# ==========================================================================================
def load_rows(pattern):
    files = sorted(glob.glob(os.path.join(HERE, pattern)))
    rows = []
    for f in files:
        for line in open(f, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    print(f"  읽은 파일 {len(files)}개, 원시 행 {len(rows)}개")
    return rows


def aggregate(rows):
    """rollout 단위 행 -> (instance, macro) 당 Q̂ / SE / P(complete). 상태 스냅샷은 첫 행에서 승계."""
    # nominal(사건 없는 관측) 행은 macro 가 없다 -> 제외
    rows = [r for r in rows if r.get("macro") is not None and r.get("fired")]
    groups = {}
    for r in rows:
        groups.setdefault((r["instance"], int(r["macro"])), []).append(r)

    out = []
    for (inst, m), g in sorted(groups.items()):
        costs = np.array([scalar_cost(r) for r in g], float)
        comp = np.array([1.0 if r.get("complete") else 0.0 for r in g], float)
        base = dict(g[0])                              # 상태 스냅샷(결정 시점 특징)은 rollout 간 동일
        base.update({
            "instance": inst, "macro": m,
            "q_cost": float(costs.mean()),
            "q_se": float(costs.std(ddof=1) / math.sqrt(len(costs))) if len(costs) > 1 else float("nan"),
            "n_rollout": int(len(costs)),
            "p_complete": float(comp.mean()),
            # 기존 featurizer 들이 `closed` 를 라벨로 쓰므로 평균 closed 도 남긴다(호환)
            "closed": float(np.mean([float(r.get("closed", 0)) for r in g])),
            "hz_events_mean": float(np.mean([float(r.get("hz_break", 0)) + float(r.get("hz_cell", 0))
                                             for r in g])),
            "hz_capped_any": bool(any(r.get("hz_capped") for r in g)),
        })
        # X_C/X_G/X_A 서술자를 원자료에서 재계산해 얹는다. 구 데이터(raw_robot_mode 없음)면
        # 빈 dict 라 아무것도 안 바뀐다 — 옛 덤프와 새 덤프를 한 파일에서 섞어 읽을 수 있다.
        base.update(derive_state_descriptors(base))
        out.append(base)
    n_inst = len({r["instance"] for r in out})
    print(f"  집계: {len(out)} (instance,macro) 행, instance {n_inst}개, "
          f"rollout/셀 중앙값 {int(np.median([r['n_rollout'] for r in out]))}")
    capped = sum(1 for r in out if r["hz_capped_any"])
    if capped:
        print(f"  !! 사건 상한에 걸린 셀 {capped}개 — 그 rollout 은 미래가 잘려 낙관 편향")
    path = os.path.join(OUTDIR, "mc_dataset.jsonl")
    with open(path, "w", encoding="utf-8") as fh:
        for r in out:
            fh.write(json.dumps(r, ensure_ascii=False, default=str) + "\n")
    print(f"  wrote {path}")
    return out


# ==========================================================================================
#  B. admissibility 선별
# ==========================================================================================
def eval_set(agg):
    """Router/T1 을 평가할 **평가셋**을 고른다. 라벨 품질 기준(admissibility)과 **분리**한다.

    왜 분리해야 하는가 (2026-08-01 에 실제로 밟은 함정):
      admissibility 는 "결정이 결과를 가르는가"로 정의된다. 라벨을 만들 가치가 있는지에는 맞는
      기준이다. 그런데 그 필터를 **평가셋에 그대로 쓰면**, NOOP 이 정답인 무해 사례가 통째로
      제거된다(무해 사례는 정의상 팔 사이 차이가 작으므로). 그 결과 평가셋의 정답이 전부 한
      매크로가 되어, "항상 개입"이 만점을 받는 **판별 문제가 없는 평가셋**이 만들어졌다.
      실측: admissible 18개의 정답이 전부 macro 1 -> surrogate regret 0.000 (무의미).

    평가셋 기준은 다르다: **라벨이 믿을 만한가**만 본다(팔 2개 이상 + 유한한 Q̂).
    정답이 NOOP 이든 개입이든 모두 포함해야 판별 능력을 잴 수 있다.
    """
    by_inst = {}
    for r in agg:
        by_inst.setdefault(r["instance"], []).append(r)
    keep = {}
    for inst, g in by_inst.items():
        if len(g) < 2:
            continue
        if not all(math.isfinite(r["q_cost"]) for r in g):
            continue
        keep[inst] = g
    best_of = {i: min(g, key=lambda r: r["q_cost"])["macro"] for i, g in keep.items()}
    from collections import Counter
    dist = Counter(best_of.values())
    print(f"  평가셋 {len(keep)} instances (라벨 신뢰 기준: 팔>=2 & 유한 Q̂)")
    print(f"  정답 macro 분포: {dict(dist)}")
    maj = dist.most_common(1)[0] if dist else (None, 0)
    frac = maj[1] / max(1, len(keep))
    print(f"  최빈 정답 = macro {maj[0]} ({frac:.0%})  <- 1.0 에 가까우면 판별 문제가 없는 것")

    # ---- 동점(tie) 진단 — 이걸 안 보면 모든 결론이 왜곡된다 -------------------------------
    # 팔들의 비용이 **완전히 같은** instance 는 어떤 정책을 골라도 regret 0 이다. 즉 결정
    # 정보를 하나도 담지 않는다. 그런데 argmin 은 동점을 **첫 원소(=macro 0=NOOP)** 로 깨기
    # 때문에, 동점 instance 는 "NOOP 이 정답" 으로 집계되어 두 가지를 동시에 왜곡한다:
    #   (1) 정답 분포가 NOOP 쪽으로 부풀려진다 (실제로 75% 가 NOOP 으로 나왔다)
    #   (2) 모든 정책의 평균 regret 이 0 쪽으로 희석돼 정책 간 차이가 사라진다
    # 그래서 동점 비율과 **결정적(decisive) 부분집합**을 항상 함께 보고한다.
    ties = {}
    for inst, g in keep.items():
        c = [float(r["q_cost"]) for r in g]
        span = max(c) - min(c)
        ties[inst] = span <= max(1e-9, 1e-9 * abs(min(c)))
    n_tie = sum(ties.values())
    decisive = {i: g for i, g in keep.items() if not ties[i]}
    print(f"  동점(모든 팔 비용 동일) instance = {n_tie}/{len(keep)} ({n_tie/max(1,len(keep)):.0%})"
          f"  -> 결정정보 없음")
    if decisive:
        d_dist = Counter(best_of[i] for i in decisive)
        print(f"  결정적 instance {len(decisive)}개의 정답 분포: {dict(d_dist)}")
        dmaj = d_dist.most_common(1)[0]
        print(f"    최빈 정답 = macro {dmaj[0]} ({dmaj[1]/len(decisive):.0%})"
              f"  <- **판별력은 이 숫자로 봐야 한다**")
    return keep, best_of, ties


def admissibility(agg, pc_gap_min=0.3, sigma_mult=2.0):
    """이 instance 가 '배울 게 있는' 사례인가.

    STEP 2 의 교훈: makespan 격차만 보면 안 된다. 결정이 **완주 확률**을 가르는지가 핵심이다.
    두 기준 중 하나라도 만족하면 admissible 로 본다:
      (i) 최선 팔과 최악 팔의 P(complete) 격차 >= pc_gap_min
      (ii) Q̂ 격차가 합성 표준오차의 sigma_mult 배 이상 (= 통계적으로 구별되는 결정)
    """
    by_inst = {}
    for r in agg:
        by_inst.setdefault(r["instance"], []).append(r)

    rows = []
    for inst, g in sorted(by_inst.items()):
        if len(g) < 2:
            rows.append({"instance": inst, "admissible": False, "reason": "팔이 1개뿐"})
            continue
        qs = np.array([r["q_cost"] for r in g], float)
        ses = np.array([r["q_se"] if math.isfinite(r["q_se"]) else 0.0 for r in g], float)
        pcs = np.array([r["p_complete"] for r in g], float)
        i_best, i_worst = int(np.argmin(qs)), int(np.argmax(qs))
        pooled = math.sqrt(ses[i_best] ** 2 + ses[i_worst] ** 2)
        gap_q = float(qs[i_worst] - qs[i_best])
        gap_pc = float(pcs[i_best] - pcs[i_worst])
        sig = gap_q > sigma_mult * pooled if pooled > 0 else gap_q > 0
        adm = bool(gap_pc >= pc_gap_min or sig)
        rows.append({"instance": inst, "kind": g[0].get("kind"), "admissible": adm,
                     "best_macro": int(g[i_best]["macro"]), "gap_q": gap_q, "gap_pc": gap_pc,
                     "significant": bool(sig), "n_arms": len(g)})
    n_adm = sum(1 for r in rows if r["admissible"])
    print(f"  admissible {n_adm}/{len(rows)} instances")
    from collections import Counter
    print("  kind별:", dict(Counter((r.get("kind"), r["admissible"]) for r in rows)))
    print("  정답 macro 분포:", dict(Counter(r.get("best_macro") for r in rows if r["admissible"])))
    json.dump(rows, open(os.path.join(OUTDIR, "admissibility.json"), "w", encoding="utf-8"),
              indent=2, ensure_ascii=False)
    return rows


# ==========================================================================================
#  C. T1 -- 조건부 라벨분산 검정 (φ 가 충분통계인가)
# ==========================================================================================
def t1_sufficiency(agg):
    """Var[Q̂|φ] = Var_MC(몬테카를로 노이즈) + Var_hidden(φ가 못 담은 정보).

    K rollout 이 있으므로 Var_MC 를 **직접** 측정할 수 있다(셀 내부 분산). 그리고 φ 로 Q̂ 를
    회귀했을 때의 잔차분산이 Var_MC 보다 유의하게 크면, φ 가 담지 못한 정보가 남아 있다는 뜻이다.
    이것이 §3.6 의 T1 — "Markov 다"를 말이 아니라 숫자로 반증 가능하게 만드는 검정.
    """
    from sklearn.ensemble import RandomForestRegressor
    from sklearn.model_selection import LeaveOneGroupOut

    # 상태 서술자: 결정 시점 스냅샷 중 수치형만. 라벨 누출이 될 수 있는 결과 필드는 제외.
    # BAN 은 모듈 최상단에 한 번만 정의한다(위 주석 참조).
    feat_names, cover = phi_columns(agg)
    print(f"  상태 특징 {len(feat_names)}개: {feat_names}")
    partial = {k: c for k, c in cover.items() if c < len(agg)}
    if partial:
        print(f"  !! 일부 행에만 있는 열 {len(partial)}개 (결측은 {NA_FILL} 로 채움): "
              + ", ".join(f"{k}({c}/{len(agg)})" for k, c in sorted(partial.items())))
    X = design_matrix(agg, feat_names)
    y = np.array([r["q_cost"] for r in agg], float)
    groups = np.array([r["instance"] for r in agg])

    # Var_MC : 셀 내부 분산의 평균 (Q̂ 의 분산이므로 SE^2)
    ses = np.array([r["q_se"] for r in agg], float)
    # K=1(결정론 에피소드)이면 셀 내부 분산이 없다 -> Var_MC = 0. 비율 검정은 정의되지 않으므로
    # 아래 보조 지표(완주예측/순위적중)로만 판정한다.
    var_mc = float(np.nanmean(ses ** 2)) if np.isfinite(ses).any() else 0.0

    # 잔차분산 : instance 단위 LOGO 예측
    preds = np.full(len(y), np.nan)
    for tr, te in LeaveOneGroupOut().split(X, y, groups):
        m = RandomForestRegressor(n_estimators=300, random_state=0).fit(X[tr], y[tr])
        preds[te] = m.predict(X[te])
    resid = y - preds
    var_resid = float(np.nanmean(resid ** 2))
    var_hidden = max(0.0, var_resid - var_mc)
    ratio = var_hidden / var_mc if var_mc > 0 else float("inf")

    print(f"  Var_MC(측정된 몬테카를로 노이즈) = {var_mc:,.1f}")
    print(f"  잔차분산(φ로 예측)              = {var_resid:,.1f}")
    print(f"  => Var_hidden                   = {var_hidden:,.1f}   (비율 {ratio:.2f}×Var_MC)")

    # ---- 절대 스케일 비율만 보면 안 되는 이유 --------------------------------------------
    # 이 문제의 비용은 **이봉(bimodal)** 이다(완주 ~20 vs 미완주 ~26000). 완주 여부를 한 번만
    # 틀려도 잔차가 10^4 규모로 튀므로, Var_hidden/Var_MC 는 거의 항상 거대해진다. 그건 "φ가
    # 불충분하다"의 증거가 아니라 "비용 스케일이 이봉이다"의 반영일 수 있다.
    # 그래서 **결정에 실제로 쓰이는** 두 가지를 함께 잰다:
    #   (1) φ 로 완주 여부를 맞힐 수 있는가 (이봉의 원인 변수를 φ가 담고 있는가)
    #   (2) φ 로 팔의 순위를 맞힐 수 있는가 (결정이 옳으려면 이것만 맞으면 된다)
    from sklearn.ensemble import RandomForestClassifier
    comp = np.array([1 if r.get("p_complete", 0) >= 0.5 else 0 for r in agg])
    acc = float("nan")
    if len(set(comp)) > 1:
        pc = np.full(len(comp), -1)
        for tr, te in LeaveOneGroupOut().split(X, comp, groups):
            c = RandomForestClassifier(n_estimators=300, random_state=0).fit(X[tr], comp[tr])
            pc[te] = c.predict(X[te])
        acc = float(np.mean(pc == comp))
    base_rate = float(max(comp.mean(), 1 - comp.mean())) if len(comp) else float("nan")

    by_inst = {}
    for i, r in enumerate(agg):
        by_inst.setdefault(r["instance"], []).append(i)
    # 순위 적중은 **동점 instance 를 빼고** 재야 한다. 참 비용이 모든 팔에서 같으면 argmin(y)
    # 는 첫 팔을 임의로 고르는데 예측값은 동점이 아니므로, 동점 instance 는 거의 항상 "틀림"으로
    # 집계된다. 즉 동점을 섞으면 순위 적중이 **인위적으로 낮게** 나온다.
    hits, n_dec, n_tie = 0, 0, 0
    for inst, idx in by_inst.items():
        if len(idx) < 2 or np.any(np.isnan(preds[idx])):
            continue
        tc = y[idx]
        if float(tc.max()) - float(tc.min()) <= max(1e-9, 1e-9 * abs(float(tc.min()))):
            n_tie += 1
            continue                                  # 동점 = 결정정보 없음
        n_dec += 1
        hits += int(idx[int(np.argmin(preds[idx]))] == idx[int(np.argmin(y[idx]))])
    rank_acc = hits / n_dec if n_dec else float("nan")
    print(f"  (동점 instance {n_tie}개는 순위 적중 계산에서 제외 — 어떤 예측도 '틀림'으로 잡히므로)")

    print(f"  [보조1] φ로 완주여부 예측 정확도 = {acc:.3f}  (다수결 기준선 {base_rate:.3f})")
    print(f"  [보조2] φ로 팔 순위(argmin) 적중 = {rank_acc:.3f}  ({n_dec}개 결정)")

    # 판정은 절대 비율이 아니라 **결정 관련 지표**를 우선한다.
    # 다만 **표본이 충분할 때만** 판정한다. 실측(2026-08-02): 결정적 instance 가 5개뿐인
    # 데이터에서 rank_acc=1.000 이 나와 "φ는 결정에 충분하다"가 찍혔다. 5/5 는 동전을 다섯 번
    # 던져 다 앞면이 나온 것과 같아(우연 확률 1/32 수준) 충분성의 증거가 못 된다.
    # 게다가 같은 실행에서 완주예측 정확도(0.955)가 다수결 기준선(0.955)과 **정확히 같았다** —
    # φ 가 아무것도 더하지 못했다는 뜻인데도 순위 분기가 먼저 걸려 '충분' 으로 보고됐다.
    N_MIN_VERDICT = 20
    if math.isfinite(rank_acc) and n_dec < N_MIN_VERDICT:
        verdict = ("판정 불가(검정력 부족): 결정적 instance 가 %d개뿐이라 순위 적중 %.2f 는 "
                   "우연과 구별되지 않는다. 최소 %d개 필요. 완주예측 %.3f vs 기준선 %.3f."
                   % (n_dec, rank_acc, N_MIN_VERDICT, acc, base_rate))
    elif math.isfinite(rank_acc) and rank_acc >= 0.9:
        verdict = ("φ는 결정에 충분하다(순위 적중 %.2f). 절대 비용 잔차가 큰 것은 비용이 이봉이라 "
                   "완주 오분류 한 번이 10^4 규모 잔차를 만들기 때문이다." % rank_acc)
    elif math.isfinite(acc) and acc <= base_rate + 0.02:
        verdict = ("φ가 완주 여부조차 못 맞힌다(정확도 %.2f ≈ 기준선 %.2f) -> φ 불충분. "
                   "설계 §2 의 어떤 블록이 빠졌는지 확인 필요(특히 X_C 커밋먼트)." % (acc, base_rate))
    else:
        verdict = ("결론 보류: 순위 적중 %.2f / 완주 예측 %.2f. 표본이 적거나 모델 용량 문제일 수 "
                   "있으니 데이터를 늘려 재확인할 것." % (rank_acc, acc))
    print(f"  판정: {verdict}")
    print("  주의: 이 검정은 '회귀모델이 φ를 다 쓸 수 있다'고 가정한다. 모델 용량 부족도 같은 신호를")
    print("        내므로, 결론을 뒤집기 전에 모델을 키워 재확인해야 한다.")
    return {"var_mc": var_mc, "var_resid": var_resid, "var_hidden": var_hidden,
            "ratio": ratio, "complete_acc": acc, "complete_base_rate": base_rate,
            "rank_acc": rank_acc, "n_decisions": n_dec,
            "verdict": verdict, "features": feat_names}


# ==========================================================================================
#  D. T2 -- 이력 추가 regret 검정
# ==========================================================================================
def t2_history(agg):
    """T2 (설계 §3.6) — φ 와 φ⊕(이력) 로 각각 학습해 **결정 regret 을 짝지어** 비교한다.

    논리: s 가 Markov 이면 이력은 잉여다. 이력을 더했을 때 regret 이 유의하게 줄면, φ 가 담지
    못한 정보가 과거에 남아 있다는 뜻 = **s 는 Markov 가 아니다**(설계 §3 의 5가지 위협 중
    어느 것이 살아 있는지 추적해야 한다).

    이력 채널(`hist_*`)은 결정 t 시점에 이미 관측 가능한 것만 담는다 — 직전에 무엇을 골랐는지,
    그 뒤 얼마나 진행됐는지, 지금까지 몇 번 개입했는지. 미래(next_*)가 아니다.

    주의 1: `decision_idx`(에피소드 내 몇 번째 결정인가)는 **이력 요약**이므로 φ 에서 빼서
            이력 쪽에 둔다. φ 에 남겨두면 T2 가 "이력 없음"을 이미 이력으로 답하게 된다.
    주의 2: regret 은 **항상 참 비용**으로 재고, 짝지은 부호검정으로 유의성을 본다.
    """
    from sklearn.ensemble import RandomForestRegressor
    from sklearn.model_selection import LeaveOneGroupOut

    hist_keys = sorted({k for r in agg for k in r
                        if str(k).startswith("hist_") and isinstance(r[k], (int, float))
                        and not isinstance(r[k], bool)})
    if not hist_keys:
        msg = ("이력 채널(hist_*)이 데이터에 없다. 다중 사건 에피소드로 재생성해야 T2 가 가능하다.")
        print("  " + msg)
        print("  => T2 = BLOCKED (이력 필드 부재).")
        return {"status": "blocked", "reason": msg}

    by_inst = {}
    for r in agg:
        by_inst.setdefault(r["instance"], []).append(r)
    data = [r for i, g in by_inst.items() if len(g) >= 2 for r in g]
    if len(data) < 20:
        print("  평가 가능한 instance 가 너무 적다.")
        return {"status": "insufficient_data", "n": len(data)}

    phi, _ = phi_columns(data)
    print(f"  φ {len(phi)}개 / 이력 {len(hist_keys)}개: {hist_keys}")

    y = np.array([r["q_cost"] for r in data], float)
    groups = np.array([r["instance"] for r in data])
    inst_idx = {}
    for i, r in enumerate(data):
        inst_idx.setdefault(r["instance"], []).append(i)

    def _regret(cols):
        X = design_matrix(data, cols)
        # 결정 중심 타깃(instance 내부 정규화) — raw q_cost 는 이봉이라 순위 학습을 가린다
        yf = np.zeros_like(y)
        for _, idx in inst_idx.items():
            v = y[idx]
            lo, hi = float(v.min()), float(v.max())
            yf[idx] = (v - lo) / max(hi - lo, 1e-9)
        out = {}
        for tr, te in LeaveOneGroupOut().split(X, yf, groups):
            inst = groups[te][0]
            m = RandomForestRegressor(n_estimators=300, random_state=0).fit(X[tr], yf[tr])
            p = m.predict(X[te])
            idx = list(te)
            pick = idx[int(np.argmin(p))]
            tc = y[idx]
            best = float(tc.min()); span = max(float(tc.max()) - best, 1e-9)
            out[inst] = (float(y[pick]) - best) / span
        return out

    r_phi = _regret(phi)
    r_aug = _regret(phi + hist_keys)
    keys = sorted(set(r_phi) & set(r_aug))
    a = np.array([r_phi[k] for k in keys]); b = np.array([r_aug[k] for k in keys])
    d = a - b                                     # >0 이면 이력이 도움이 된 것
    better = int(np.sum(d > 1e-9)); worse = int(np.sum(d < -1e-9))
    # 짝지은 부호검정(정규성 가정 없이) — 이항 양측 p
    n_eff = better + worse
    p = float("nan")
    if n_eff:
        from math import comb
        k = min(better, worse)
        p = min(1.0, 2.0 * sum(comb(n_eff, j) for j in range(k + 1)) / (2.0 ** n_eff))

    print(f"  regret(φ)        = {a.mean():.3f}")
    print(f"  regret(φ⊕이력)   = {b.mean():.3f}    (Δ = {d.mean():+.3f})")
    print(f"  이력이 도움된 instance {better} / 해친 {worse} / 무변화 {len(keys)-n_eff}"
          f"   짝지은 부호검정 p = {p:.3f}")
    if math.isfinite(p) and p < 0.05 and d.mean() > 0:
        verdict = ("이력을 더하면 결정이 유의하게 좋아진다 -> **φ 는 Markov 하지 않다**. "
                   "설계 §3 의 위협 중 어느 것이 살아 있는지 추적할 것(퇴화기억/부분실행기억이 유력).")
    elif math.isfinite(p) and p < 0.05 and d.mean() < 0:
        verdict = ("이력을 더하면 오히려 나빠진다 = 이력은 잉여이고 차원만 늘렸다(과적합). "
                   "φ 가 이미 이력을 담고 있다는 간접 증거.")
    else:
        verdict = ("이력 추가의 효과가 유의하지 않다 -> 이 표본에서 φ 의 Markov 성을 **반증하지 "
                   "못했다**. (통과가 아니라 반증 실패 — 표본이 커지면 뒤집힐 수 있다.)")
    print(f"  판정: {verdict}")
    return {"status": "done", "n_instances": len(keys), "regret_phi": float(a.mean()),
            "regret_phi_hist": float(b.mean()), "delta": float(d.mean()),
            "n_better": better, "n_worse": worse, "sign_test_p": p,
            "hist_features": hist_keys, "verdict": verdict}


# ==========================================================================================
#  E. Router -- §9 VoI 정지규칙
# ==========================================================================================
def router_voi(agg, adm_rows):
    """surrogate 로 끝낼 것인가, 비싼 오라클을 부를 것인가를 **비용/이득 비교로 유도**한다.

    설계 §9 의 meta-action 은 {ACCEPT(surrogate), QUERY_LLM, CALL_ORACLE} 이다. 밤사이 LLM 을
    부를 수 없으므로 여기서는 비싼 결정기 = **오라클**(= 참 라벨)로 두고 게이트를 평가한다.
    이건 대체가 아니라 설계 그대로다 — CALL_ORACLE 이 이미 meta-action 의 하나다.

    게이트 신호: surrogate 앙상블(트리별 예측)의 **최상위 두 팔 간 격차 대비 불확실성**.
        margin = q̂(2등) - q̂(1등)          (작을수록 헷갈림)
        unc    = 두 팔 예측의 트리간 표준편차 합
        VoI    ≈ P(1등이 사실 틀렸을 확률) × (틀렸을 때 잃는 regret)
    비싼 결정기를 부르는 조건:  VoI > w_c (오라클 호출 비용)
    w_c 를 쓸어가며 **regret vs 오라클 호출률** 프론티어를 그린다 = §9 가 요구한 그림.
    """
    from sklearn.ensemble import RandomForestRegressor
    from sklearn.model_selection import LeaveOneGroupOut

    keep, best_of, ties = eval_set(agg)
    data = [r for r in agg if r["instance"] in keep]
    if len(data) < 10:
        print("  평가셋이 너무 적어 Router 평가를 건너뛴다.")
        return {"status": "insufficient_data", "n": len(data)}

    # BAN 은 모듈 최상단에 한 번만 정의한다(위 주석 참조).
    feats, _ = phi_columns(data)
    X = design_matrix(data, feats)
    y = np.array([r["q_cost"] for r in data], float)
    groups = np.array([r["instance"] for r in data])
    by_inst = {}
    for i, r in enumerate(data):
        by_inst.setdefault(r["instance"], []).append(i)

    # ---- 학습 타깃 두 가지 ---------------------------------------------------------------
    # (a) raw   : q_cost 그대로. 문제는 이 값이 **이봉**이라는 것 — 완주 ~20 vs 미완주 ~26000.
    #             회귀 손실이 "완주할까?"에 지배되고, 정작 결정에 필요한 "같은 instance 안에서
    #             어느 팔이 나은가"는 스케일에 묻힌다.
    # (b) focused: instance 내부에서 정규화한 비용 (설계 §8.3 의 decision-focused).
    #             (q − min)/(max − min) 이므로 모든 instance 가 같은 [0,1] 스케일을 갖고,
    #             모델은 오직 **팔 사이의 상대 순위**를 배우게 된다. argmin 만 맞으면 되는
    #             우리 목적과 손실이 정렬된다.
    y_focus = np.zeros_like(y)
    for inst, idx in by_inst.items():
        v = y[idx]
        lo, hi = float(v.min()), float(v.max())
        y_focus[idx] = (v - lo) / max(hi - lo, 1e-9)

    def _loio_regret(target):
        """주어진 타깃으로 LOIO 학습 -> instance 별 (regret, margin, 불확실성) 반환."""
        out = {}
        for tr, te in LeaveOneGroupOut().split(X, target, groups):
            inst = groups[te][0]
            mdl = RandomForestRegressor(n_estimators=300, random_state=0).fit(X[tr], target[tr])
            per_tree = np.array([t.predict(X[te]) for t in mdl.estimators_])
            pred, unc = per_tree.mean(axis=0), per_tree.std(axis=0)
            idx = list(te)
            order = np.argsort(pred)
            pick = idx[order[0]]
            tc = y[idx]                                   # regret 은 **항상 참 비용**으로 잰다
            best = float(tc.min()); span = max(float(tc.max()) - best, 1e-9)
            out[inst] = {
                "regret": (float(y[pick]) - best) / span,
                "margin": float(pred[order[1]] - pred[order[0]]) if len(order) > 1 else float("inf"),
                "unc": float(unc[order[0]] + (unc[order[1]] if len(order) > 1 else 0.0)),
            }
        return out

    rec_focus = _loio_regret(y_focus)
    reg_focus = np.array([rec_focus[i]["regret"] for i in sorted(rec_focus)])

    # instance 별로: surrogate 예측, 트리간 불확실성, 참 regret
    rec = {}
    for tr, te in LeaveOneGroupOut().split(X, y, groups):
        inst = groups[te][0]
        m = RandomForestRegressor(n_estimators=300, random_state=0).fit(X[tr], y[tr])
        per_tree = np.array([t.predict(X[te]) for t in m.estimators_])   # (n_trees, n_arms)
        pred, unc = per_tree.mean(axis=0), per_tree.std(axis=0)
        idx = list(te)
        order = np.argsort(pred)                       # 비용이므로 작을수록 좋음
        pick = idx[order[0]]
        margin = float(pred[order[1]] - pred[order[0]]) if len(order) > 1 else float("inf")
        unc_sum = float(unc[order[0]] + (unc[order[1]] if len(order) > 1 else 0.0))
        true_costs = y[idx]
        best_true = float(true_costs.min())
        span = max(float(true_costs.max()) - best_true, 1e-9)
        rec[inst] = {
            "regret_surrogate": (float(y[pick]) - best_true) / span,   # 0=최선, 1=최악
            "margin": margin, "unc": unc_sum,
            # VoI 대리치: 헷갈릴수록(margin 작고 불확실성 큼) 오라클을 부를 값어치가 크다
            "voi": float(unc_sum / (abs(margin) + 1e-9)),
            "span": span,
        }

    insts = list(rec.keys())
    reg_sur = np.array([rec[i]["regret_surrogate"] for i in insts])

    # ---- 게이트는 **배포할 모델** 위에서 평가해야 한다 -----------------------------------
    # 이전 판의 결함: 배포 후보는 decision-focused 모델인데, VoI 프론티어는 raw 타깃 모델의
    # margin/unc 로 그렸다. "어느 모델을 쓸 것인가"와 "그 모델을 언제 못 믿을 것인가"가
    # 서로 다른 모델을 가리키면 프론티어는 배포 결정에 쓸 수 없다.
    # 두 모델 중 regret 이 낮은 쪽을 배포 후보로 잡고, 그 모델의 신호로 게이트를 판정한다.
    _use_focus = np.mean([rec_focus[i]["regret"] for i in insts]) <= reg_sur.mean()
    gate_src = rec_focus if _use_focus else rec
    gate_key = "regret" if _use_focus else "regret_surrogate"
    reg_deploy = np.array([gate_src[i][gate_key] for i in insts])
    vois = np.array([float(gate_src[i]["unc"] / (abs(gate_src[i]["margin"]) + 1e-9))
                     for i in insts])
    print(f"  게이트 기준 모델 = surrogate({'focused' if _use_focus else 'raw'}) "
          f"(평균 regret {reg_deploy.mean():.3f})")

    # ---- 베이스라인 ------------------------------------------------------------------
    # 이게 없으면 "surrogate regret = 0.000" 은 해석 불가능하다. 과제가 쉬워서 0 인지, 모델이
    # 잘해서 0 인지 구별할 방법이 없기 때문이다. 실제로 그 함정을 밟았다(2026-08-01).
    # 최소한 '항상 같은 매크로' 정책보다 나아야 surrogate 가 상태를 읽고 있다고 말할 수 있다.
    def canonical_pick(g):
        """규칙 기반 표준 대응(shim 의 canonical_action 과 같은 분기)."""
        kind = str(g[0].get("kind", ""))
        valid = {int(r["macro"]) for r in g}
        if kind == "fault":
            return 1 if 1 in valid else 0
        if kind == "battery":
            soc = float(g[0].get("soc", float("nan")))
            deep = math.isfinite(soc) and soc <= 0.2
            return (1 if deep else 2) if (1 if deep else 2) in valid else 0
        if kind in ("zone", "zoneblk"):
            return 3 if 3 in valid else 0
        return 0

    def regret_of(pick_fn):
        out = []
        for inst in insts:
            g = keep[inst]
            costs = {int(r["macro"]): float(r["q_cost"]) for r in g}
            best, worst = min(costs.values()), max(costs.values())
            span = max(worst - best, 1e-9)
            m = pick_fn(g)
            m = m if m in costs else min(costs, key=costs.get)  # 불가능한 선택은 최선으로 관대 처리
            out.append((costs[m] - best) / span)
        return np.array(out)

    rng0 = np.random.default_rng(0)
    baselines = {
        "always-NOOP(0)":   regret_of(lambda g: 0),
        "always-Replace(1)": regret_of(lambda g: 1),
        "canonical(규칙)":   regret_of(canonical_pick),
        "random(valid)":     regret_of(lambda g: int(rng0.choice([int(r["macro"]) for r in g]))),
        "surrogate(raw)":    reg_sur,
        "surrogate(focused)": np.array([rec_focus[i]["regret"] for i in insts]),
        "oracle":            np.zeros(len(insts)),
    }
    noop_mask = np.array([best_of[i] == 0 for i in insts])
    dec_mask = np.array([not ties[i] for i in insts])          # 결정정보가 있는 instance
    print("\n  정책별 평균 normalized regret (0=항상 최선, 1=항상 최악)")
    print(f"    {'정책':<20} {'regret(전체)':>13} {'regret(결정적)':>14} {'NOOP정답부분':>13}")
    for name, v in baselines.items():
        sub = v[noop_mask].mean() if noop_mask.any() else float("nan")
        dec = v[dec_mask].mean() if dec_mask.any() else float("nan")
        print(f"    {name:<20} {v.mean():>13.3f} {dec:>14.3f} {sub:>13.3f}")
    print(f"    (NOOP 정답 {int(noop_mask.sum())}개 / 결정적 {int(dec_mask.sum())}개 / 전체 {len(insts)}개)")
    print("    ** 동점 instance 는 어떤 정책도 regret 0 이라 전체 열을 0 쪽으로 희석한다."
          " 정책 비교는 '결정적' 열로 해야 한다. **")

    # 난이도 판정도 **결정적 부분집합**에서 한다. 전체 평균으로 하면 동점 희석 때문에
    # 모든 정책이 비슷해 보여 "판별 문제가 아니다" 라는 잘못된 결론이 나온다.
    _m = dec_mask if dec_mask.any() else np.ones(len(insts), bool)
    _rules = {k: v for k, v in baselines.items() if not k.startswith("surrogate") and k != "oracle"}
    best_baseline = min((v[_m].mean(), k) for k, v in _rules.items())
    reg_best_sur = min(reg_sur[_m].mean(), baselines["surrogate(focused)"][_m].mean())
    beats = reg_best_sur < best_baseline[0] - 1e-9
    print(f"\n  판정(과제 난이도): 최선 베이스라인 = {best_baseline[1]} ({best_baseline[0]:.3f}), "
          f"surrogate 최선 = {reg_best_sur:.3f} -> "
          + ("surrogate 가 상태를 읽고 이득을 낸다" if beats else
             "**surrogate 가 단순 규칙을 못 이긴다 = 이 평가셋은 판별 문제가 아니다**"))

    # ---- 짝지은 유의성: surrogate 가 최선 규칙을 **우연 이상으로** 이기는가 ----------------
    # 평균만 비교하면 표본이 작을 때 언제든 뒤집힌다(실제로 28->96 instance 로 늘리자 이득이
    # 0.107 -> 0.167 로 좁아졌다). instance 는 동일하므로 짝지어 부호검정을 한다.
    # 짝지은 검정은 **결정적 instance 만** 대상으로 한다. 동점은 정의상 무승부라 검정력만
    # 깎는다(실측: 96개 중 74개가 무승부로 잡혀 p=1.0 이 나왔다 — 신호가 없어서가 아니라
    # 결정정보가 없는 instance 를 검정에 넣어서였다).
    _bl = baselines[best_baseline[1]][dec_mask]
    _sd = _bl - baselines["surrogate(focused)"][dec_mask]   # >0 이면 surrogate 승
    _w = int(np.sum(_sd > 1e-9)); _l = int(np.sum(_sd < -1e-9)); _n = _w + _l
    _p = float("nan")
    if _n:
        from math import comb
        _k = min(_w, _l)
        _p = min(1.0, 2.0 * sum(comb(_n, j) for j in range(_k + 1)) / (2.0 ** _n))
    print(f"\n  짝지은 검정  surrogate(focused) vs {best_baseline[1]}: "
          f"승 {_w} / 패 {_l} / 무 {len(_sd)-_n},  Δ={_sd.mean():+.3f},  부호검정 p={_p:.4f}")
    print("    -> " + ("유의한 우위" if (math.isfinite(_p) and _p < 0.05 and _sd.mean() > 0)
                       else "우위가 유의하지 않다 (표본을 늘리거나 φ 를 보강해야 한다)"))

    print(f"\n  instance {len(rec)}개.  surrogate-only 평균 regret = {reg_sur.mean():.3f}")
    print(f"  오라클-only 평균 regret = 0.000 (정의상), 호출률 1.00")
    # 프론티어도 결정적 부분집합에서 그린다. 동점 instance 는 오라클을 불러도 regret 이
    # 0 에서 0 으로 갈 뿐이라, 섞어 넣으면 "호출이 이득을 낸다"는 착시만 만든다.
    vois = vois[_m]
    reg_deploy = reg_deploy[_m]
    print("\n  VoI 게이트 프론티어 (결정적 instance %d개, 임계값을 쓸어가며):" % int(_m.sum()))
    print(f"    {'오라클 호출률':>12} {'평균 regret':>12} {'임계 VoI':>12}")
    frontier = []
    for q in [1.01, 0.9, 0.75, 0.5, 0.25, 0.1, 0.0]:
        thr = float(np.quantile(vois, q)) if q <= 1.0 else float("inf")
        called = vois >= thr
        # 오라클을 부른 instance 는 regret 0, 아니면 surrogate 의 regret
        r = np.where(called, 0.0, reg_deploy).mean()
        rate = float(called.mean())
        frontier.append({"threshold": thr, "call_rate": rate, "regret": float(r)})
        print(f"    {rate:>12.2f} {r:>12.3f} {thr:>12.3f}")

    # 무작위 게이트(같은 호출률)와 비교 — VoI 신호가 실제로 정보를 담는지 확인
    print("\n  대조: 같은 호출률을 **무작위로** 배분했을 때 (VoI 신호가 쓸모 있는지 판정)")
    rng = np.random.default_rng(0)
    print(f"    {'호출률':>8} {'VoI 게이트':>12} {'무작위':>12} {'이득':>10}")
    gains = []
    for f in frontier:
        if f["call_rate"] in (0.0, 1.0):
            continue
        rnd = []
        for _ in range(200):
            mask = rng.random(len(reg_deploy)) < f["call_rate"]
            rnd.append(np.where(mask, 0.0, reg_deploy).mean())
        g = float(np.mean(rnd) - f["regret"])
        gains.append(g)
        print(f"    {f['call_rate']:>8.2f} {f['regret']:>12.3f} {np.mean(rnd):>12.3f} {g:>+10.3f}")
    verdict = ("VoI 신호가 무작위보다 낫다 (게이트가 실제로 정보를 쓴다)"
               if gains and np.mean(gains) > 0 else
               "VoI 신호가 무작위와 구별되지 않는다 — 게이트 신호를 바꿔야 한다")
    print(f"\n  판정: {verdict}")
    json.dump({"frontier": frontier, "per_instance": rec, "verdict": verdict,
               "baselines": {k: float(v.mean()) for k, v in baselines.items()},
               "best_baseline": {"name": best_baseline[1], "regret": float(best_baseline[0])},
               "surrogate_beats_baseline": bool(beats),
               "paired_sign_test": {"wins": _w, "losses": _l, "delta": float(_sd.mean()), "p": _p},
               "gate_model": ("focused" if _use_focus else "raw"),
               "n_noop_correct": int(noop_mask.sum()), "n_eval": len(insts),
               "mean_gain_vs_random": float(np.mean(gains)) if gains else None},
              open(os.path.join(OUTDIR, "router_voi.json"), "w", encoding="utf-8"),
              indent=2, ensure_ascii=False, default=str)
    return {"frontier": frontier, "verdict": verdict,
            "surrogate_only_regret": float(reg_sur.mean()),
            "baselines": {k: float(v.mean()) for k, v in baselines.items()},
            "best_baseline": best_baseline[1], "best_baseline_regret": float(best_baseline[0]),
            "surrogate_beats_baseline": bool(beats),
            "paired_sign_test": {"wins": _w, "losses": _l, "delta": float(_sd.mean()), "p": _p},
            "gate_model": ("focused" if _use_focus else "raw"),
            "n_noop_correct": int(noop_mask.sum()), "n_eval": len(insts),
            "mean_gain_vs_random": float(np.mean(gains)) if gains else None}


# ==========================================================================================
def main():
    os.makedirs(OUTDIR, exist_ok=True)
    pattern = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--glob=")),
                   "oracle/out/mcds_*.jsonl")
    results = {}

    rows = stage("A. 원시 rollout 행 읽기", lambda: load_rows(pattern), results)
    if not rows:
        print("\n!! 원시 데이터가 없다. 파이프라인 중단.")
        json.dump(results, open(os.path.join(OUTDIR, "overnight_results.json"), "w",
                                encoding="utf-8"), indent=2, ensure_ascii=False, default=str)
        return
    agg = stage("A2. (instance, macro) 집계 -> Q̂ / SE / P(complete)", lambda: aggregate(rows), results)
    if not agg:
        return
    adm = stage("B. admissibility 선별 (P(complete) 격차 포함)", lambda: admissibility(agg), results)
    stage("C. T1 — 조건부 라벨분산 검정 (φ 충분성)", lambda: t1_sufficiency(agg), results)
    stage("D. T2 — 이력 추가 regret 검정", lambda: t2_history(agg), results)
    if adm:
        stage("E. Router — §9 VoI 정지규칙", lambda: router_voi(agg, adm), results)

    json.dump(results, open(os.path.join(OUTDIR, "overnight_results.json"), "w", encoding="utf-8"),
              indent=2, ensure_ascii=False, default=str)
    print(f"\nwrote {os.path.join(OUTDIR, 'overnight_results.json')}")


if __name__ == "__main__":
    main()
