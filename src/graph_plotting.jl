# ============================================================================
#  GRAPH PLOTTING : 그래프(노드·엣지)를 보기 좋게 배치(layout)하고 그림으로 그리는 도구
# ----------------------------------------------------------------------------
#  큰 흐름:
#   1) get_graph_layout : 각 노드의 깊이(depth)·폭(width)·좌우 위치를 계산해
#                         트리 모양으로 펼칠 좌표(x, y)를 정한다.
#   2) draw_node / draw_edge : 노드 하나, 엣지 하나를 Compose(벡터 그래픽)로 그린다.
#   3) display_graph : 위 둘을 합쳐 그래프 전체를 캔버스에 그린다.
#  여기서 G/graph 는 MetaGraphs 그래프 — 각 노드에 set_prop!/get_prop 로
#  부가 속성(:depth, :center 등)을 붙여가며 계산한다.
# ============================================================================

# @with_kw : Parameters 패키지 매크로. 이 struct 에 "키워드 인자 생성자"를 자동 생성
#            → BFS_state(d=1, w=2) 처럼 필드 이름을 지정해 만들 수 있음. `= 0` 은 기본값.
# 너비우선탐색(BFS)으로 트리를 훑을 때 들고 다니는 "현재 상태"(깊이·폭 등).
@with_kw struct BFS_state
    d::Int     = 0 # current depth        # 현재 깊이(루트로부터 거리)
	w::Int     = 0 # current width        # 현재까지의 누적 가로 위치(왼쪽부터 센 폭)
	d_max::Int = 0 # max depth so far     # 지금까지 본 최대 깊이
end

# 잎(leaf, 자식 없는 말단) 노드를 만났을 때의 처리. set_prop!(G, v, :키, 값) = 노드 v 에 속성 저장.
function leaf_case!(G,v,s::BFS_state)
    set_prop!(G,v,:height, 0)   # distance to leaf          # 잎까지 거리=0 (자기 자신이 잎)
    set_prop!(G,v,:depth, s.d) # distance to root           # 루트까지 거리=현재 깊이
    set_prop!(G,v,:left,  s.w)                               # 이 노드의 왼쪽 경계 = 현재 폭
    set_prop!(G,v,:width, 1)                                 # 잎의 폭은 1
    set_prop!(G,v,:right, s.w+1)                             # 오른쪽 경계 = 왼쪽+1
    set_prop!(G,v,:center, (get_prop(G,v,:left)+get_prop(G,v,:right))/2.0)  # 중심 = (왼+오)/2
    s = BFS_state(d=s.d,w=s.w+1,d_max=max(s.d_max,s.d))      # 폭을 1 늘리고 최대깊이 갱신한 새 상태 반환
end
# 가지(branch, 자식 있는) 노드를 처음 만났을 때의 초기화.
function initial_branch_case!(G,v,s::BFS_state)
    set_prop!(G,v,:height, 0)   # distance to leaf          # 잎까지 거리(자식들 보며 갱신될 예정)
    set_prop!(G,v,:left,  s.w)                               # 왼쪽 경계 = 현재 폭
    set_prop!(G,v,:depth,  s.d)                              # 루트까지 거리
    set_prop!(G,v,:edge_count,  0)                           # 지금까지 처리한 자식 수 = 0
    set_prop!(G,v,:center, 0.0)                              # 중심 초기값(자식 중심들의 평균으로 갱신됨)
end
# 자식 v2 를 하나 처리하고 부모 v 로 돌아올 때(backup) 부모 속성을 갱신.
function backup!(G,v,v2,s::BFS_state)
    set_prop!(G,v,:height, max(get_prop(G,v,:height),1+get_prop(G,v2,:height)))   # distance to leaf  # 잎까지 거리 = max(기존, 1+자식높이)
    set_prop!(G,v,:right, s.w)                               # 오른쪽 경계 갱신(자식들 다 펼친 만큼)
    set_prop!(G,v,:width, s.w - get_prop(G,v,:left))         # 폭 = 오른쪽 - 왼쪽
    set_prop!(G,v,:edge_count,  1 + get_prop(G,v,:edge_count))  # 처리한 자식 수 +1
    c = get_prop(G,v,:center)                                # 현재까지의 중심 평균
    e = get_prop(G,v,:edge_count)                            # 지금까지 처리한 자식 수
    set_prop!(G,v,:center, c*((e-1)/e) + get_prop(G,v2,:center)*(1/e))  # 중심을 자식들 중심의 누적 평균으로 갱신
