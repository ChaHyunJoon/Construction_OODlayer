# 실행: julia +lts --project=. tools/monitor/grid/t10a/killdemo.jl  (레포 루트에서)
# fix 3 기전 확인: SIGTERM 을 무시하는 "부모"(ZRV_BRANCH_TOKEN 포함, 그룹 리더 아님 — start_parent 와 같은 모양)
include(joinpath(pwd(), "src", "verification", "branch_runner.jl"))
import .BranchRunner as BR
spawn(tok) = run(setenv(`bash -c 'trap "" TERM; while true; do sleep 0.2; done'`, merge(Dict(ENV), Dict("ZRV_BRANCH_TOKEN" => tok))); wait = false)
# 옛 경로: kill(p); wait(p) — 10 s 안에 안 끝나면 매달린 것
p = spawn("old-$(time_ns())"); sleep(0.5); kill(p)
t = @async wait(p); t0 = time(); while !istaskdone(t) && time() - t0 < 10; sleep(0.1); end
println("OLD kill+wait: finished=", istaskdone(t), " after ", round(time() - t0; digits = 1), " s")
process_running(p) && kill(p, Base.SIGKILL); wait(p)
# 새 경로: kill(p); kill_tree!(p, token); wait(p)
tok = "new-$(time_ns())"; p = spawn(tok); sleep(0.5); t0 = time()
kill(p); n = BR.kill_tree!(p, tok); wait(p)
println("NEW kill+kill_tree!: finished=true after ", round(time() - t0; digits = 1), " s survivors=", n, " termsignal=", p.termsignal)
