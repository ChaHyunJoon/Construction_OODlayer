"""A₀ kind(fault·battery)를 render 엔진으로 다시 라벨한다 (spec §0.0 R10) — 게이트 풀 × 모델 ×
{fault, battery} × A₀ 합법 팔을 canonical 레인 + `DEMO_FORCE_MACRO=<팔>` 로 반사실 판.
v1 이상 데이터셋은 render 엔진 라벨만 쓴다(gen_oracle 33행과 섞지 않는다). 실험당 1회, 캐시."""
import json, os, subprocess
from . import paths, rows
from .versions import canonical, sha256_bytes

KINDS = ("fault", "battery")


def arm_plan():
    reg = json.load(open(paths.A0_REGISTRY, encoding="utf-8"))["macros"]
    return {k: [reg[str(i)]["name"] for i in rows._a0_kind_valid(k)] for k in KINDS}


def assemble(runs, stamps):
    """runs: {(model, kind, seed, arm_name): run}. 메뉴는 그 인스턴스의 NOOP 판 결정에서 읽고, 메뉴 밖
    팔(강제로 돌렸어도)은 버린다. 메뉴 팔 중 하나라도 판이 없으면 인스턴스를 통째로 뺀다(loader 가
    관측 팔 == valid_mask 를 요구한다)."""
    ids = {v: k for k, v in stamps["names"].items()}
    out = []
    for (model, kind, seed) in sorted({k[:3] for k in runs}):
        noop = runs.get((model, kind, seed, stamps["names"][0]))
        if noop is None:
            continue
        menu = rows.menu_ids(noop, kind, stamps["names"])
        got = {ids[a]: r for (m, k, s, a), r in runs.items() if (m, k, s) == (model, kind, seed)}
        if not set(menu) <= set(got):
            continue
        inst = "%s_%s_s%d" % (kind, model, seed)
        out += [rows.row_from_run(got[a], a, inst, kind, menu, stamps) for a in menu]
    return out


def cache_key(code_rev, dirty, seeds, models):
    return sha256_bytes(canonical([code_rev, dirty, list(seeds), list(models), arm_plan()]).encode())[:16]


def run(exp, cfg, code_rev, dirty, stamps, workers=8):
    """grids → 판 수집 → data/selfimprove/<exp>/labels/a0_render.jsonl. 경로를 돌려준다."""
    from . import harvest
    key = cache_key(code_rev, dirty, cfg["gate_seeds"], cfg["models"])
    base = os.path.join(paths.state_dir(exp), "cache", "a0", key)
    plan, runs = arm_plan(), {}
    for model in cfg["models"]:
        for arm in sorted({a for v in plan.values() for a in v}):
            cases = [k for k in KINDS if arm in plan[k]]
            grid = os.path.join(base, model, arm)
            env = dict(os.environ, GRID_OUT=grid, DEMO_MODEL=paths.MODEL_FILES[model],
                       CAMPAIGN_ID="si-%s-a0-%s-%s" % (exp, model, arm), DEMO_FORCE_MACRO=arm)
            env.pop("DSPY_URL", None)            # canonical 레인: 서비스 신원 검사를 안 태운다
            subprocess.run(["bash", os.path.join(paths.ROOT, "tools", "monitor", "grid", "render_grid.sh"),
                            "canonical", " ".join(cases), " ".join(map(str, cfg["gate_seeds"])),
                            str(workers)], env=env, cwd=paths.ROOT, check=False)
            for case in cases:
                for seed in cfg["gate_seeds"]:
                    r = harvest.collect_run(grid, "canonical__%s__s%d" % (case, seed))
                    if r is not None:
                        runs[(model, case, seed, arm)] = r
    out = os.path.join(paths.data_dir(exp), "labels", "a0_render.jsonl")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        for r in assemble(runs, stamps):
            f.write(json.dumps(r, sort_keys=True) + "\n")
    return out
