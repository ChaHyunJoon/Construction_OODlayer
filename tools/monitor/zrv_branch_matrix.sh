#!/usr/bin/env bash
# zrv_branch_matrix.sh <outroot> [t3_root] — T4 재검증 행렬(순차). 칸마다 `test/repair_branch_isolation.jl … noop`:
# 원래 세계(부모)를 t0 에 세우고 **새 worker 경로**로 NOOP 분기를 돌린 뒤, 부모를 재개해 두 궤적을 전 스텝 비교한다.
# t3_root 를 주면 T3 의 orig-a trace(같은 런타임 코드)와도 비교한다. 한 줄 = "model case seed".
set -u
root=$1; t3=${2:-}
ROOT=/home/chahj578/Construction_OODlayer
mkdir -p "$root"
while read -r model case seed; do
  [ -z "$model" ] && continue
  ep="${model}__${case}__s${seed}"
  orig=""; [ -n "$t3" ] && [ -f "$t3/$ep/orig-a/trace.tsv" ] && orig="$t3/$ep/orig-a/trace.tsv"
  echo "=== $ep $(date +%T) orig=${orig:-none}"
  st=$(date +%s)
  ( cd "$ROOT" && env -i HOME="$HOME" PATH="$PATH" USER="${USER:-}" LANG=C.UTF-8 \
      julia +lts --project="$ROOT" test/repair_branch_isolation.jl "$model" "$case" "$seed" "$root/$ep" noop $orig ) \
      > "$root/$ep.log" 2>&1
  echo "$ep rc=$? $(( $(date +%s) - st ))s" | tee -a "$root/wall.csv"
  grep -E "Test Summary|T4 branch" -A2 "$root/$ep.log" | tail -3
done <<'LIST'
tractor all3 5
tractor zone 10
tractor all3 26
tractor all3 4
tractor zone 9
xwing all3 4
LIST
echo "=== matrix done $(date +%T)"
