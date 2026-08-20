#!/usr/bin/env bash
# =============================================================================
# publish_streams.sh -- 스윕이 남긴 스트림을 모니터 대시보드가 찾는 **이름**으로 발행한다.
#
# 두 이름 규칙이 어긋나 있는 것이 문제의 전부다:
#
#   스윕이 쓴 자리   results_4pol/shards/<case>/s<seed>/logs/stream_s<seed>_<policy>.jsonl
#   대시보드가 찾는 자리  tools/monitor/streams/<base>__<case>__<policy><nsuf>.jsonl
#
# 오른쪽 규칙은 server.jl 의 `/artifact` 핸들러(server.jl:242-248)가 정한다:
#   base  = safe_base(model)            -- "tractor.mpd" → "tractor"
#   psuf  = policy 가 있으면 "__<policy>"
#   nsuf  = (n>0 ? "_n<n>" : "") * seed_suffix(seed),  seed_suffix(1) == ""   (server.jl:69)
# 대시보드의 기본 UI 값은 OOD events=0 · OOD seed=1 (dashboard.html:339,343) 이므로
# 기본 발행본의 nsuf 는 **빈 문자열**이다 → `tractor__all__noop.jsonl`.
#
# 원본은 판당 ~1.1 MB · 630 판(~700 MB)이라 복사하지 않고 **심링크**를 건다.
# 발행물은 .gitignore 로 배제돼 있다(tools/monitor/streams/).
#
# 사용:
#   ./render/publish_streams.sh                          # 기본: 7 case x 3 policy x seed 1 = 21 개
#   ./render/publish_streams.sh --clean                  # streams/ 를 비우고 새로 발행
#   ./render/publish_streams.sh --seeds 1,2,3            # 여러 시드(seed 1 만 접미사 없음, 나머지는 _sN)
#   ./render/publish_streams.sh --cases all,zone --policies noop,dspy
# =============================================================================
set -euo pipefail

# 2026-08-18 폴더 분류: 이 스크립트가 render/ 로 내려갔다. HERE=render/ ·
# WM=wm4spacecraft_manufacturing/ (샤드 트리 기준) · REPO=레포 루트(tools/ 가 있는 곳).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WM="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$WM/.." && pwd)"
DEST="$REPO/tools/monitor/streams"

# 대시보드의 모델 선택기 기본값. safe_base() 와 같은 변환(확장자 제거 + 비영숫자 → "_").
MODEL="tractor.mpd"
BASE="$(printf '%s' "${MODEL%.*}" | sed 's/[^A-Za-z0-9][^A-Za-z0-9]*/_/g')"

SEEDS="1"
CASES="battery,fault,all,fault_battery,fault_zone,battery_zone,zone"
POLICIES="noop,surrogate,dspy"
SHARDS_DIR="results_4pol/shards"
CLEAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --seeds)       SEEDS="$2";      shift 2 ;;
        --cases)       CASES="$2";      shift 2 ;;
        --policies)    POLICIES="$2";   shift 2 ;;
        --shards-dir)  SHARDS_DIR="$2"; shift 2 ;;
        --clean)       CLEAN=1;         shift ;;
        -h|--help)     sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# 상대 경로면 이 스크립트가 있는 폴더 기준으로 푼다(어디서 부르든 같은 자리를 보게).
[[ "$SHARDS_DIR" = /* ]] || SHARDS_DIR="$WM/$SHARDS_DIR"   # 샤드 트리는 wm4 폴더 기준
[[ -d "$SHARDS_DIR" ]] || { echo "shards dir not found: $SHARDS_DIR" >&2; exit 1; }

mkdir -p "$DEST"
if [[ $CLEAN -eq 1 ]]; then
    # 링크만 지운다. 이 폴더는 옛 데모 녹화도 담을 수 있으므로 rm -rf 로 통째 날리지 않는다.
    find "$DEST" -maxdepth 1 -name '*.jsonl' -exec rm -f {} +
    echo "[clean] emptied $DEST"
fi

published=0
missing=0
for seed in ${SEEDS//,/ }; do
    # server.jl:69 seed_suffix -- seed 1 만 접미사가 없다(기본 녹화 이름 그대로).
    if [[ "$seed" == "1" ]]; then ssuf=""; else ssuf="_s$seed"; fi
    for case in ${CASES//,/ }; do
        for pol in ${POLICIES//,/ }; do
            src="$SHARDS_DIR/$case/s$seed/logs/stream_s${seed}_${pol}.jsonl"
            dst="$DEST/${BASE}__${case}__${pol}${ssuf}.jsonl"
            if [[ ! -f "$src" ]]; then
                echo "  MISSING  $case/s$seed/$pol  ($src)" >&2
                missing=$((missing + 1))
                continue
            fi
            ln -sfn "$src" "$dst"
            printf '  %-44s -> %s\n' "$(basename "$dst")" "${src#"$SHARDS_DIR"/}"
            published=$((published + 1))
        done
    done
done

# 심링크 대상의 실제 크기(-L 로 따라간다). 링크 자체는 몇 바이트뿐이라 -L 없이는 뜻이 없다.
total="$(find "$DEST" -maxdepth 1 -name '*.jsonl' -print0 | du -Lch --files0-from=- 2>/dev/null | tail -1 | cut -f1)"
echo "published: $published stream(s) into $DEST  (total ${total:-0})"
[[ $missing -gt 0 ]] && { echo "missing: $missing" >&2; exit 1; }
exit 0
