# tools/monitor/run_header.jl
# =============================================================================================
#  라이브 런 사이드카 — "이 스트림은 어느 런의 것인가"를 파일 하나로 못박는다.
# ---------------------------------------------------------------------------------------------
#  왜 스트림 안이 아니라 옆 파일인가: 이 저장소에서 스트림 jsonl 을 읽는 도구가 최소 네 곳이고
#  (verify_depot_station.py / artifacts_to_html.py / diag_stall.py / verify_night.py) 전부 **모든 줄을
#  프레임으로** 읽는다. 첫 줄에 헤더를 끼우면 그 넷이 조용히 깨진다. 사이드카는 아무도 안 건드린다.
#
#  왜 별도 파일인가: render_demo.jl 은 include 하면 데모 전체가 돌아버려 단위검사를 못 붙인다.
# =============================================================================================
using JSON3

# 이름이 server.jl 의 run_info_path(key) 와 **달라야 한다.** 둘 다 문자열을 받으므로 같은 이름으로
# 두면 다중 디스패치가 구분하지 못하고, 더 구체적인 쪽(AbstractString)이 서버 정의를 가려
# 엉뚱한 경로가 나온다(엔진과 서버가 서로 다른 파일을 보게 된다).
"명령 파일 경로 → 사이드카 경로. server.jl 의 run_info_path(key) 와 **같은 파일**을 가리켜야 한다."
run_info_path_of(cmdfile::AbstractString) =
    isempty(cmdfile) ? "" :
    joinpath(dirname(cmdfile), splitext(basename(cmdfile))[1] * ".run.json")

"""
    run_info(; run_id, case, requires_zone, started_at, stream, zone=nothing)

사이드카 레코드. `zone` 은 조작자가 확정한 구역이며 게이트가 있는 런에서만 채워진다
(게이트가 없는 런은 `nothing` = JSON 의 null).
"""
function run_info(; run_id::AbstractString, case::AbstractString, requires_zone::Bool,
                  started_at::Real, stream::AbstractString, zone = nothing)
    return (; run_id = String(run_id), case = String(case), requires_zone = requires_zone,
            started_at = Float64(started_at), stream = String(stream), zone = zone)
end

"사이드카를 원자적으로 쓴다. 대시보드가 반쯤 쓰인 파일을 읽고 JSON 파싱에 실패하면 안 된다."
function write_run_info(path::AbstractString, info)
    isempty(path) && return ""
    mkpath(dirname(path))
    tmp = path * ".tmp"
    open(tmp, "w") do io
        println(io, JSON3.write(info))
    end
    mv(tmp, path; force = true)
    return path
end
