# tools/monitor/smoke_run.jl
# -----------------------------------------------------------------------------
# tractor 를 한 판 돌리며 monitor_stream.jsonl 을 생성하는 스모크 러너.
# 목적: 대시보드의 Assembly Tree / Fleet / (static)MeshCat 이 실데이터로 뜨는지 확인.
# 실행:  ConstructionBots.jl 폴더에서
#        julia +lts --project=. tools/monitor/smoke_run.jl
# 결과:  tools/monitor/monitor_stream.jsonl   (프레임 스트림)
#        tools/monitor/visualization.html     (MeshCat static, iframe 용)
# -----------------------------------------------------------------------------
using ConstructionBots
using Random
const CB = ConstructionBots

here = @__DIR__
stream_path = joinpath(here, "monitor_stream.jsonl")

println("[smoke] enabling monitor stream → ", stream_path)
CB.monitor_enable!(stream_path)
try
    CB.run_lego_demo(;
        ldraw_file        = "tractor.mpd",
        project_name      = "tractor",
        num_robots        = 10,
        assignment_mode   = :greedy,
        save_animation    = true,      # visualization.html 생성(Factory View iframe 용)
        overwrite_results = true,
        rng               = Random.MersenneTwister(1),
    )
finally
    CB.monitor_disable!()
end

# MeshCat static html 을 대시보드 옆으로 복사 → CONFIG.MESHCAT_URL="visualization.html" 로 임베드 가능
viz = joinpath(dirname(pathof(CB)), "..", "results", "tractor",
               "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(viz)
    cp(viz, joinpath(here, "visualization.html"); force=true)
    println("[smoke] copied visualization.html → ", joinpath(here, "visualization.html"))
else
    println("[smoke] visualization.html not found at ", viz)
end

n = isfile(stream_path) ? countlines(stream_path) : 0
println("[smoke] DONE — ", n, " frames → ", stream_path)