end

# 한 단계 더 깊이 내려갈 때(자식으로)의 상태: 깊이 +1. step_out 은 반대(깊이 -1).
step_in(s::BFS_state) = BFS_state(d=s.d+1,w=s.w,d_max=s.d_max)
step_out(s::BFS_state) = BFS_state(d=s.d-1,w=s.w,d_max=s.d_max)

# 재귀 BFS/DFS: 노드 v 에서 시작해 부모 방향(inneighbors)으로 트리를 훑으며 위 속성들을 채운다.
# visited=Set{Int}() : 이미 방문한 노드 집합(기본 빈 집합). enforce_visited : 방문체크를 강제할지 여부.
function bfs!(G,v,s,visited=Set{Int}(),enforce_visited=false)
    s = step_in(s)                                  # 깊이 한 단계 내려감
    if indegree(G,v) == 0                           # 들어오는 엣지가 없으면(=잎 노드)
        s = leaf_case!(G,v,s)                        # 잎 처리
    else                                            # 자식이 있으면(가지)
        initial_branch_case!(G,v,s)                  # 가지 초기화
        for v2 in inneighbors(G,v)                  # 각 자식(부모방향 이웃) v2 에 대해
            if !(v2 in visited) || !enforce_visited # 아직 방문 안 했거나 방문강제가 꺼져있으면
                s = bfs!(G,v2,s,visited,enforce_visited)  # 자식으로 재귀
                backup!(G,v,v2,s)                    # 돌아와서 부모 속성 갱신
            end
        end
    end
    push!(visited,v)                                # v 를 방문 처리(집합에 추가)
    return step_out(s)                              # 깊이 한 단계 올라간 상태 반환
end

# abstract type = "추상 타입"(직접 만들 수 없고, 하위 타입들을 묶는 분류용 부모). 파이썬의 추상 베이스 클래스 비슷.
abstract type GraphInfoFeature end
# 아래는 모두 빈 struct(필드 없음) — "어떤 레이아웃 특징을 계산할지" 골라주는 라벨 역할.
# <: GraphInfoFeature = 위 추상 타입의 하위 타입. 다중 디스패치로 특징별 계산 메서드를 구분하는 데 쓰임.
struct ForwardDepth <: GraphInfoFeature end     # 전방(루트→잎) 깊이
struct BackwardDepth <: GraphInfoFeature end    # 후방(잎→루트) 깊이
struct ForwardWidth <: GraphInfoFeature end     # 전방 폭
struct BackwardWidth <: GraphInfoFeature end    # 후방 폭
struct VtxWidth <: GraphInfoFeature end         # 노드 자체의 폭
struct ForwardIndex <: GraphInfoFeature end     # 전방 가로 인덱스(왼쪽부터 몇 번째 위치)
struct ForwardCenter <: GraphInfoFeature end    # 전방 기준 중심 x좌표
struct BackwardIndex <: GraphInfoFeature end    # 후방 가로 인덱스
struct BackwardCenter <: GraphInfoFeature end   # 후방 기준 중심 x좌표

