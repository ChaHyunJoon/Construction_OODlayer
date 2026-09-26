# natural_tool.jl <model> <case> <seed> <root> <proposals.json> — T10b: production 진입점(render_demo.jl,
# ZONE_REPAIR_VERIFICATION=shadow, fixture proposal source)을 B0-FAIL 판에 그대로 돌린다. 선택은 강제하지 않는다
# (baseline_override·forged capabilities 없음) — NOOP 기준이 실제로 FAIL 이고 후보가 COMPLETE + 효과·계약 검사를 통과할 때만
# supervisor 가 스스로 TOOL 을 고른다(shadow 라 commit 은 안 하고 SHADOW_NOT_COMMITTED → 원래 세계 NOOP 재개).
# env 는 T8 시험의 `render()` 와 같다: 최소 env + pi0 셀 + 검증 손잡이(DSPY_URL 없음 — 모델·서비스 호출 0).
include(joinpath(@__DIR__, "..", "..", "..", "..", "src", "verification", "branch_runner.jl"))
const BR = BranchRunner
model, case, seed, root, props = ARGS[1], ARGS[2], parse(Int, ARGS[3]), abspath(ARGS[4]), abspath(ARGS[5])
ispath(root) && error("root exists: $(root)")
mkpath(root)
env = merge(BR.base_env(), BR.pi0_launch_env(model, case, seed),
            Dict("ZONE_REPAIR_VERIFICATION" => "shadow", "ZONE_REPAIR_PROPOSALS" => props,
                 "DEMO_OUT_DIR" => joinpath(root, "out"), "ZONE_REPAIR_DIR" => joinpath(root, "zr"),
                 "ZONE_REPAIR_CAMPAIGN_DIR" => joinpath(root, "campaign")))
lf = joinpath(root, "render.log")
p = open(lf, "w") do io
    run(pipeline(ignorestatus(Cmd(setenv(`$(BR.JULIA) --project=$(BR.ROOT) $(joinpath(BR.ROOT, "tools", "monitor", "render_demo.jl"))`, env);
                                  dir = BR.ROOT)); stdout = io, stderr = io))
end
println("[t10b-natural] render_demo exit=", p.exitcode, " log=", lf)
exit(p.exitcode)
