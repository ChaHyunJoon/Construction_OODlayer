#!/usr/bin/env bash
# run1.sh <grid> <lane> <case> <seed> — campaign.py run-one under env -i with the B0 env (b0env.sh)
source "$(dirname "$0")/b0env.sh"
cd "$(dirname "$0")/../../../.."
exec env -i "${B0ENV[@]}" python3 tools/monitor/grid/campaign.py run-one "$@"