"""
    Track the width of the tree above a node, and the parent of that tree
"""
struct ForwardTreeWidth <: GraphInfoFeature end   # 한 노드 위쪽 서브트리의 폭 추적
struct BackwardTreeWidth <: GraphInfoFeature end  # 아래쪽 서브트리의 폭 추적
# initial_value : 각 특징의 초기값을 정하는 함수(특징 타입별로 다른 메서드). 트리폭은 빈 딕셔너리에서 시작.
initial_value(f::Union{ForwardTreeWidth,BackwardTreeWidth}) = Dict{Int,Int}()
# forward_propagate : 자식 v2 의 값을 부모 v 로 "전파"하는 규칙(특징마다 다름). 여기선 키별 최댓값을 합침.
function forward_propagate(::ForwardTreeWidth,G,v,v2,vec)
    for (k,val) in vec[v2]                       # 자식의 딕셔너리 (키 k, 값 val) 순회
        vec[v][k] = max(get(vec[v],k,0),val)     # 부모의 같은 키 값과 비교해 더 큰 값으로 갱신(없으면 0 기준)
    end
end
# 후방 전파도 동일 로직(방향만 반대).
function backward_propagate(::BackwardTreeWidth,G,v,v2,vec)
    for (k,val) in vec[v2]
        vec[v][k] = max(get(vec[v],k,0),val)
    end
end
# backward_propagate(::BackwardTreeWidth,G,v,v2,vec) = merge(vec[v],vec[v2])   # (옛 코드 — 무시)
# forward_accumulate : 한 노드에서 들어온 값들을 "누적·초기화"하는 규칙. 잎 노드면 자기 자신을 폭 1로 등록.
function forward_accumulate(::ForwardTreeWidth,G,v,vtxs,vec)
    if indegree(G,v) == 0                        # 들어오는 엣지가 없으면(잎)
        vec[v][v] = 1                            # 자기 자신 키에 폭 1
    end
    return vec[v]
end
# 후방 누적: 나가는 엣지가 없으면(=후방 기준 잎) 자기 자신을 폭 1로.
function backward_accumulate(::BackwardTreeWidth,G,v,vtxs,vec)
    if outdegree(G,v) == 0
        vec[v][v] = 1
    end
    return vec[v]
end



# 아래는 "기본(fallback) 규칙" — 특정 특징용 메서드가 없으면 이게 적용됨. `f` 에 타입 지정이 없어 무엇이든 받음.
initial_value(f) = 1.0                           # 기본 초기값 1.0
initial_value(f::Union{ForwardDepth,BackwardDepth}) = 1   # 깊이 특징은 정수 1에서 시작
forward_propagate(f,G,v,v2,vec) = vec[v]         # 기본 전파: 그대로 둠(변화 없음)
backward_propagate(f,G,v,v2,vec) = vec[v]
forward_accumulate(f,G,v,vtxs,vec) = vec[v]      # 기본 누적: 그대로 둠
backward_accumulate(f,G,v,vtxs,vec) = vec[v]

# 깊이 계산: 부모 깊이 = max(기존, 자식깊이+1) → 가장 깊은 경로 기준 깊이.
backward_propagate(::BackwardDepth, G,v,v2,vec) = max(vec[v],vec[v2]+1)
forward_propagate(::ForwardDepth,	G,v,v2,vec) = max(vec[v],vec[v2]+1)
# 폭 계산: 자식 폭을 자식의 (나가는/들어오는) 차수로 나눠 나눠 가지는 효과. v2->... 는 익명함수(파이썬 lambda).
forward_propagate(::ForwardWidth,	G,v,v2,vec) = max(vec[v],vec[v2]/max(1,outdegree(G,v2)))
backward_propagate(::BackwardWidth, G,v,v2,vec) = max(vec[v],vec[v2]/max(1,indegree(G,v2)))
# 폭 누적: 모든 이웃 vtxs 의 (폭/차수) 합과 기존값 중 큰 쪽. `...` 는 배열을 인자들로 펼침(splat), [0, ...] 는 빈 합 대비 0 포함.
forward_accumulate(::ForwardWidth,	G,v,vtxs,vec) = max(vec[v],sum([0,map(v2->vec[v2]/outdegree(G,v2),vtxs)...]))
backward_accumulate(::BackwardWidth,G,v,vtxs,vec) = max(vec[v],sum([0,map(v2->vec[v2]/indegree(G,v2),vtxs)...]))

