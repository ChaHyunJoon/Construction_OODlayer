"""판 → 학습 행: render 엔진 라벨 계약 (spec §11.4, §0.0 R10). 계약 문서:
docs/superpowers/reports/2026-09-29-render-label-contract.md

`run` = `harvest.collect_run` 의 결과 모양: complete · closed · n_total · sim_seconds · total_energy_J ·
decisions_raw(스트림 `respec_history` 원본). 결정 피처는 그 판의 **첫** 해당 kind 결정의
`input.router.ood_features`, 메뉴는 같은 결정의 `input.router.valid_menu` 에서 읽는다."""
import json, math, os, sys
from . import paths

sys.path.insert(0, os.path.join(paths.ROOT, "src", "decision", "core"))
import features_agnostic  # noqa: E402

# `dspy_service._surro_row` 가 채우는 필드와 None 규약 — 두 벌이 갈리면 학습 행과 온라인 행이 다른 세계다.
SURRO_FIELDS = ("severity", "soc", "zone_overlap", "agent_pending", "n_active", "spare_count",
                "closed_at_fire", "total_nodes", "progress", "zone_nav_blocked", "zone_nav_downstream")
_NONE_AS = {"soc": math.nan, "zone_overlap": -1.0, "zone_nav_blocked": -1.0, "zone_nav_downstream": -1.0}


def first_decision(run, kind):
    for h in run.get("decisions_raw") or []:
        o = ((h.get("input") or {}).get("router") or {}).get("ood_features") or {}
        if o.get("kind") == kind:
            return h
    return None


def _router(run, kind):
    h = first_decision(run, kind)
    if h is None:
        raise ValueError("no %s decision with ood_features in this run" % kind)
    return h["input"]["router"]


def _a0_kind_valid(kind):
    reg = json.load(open(paths.A0_REGISTRY, encoding="utf-8"))["macros"]
    return sorted(int(i) for i, m in reg.items() if kind in m.get("kinds", []) and not m.get("retired"))


def menu_ids(run, kind, names=None):
    """그 결정의 합법 메뉴(id). `valid_menu == []` 는 "전용 메뉴 없음 = kind 기본표"(policy.jl 규약)."""
    menu = _router(run, kind).get("valid_menu")
    if not menu:
        return _a0_kind_valid(kind)
    if names is None:
        reg = json.load(open(paths.A0_REGISTRY, encoding="utf-8"))["macros"]
        names = {int(i): m["name"] for i, m in reg.items()}
    ids = {v: k for k, v in names.items()}
    return sorted(ids[m] for m in menu)


def features(ood):
    return {k: (_NONE_AS.get(k, 0.0) if ood.get(k) is None else float(ood[k])) for k in SURRO_FIELDS}


def row_from_run(run, arm_id, instance, kind, valid_mask, stamps):
    f = features(_router(run, kind)["ood_features"])
    row = dict(instance=instance, kind=kind, macro=int(arm_id), macro_name=stamps["names"][int(arm_id)],
               valid_mask=list(valid_mask), fired=True, complete=bool(run["complete"]),
               closed=int(run["closed"]), total=int(run["n_total"]),
               makespan=float(run["sim_seconds"]), energy_J=float(run["total_energy_J"]),
               total_energy_J=float(run["total_energy_J"]), vocab=stamps["vocab"],
               train_kinds=stamps["train_kinds"], objective_hash=stamps["objective_hash"],
               label_engine="render")
    row.update(f)
    return row


def descriptors(row):
    return list(features_agnostic.descriptors_from_row(row).values())


def parity_ok(row, stream_descriptors):
    """학습 행에서 계산한 6-서술자 == 그 판 결정 기록의 `descriptors` (spec §11.4 변환 동등성)."""
    a = descriptors(row)
    return len(a) == len(stream_descriptors) and all(
        abs(x - float(y)) <= 1e-9 for x, y in zip(a, stream_descriptors))
