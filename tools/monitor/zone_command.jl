# tools/monitor/zone_command.jl
# 명령 파일에서 **조작자가 확정한 마지막 구역**을 읽는다. 사이드카에 그대로 실어
# "이 런은 사람이 정의한 이 구역으로 출발했다"를 파일 하나로 증명하기 위한 것.
using JSON3

"마지막 forbid_zone 명령. 없으면 nothing. 깨진 줄은 건너뛴다(부분 기록 중일 수 있다)."
function last_zone_command(path::AbstractString)
    (isfile(path) && filesize(path) > 0) || return nothing
    found = nothing
    for line in eachline(path)
        isempty(strip(line)) && continue
        cmd = try JSON3.read(line) catch; continue end
        (try String(cmd[:type]) catch; "" end) == "forbid_zone" || continue
        found = try
            (; id = String(cmd[:id]), x = Float64(cmd[:x]), y = Float64(cmd[:y]), r = Float64(cmd[:r]))
        catch; found end
    end
    return found
end