# 전방 패스: 위상정렬 순서(부모가 먼저)대로 돌며 각 특징값을 누적·전파한다.
# feat_vals 기본값 : 각 특징 f 마다, 모든 정점에 initial_value(f) 를 채운 딕셔너리(=> 는 키=>값 쌍).
function forward_pass!(G,feats,feat_vals=Dict(f=>map(v->initial_value(f),Graphs.vertices(G)) for f in feats))
	for v in topological_sort_by_dfs(G)             # 위상정렬 순서로 각 정점 v
		for (f,vec) in feat_vals                    # 각 특징 f 와 그 값 배열 vec
			vec[v] = forward_accumulate(f,G,v,inneighbors(G,v),vec)  # 들어오는 이웃들로부터 누적
			for v2 in inneighbors(G,v)              # 각 부모방향 이웃 v2 로부터
				vec[v] = forward_propagate(f,G,v,v2,vec)  # 값을 전파해 갱신
			end
		end
    end
    return feat_vals                                # 채워진 특징값 딕셔너리 반환
end
# 후방 패스: 위상정렬을 뒤집어(잎이 먼저) 반대 방향으로 같은 일을 한다.
function backward_pass!(G,feats,feat_vals=Dict(f=>map(v->initial_value(f),Graphs.vertices(G)) for f in feats))
	for v in reverse(topological_sort_by_dfs(G))    # 역순으로 각 정점 v
		for (f,vec) in feat_vals
			vec[v] = backward_accumulate(f,G,v,outneighbors(G,v),vec)  # 나가는 이웃들로부터 누적
			for v2 in outneighbors(G,v)             # 각 자식방향 이웃 v2 로부터
				vec[v] = backward_propagate(f,G,v,v2,vec)  # 값을 전파해 갱신
			end
		end
    end
    return feat_vals
end

# 그래프 G 의 레이아웃(각 노드의 깊이·폭·인덱스·중심)을 한꺼번에 계산해 딕셔너리로 반환.
# `;` 뒤 enforce_visited 는 키워드 인자. feats 는 계산할 특징 목록(기본 4개).
function get_graph_layout(
        G,feats=[ForwardDepth(),BackwardDepth(),ForwardWidth(),BackwardWidth()];
        enforce_visited=false,
)
    @assert !is_cyclic(G)                           # 사이클 없는 그래프(DAG)여야 함 — 아니면 에러
    feat_vals = forward_pass!(G,feats)              # 전방 패스로 깊이/폭 등 계산
    feat_vals = backward_pass!(G,feats,feat_vals)   # 후방 패스로 보완
	feat_vals[VtxWidth()] = max.(feat_vals[ForwardWidth()],feat_vals[BackwardWidth()])  # 노드폭 = 전방/후방 폭의 원소별 최댓값(.max 의 `.` 은 브로드캐스트)

    graph = MetaDiGraph(nv(G))                      # 같은 정점 수의 빈 메타방향그래프 생성(속성 저장용 사본)
    for e in edges(G)                               # 원본의 모든 엣지를
        add_edge!(graph,e)                          # 사본에 그대로 복사
    end
	end_vtxs = [v for v in Graphs.vertices(graph) if outdegree(graph,v) == 0]  # 나가는 엣지가 없는 말단 정점들(컴프리헨션)
	s = BFS_state(0,0,0)                            # 초기 BFS 상태(깊이0, 폭0, 최대깊이0)
	for v in end_vtxs                              # 각 말단에서 시작해
		s = bfs!(graph,v,s,Set{Int}(),enforce_visited)  # BFS 로 left/center 등 속성 채움
	end
	# 전방·후방 두 방향에 대해 같은 인덱스 계산을 반복. 각 줄은 (인덱스키, 중심키, 깊이키) 묶음.
	for (idx_key, ctr_key, depth_key) in [
            (ForwardIndex(), ForwardCenter(), ForwardDepth()),
            ((BackwardIndex(), BackwardCenter(), BackwardDepth()))
        ]
		vec = feat_vals[depth_key]                  # 이 방향의 깊이 배열
		forward_width_counts = map(v->Int[],1:maximum(vec))  # 깊이별로 노드를 담을 빈 배열들(깊이 1..최대깊이)
		forward_idxs = zeros(nv(G))                 # 각 노드의 가로 위치(0으로 초기화)
		backward_idxs = zeros(nv(G))                # (사용 안 하는 보조 배열)
		for v in topological_sort_by_dfs(G)         # 위상정렬 순서로
			push!(forward_width_counts[vec[v]],v)   # 노드 v 를 자기 깊이 칸에 모음
		end
		for vec in forward_width_counts             # 같은 깊이(한 행)에 있는 노드들 vec 마다
			sort!(vec,by=v->get_prop(graph,v,:left))  # 왼쪽 위치 기준으로 정렬(왼→오 순서로)
			for (i,v) in enumerate(vec)             # 그 행의 각 노드 v (행 안 순번 i)
				if i > 1                            # 첫 노드가 아니면
					v2 = vec[i-1]                   # 바로 왼쪽 노드 v2
					forward_idxs[v] += forward_idxs[v2] + feat_vals[VtxWidth()][v2]  # 왼쪽 노드 위치+폭 만큼 오른쪽으로 밀기(겹침 방지)
				end
				if indegree(G,v) > 0                # 자식(부모방향 이웃)이 있으면
					min_idx = minimum(map(v2->forward_idxs[v2],inneighbors(G,v)))  # 자식들 위치의 최솟값
					forward_idxs[v] = max(forward_idxs[v],min_idx)  # 자식들 위에 정렬되도록 위치 보정
					for v2 in vec[1:i-1]            # 같은 행 왼쪽 노드들과
						forward_idxs[v] = max(forward_idxs[v],forward_idxs[v2]+feat_vals[VtxWidth()][v2])  # 다시 겹치지 않게 보정
					end
				end
			end
		end
		feat_vals[idx_key] = forward_idxs           # 계산한 가로 인덱스 저장
		feat_vals[ctr_key] = forward_idxs .+ 0.5*feat_vals[VtxWidth()]  # 중심 = 인덱스 + 폭/2 (원소별 덧셈 .+)
	end

	feat_vals                                       # 모든 레이아웃 정보가 담긴 딕셔너리 반환
end

# Node plotting utilities
# 아래는 노드의 글자/색/모양 기본값을 정하는 헬퍼들. 사용자가 노드 타입별로 메서드를 덮어써 커스터마이즈 가능.
_title_string(n::Int) = string(n)               # 노드가 정수면 그 숫자를 제목 문자열로
_title_string(n) = ""                           # 그 외엔 제목 없음(빈 문자열)
_subtitle_string(n) = ""                         # 부제목 기본값: 없음
_node_color(n) = "red"                           # 노드 테두리 색 기본값: 빨강
_node_bg_color(n) = "white"                      # 노드 배경 색 기본값: 흰색
_text_color(n) = _node_color(n)                  # 글자색 기본값: 테두리 색과 동일
_node_shape(n,t=0.1) = Compose.circle(0.5, 0.5, 0.5-t/2)  # 노드 모양 기본값: 원(반지름은 선두께 t 만큼 줄임)
_title_text_scale(n) = 0.6                       # 제목 글자 크기 비율
_subtitle_text_scale(n) = 0.2                    # 부제목 글자 크기 비율
# _node_shape(n,t) = Compose.circle(0.5, 0.5, 0.5-t/2)   # (옛 코드 — 무시)
# 메타프로그래밍: 위 함수들에 "(graph, v) 형태로도 부를 수 있는" 버전을 자동 생성.
# 즉 그래프와 정점을 받으면 정점만 떼어 원래 함수를 부른다. `args...` 는 나머지 인자들을 모두 받아 그대로 넘김.
for op in (:_node_shape,:_node_color,:_subtitle_string,:_text_color,:_title_string)
    @eval $op(graph::AbstractGraph,v,args...) = $op(v,args...)
end

# 노드 하나를 그린다 — 제목/부제목 텍스트 + 모양(원 등)을 Compose 그래픽으로 합성.
# `;` 뒤는 모두 키워드 인자(기본값은 위 헬퍼들에서 가져옴). Compose 좌표는 0~1 단위박스 기준.
function draw_node(n;
        t=0.1, # line thickness                         # 테두리 선 두께
        title_scale=_title_text_scale(n),               # 제목 글자 크기
        subtitle_scale=_subtitle_text_scale(n),         # 부제목 글자 크기
        bg_color=_node_bg_color(n),                     # 배경색
        text_color=_text_color(n),                      # 글자색
        node_color=_node_color(n),                      # 테두리색
        title_text = _title_string(n),                  # 제목 문자열
        subtitle_text = _subtitle_string(n),            # 부제목 문자열
        )
    title_y = 0.5                                       # 제목 세로 위치(중앙)
    if !isempty(subtitle_text)                          # 부제목이 있으면
        title_y -= subtitle_scale/2                     # 제목을 살짝 위로 올려 자리 확보
    end
    subtitle_y = title_y + (title_scale)/2              # 부제목은 제목 아래에 배치

    # Compose.compose(부모, 자식들...) : 그래픽 요소들을 겹쳐 하나로 합성(파이썬으로 치면 그룹 만들기).
    Compose.compose(context(),
        (context(),                                     # ① 제목 텍스트 그룹
            Compose.text(0.5, title_y, title_text, hcenter, vcenter),  # (가운데, title_y)에 가운데정렬 텍스트
            Compose.fill(text_color),                   # 글자색 채우기
            fontsize(title_scale*min(w,h))              # 글자 크기(폭·높이 중 작은 쪽 기준)
            ),
        (context(),                                     # ② 부제목 텍스트 그룹
            Compose.text(0.5, subtitle_y, subtitle_text, hcenter, vcenter),
            Compose.fill(text_color),
            Compose.fontsize(subtitle_scale*min(w,h))
            ),
        (context(),                                     # ③ 노드 모양(원) 그룹
            _node_shape(n,t),                           # 모양(기본 원)
            fill(bg_color),                             # 배경색 채우기
            Compose.stroke(node_color),                 # 테두리색
            Compose.linewidth(t*w)                      # 선 두께(가로폭 w 비례)
            ),
        )
end
# (graph, v) 형태로 불러도 동작하는 버전 — 그래프는 무시하고 v 만 넘김. `kwargs...` 는 키워드 인자들을 통째로 전달.
draw_node(graph,v;kwargs...) = draw_node(v;kwargs...)

# display_graph 가 기본으로 쓰는 노드 그리기 함수. stroke_width 를 선두께 t 로 넘겨 draw_node 호출.
function default_draw_node(G,v;fg_color="red",bg_color="white",stroke_width=0.1)
    draw_node(G,v;t=stroke_width)
end

# 엣지(두 점 pt1→pt2)를 직선으로 그리는 기본 함수. 한 줄 함수가 튜플 그래픽을 반환.
default_draw_edge(G,v1,v2,pt1,pt2;fg_color="blue",stroke_width=0.01) = (
    context(),
        Compose.line([pt1,pt2]),                        # pt1 에서 pt2 로 직선
        Compose.stroke(fg_color),                       # 선 색
        Compose.linewidth(stroke_width*w),              # 선 두께
)

# 직각(ㄱ자)으로 꺾이는 엣지 그리기 — 두 점 사이 중간 높이에서 한 번 꺾어 연결.
function draw_ortho_edge(G,v1,v2,pt1,pt2;fg_color="blue",stroke_width=0.01)
    ymid = (pt1[2]+pt2[2])/2                            # 두 점의 중간 y좌표
    (context(),
        Compose.line([pt1,(pt1[1],ymid),(pt2[1],ymid),pt2]),  # pt1→(꺾임)→(꺾임)→pt2 의 꺾인 선
        Compose.stroke(fg_color),
        Compose.linewidth(stroke_width*w),)
end

"""
    display_graph(graph;kwargs...)

Plot a graph.
"""
# 그래프 전체를 그린다. 레이아웃 계산 → 정렬/방향 조정 → 좌표 정규화 → 노드·엣지 합성.
# draw_node_function / draw_edge_function 은 노드·엣지를 그리는 방식을 바꿔 끼울 수 있게 받는 콜백(익명함수).
function display_graph(graph;
        draw_node_function = (G,v)->default_draw_node(G,v),                    # 노드 그리기 함수(기본값)
        draw_edge_function = (G,v,v2,pt1,pt2)->default_draw_edge(G,v,v2,pt1,pt2),  # 엣지 그리기 함수(기본값)
        grow_mode=:from_bottom, # :from_left, :from_bottom, :from_top,         # 트리가 자라는 방향(:심볼 라벨)
        align_mode=:leaf_aligned, # :root_aligned                             # 정렬 기준(잎/루트 기준 등)
        node_size = (0.75,0.75),                                              # 노드 한 칸의 (가로, 세로) 크기
        scale=1.0,                                                            # 전체 확대 비율
        pad = (0.5,0.5),                                                      # 캔버스 바깥 여백
        aspect_stretch=(1.0,1.0),                                             # 가로·세로 늘이기 비율
        bg_color="white",                                                     # 배경색
        enforce_visited=false                                                 # BFS 방문 강제 여부
    )

    feat_vals = get_graph_layout(graph; enforce_visited=enforce_visited)  # 위에서 만든 레이아웃 계산
    # alignment  (정렬 모드에 따라 각 노드의 x, y 좌표를 깊이/중심 값으로 정함)
    if align_mode == :leaf_aligned                  # 잎 기준 정렬
        x = feat_vals[ForwardDepth()]               # x = 전방 깊이
	    y = feat_vals[ForwardCenter()]              # y = 전방 중심
    elseif align_mode == :root_aligned              # 루트 기준 정렬
        x = feat_vals[BackwardDepth()]              # x = 후방 깊이
		x = 1 + maximum(x) .- x                     # 깊이를 뒤집어(루트가 한쪽 끝에 오게) .- 는 원소별 뺄셈
        y = feat_vals[BackwardCenter()]
    elseif align_mode == :split_aligned             # 분할 정렬(루트에서부터 자식 위치를 따라 내려가며 x 재배치)
        x = feat_vals[ForwardDepth()]
	    y = feat_vals[ForwardCenter()]
        # Start with the root node, which is the max x value for forward_depth
        root_node = argmax(x)                       # x(깊이)가 최대인 노드 = 루트
        parents = [root_node]                       # 현재 층의 노드들(루트부터 시작)
        temp_parents = []                           # 다음 층 노드들 임시 저장
        while !isempty(parents)                     # 더 거슬러 올라갈 부모가 있는 동안
            for parent in parents                   # 현재 층의 각 부모에 대해
                for v in inneighbors(graph, parent) # 그 부모의 자식(부모방향 이웃) v 들에 대해
                    push!(temp_parents, v)          # 다음 층 후보로 추가
                    for vc in outneighbors(graph, v)  # v 의 자식방향 이웃 vc 들
                        if vc == parent             # 방금 온 부모면
                            continue                # 건너뜀
                        end
                        x[vc] = x[parent]           # 형제들을 부모와 같은 x 에 맞춤
                    end
                    x[v] = x[parent] - 1            # v 는 부모보다 한 칸 앞에 배치
                end
            end
            parents = temp_parents                  # 다음 층으로 이동
            temp_parents = []                       # 임시 목록 비움
        end

    else
        throw(ErrorException("Unknown align_mode $align_mode"))  # 모르는 정렬모드면 에러
    end
    # growth direction  (자라는 방향에 맞춰 x, y 축을 회전/반전)
    if grow_mode == :from_left
        # do nothing                                # 왼→오: 그대로
    elseif grow_mode == :from_right
        x = -x                                      # 오→왼: x 반전
    elseif grow_mode == :from_bottom
        x, y = y, -x                                # 아래→위: 축 교환 + 뒤집기 (한 줄에 두 변수 동시 대입)
    elseif grow_mode == :from_top
        x, y = y, x                                 # 위→아래: 축 교환
    else
        throw(ErrorException("Unknown grow_mode $grow_mode"))  # 모르는 방향이면 에러
    end
    # ensure positive and shift to be on the canvas (how to shift the canvas instead?)
    x *= aspect_stretch[1]                          # 가로 비율 적용
    y *= aspect_stretch[2]                          # 세로 비율 적용
	x = x .- minimum(x) .+ node_size[1]/2# .+ pad[1]  # x 를 0 이상으로 평행이동(최솟값 빼고 노드 반칸만큼 띄움)
    y = y .- minimum(y) .+ node_size[2]/2# .+ pad[2]  # y 도 동일하게 평행이동
    context_size=(maximum(x) + node_size[1]/2, maximum(y)+node_size[2]/2)  # 그림 내용 영역 크기
	canvas_size   = (context_size[1] .+ 2*pad[1], context_size[2] .+ 2*pad[2])  # 여백 포함 전체 캔버스 크기
    set_default_graphic_size(                       # 출력 그림의 기본 물리 크기 설정
        (scale*canvas_size[1])cm,                   # 가로 [cm] (숫자 뒤 cm = 단위 리터럴)
        (scale*canvas_size[2])cm                    # 세로 [cm]
        )

    # 한 노드를 (a,b) 위치에 놓을 좌표계(context)를 만드는 헬퍼. units=UnitBox(...) 는 내부를 0~1 단위로 봄.
    node_context(a,b,s=node_size) = context(
        (a-s[1]/2),                                 # 노드 중심을 (a,b)에 맞추려 좌상단으로 반칸 이동
        (b-s[2]/2),
        s[1],                                       # 폭
        s[2],                                       # 높이
        units=UnitBox(0.0,0.0,1.0,1.0),
        )
    edge_context(a,b) = context(a,b,1.0,1.0,units=UnitBox(0.0,0.0,1.0,1.0))  # 엣지용 좌표계(시작점 (a,b))
    # 각 정점마다 (위치 컨텍스트, 그려진 노드) 쌍을 만든다. map(함수, 컬렉션) = 각 원소에 함수 적용.
    nodes = map(
        v->(node_context(x[v],y[v]), draw_node_function(graph,v)), Graphs.vertices(graph)
    )
    lines = []                                      # 엣지 그래픽들을 담을 배열
    for e in edges(graph)                           # 각 엣지 e 에 대해
        dx = x[e.dst] - x[e.src]                    # 끝점-시작점의 x 차이
        dy = y[e.dst] - y[e.src]                    # y 차이
        push!(lines,                                # (시작점 컨텍스트, 그려진 엣지)를 추가
            (edge_context(x[e.src],y[e.src]),
            draw_edge_function(
                graph,e.src,e.dst,(0.0,0.0),(dx,dy)  # 시작점을 (0,0) 기준으로, 끝점을 (dx,dy)로 그림
                ))
        )
    end
    # 최종 합성: 전체 캔버스 위에 (노드들 + 엣지들)을 얹고, 맨 아래 배경 사각형을 깐다. `...` 는 배열을 인자들로 펼침.
    Compose.compose( context(units=UnitBox(0.0,0.0,canvas_size...)),
        (
            context(pad[1],pad[2],context_size...,units=UnitBox(0.0,0.0,context_size...)),  # 여백만큼 안쪽으로 들어간 내용 영역
            nodes...,                               # 노드 그래픽들 펼쳐 넣기
            lines...,                               # 엣지 그래픽들 펼쳐 넣기
        ),
        Compose.compose(context(),rectangle(),fill(bg_color))  # 배경 사각형(맨 뒤)
    )
end
