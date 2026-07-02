#!/usr/bin/env bash
# Reproduce & sample the gum dlmalloc allocator wedge
# (GumJS Memory.patchCode race vs concurrent glib alloc/free/realloc churn).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$here/build/tests/gum-tests-unsigned"
test='/GumJS/Script/Memory/code_patch_race_does_not_wedge_allocator#QJS'

threads="${THREADS:-1}"
iters="${ITERS:-20000}"
runs="${RUNS:-1}"
wedge_secs="${WEDGE_SECS:-12}"
build=0

usage () {
  cat <<EOF
usage: $(basename "$0") [-b] [-t THREADS] [-i ITERS] [-n RUNS] [-w SECS]
  -b          ninja -C build first
  -t THREADS  churn threads (default $threads; 1 = real gdbus topology; 0 = baseline, should NOT wedge)
  -i ITERS    Memory.patchCode iterations (default $iters)
  -n RUNS     repeat, report wedge rate (default $runs)
  -w SECS     call it "wedged" if still alive after this long (default $wedge_secs)
  (env THREADS/ITERS/RUNS/WEDGE_SECS also honored)

On the first wedge: samples the process to /tmp/gum-wedge.txt and prints the
waiter (JS thread) and holder (churn thread) stacks.
EOF
}

while getopts "bt:i:n:w:h" o; do
  case $o in
    b) build=1 ;;
    t) threads=$OPTARG ;;
    i) iters=$OPTARG ;;
    n) runs=$OPTARG ;;
    w) wedge_secs=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[ $build -eq 1 ] && { echo "building..."; ninja -C "$here/build" || exit 1; }
[ -x "$bin" ] || { echo "error: $bin not found (build with --enable-gumjs --enable-tests, or pass -b)"; exit 1; }

reap () { pkill -9 -f gum-tests-unsigned 2>/dev/null; }
trap 'reap; exit 130' INT TERM

wedges=0
sampled=0
for r in $(seq 1 "$runs"); do
  GUM_RACE=1 GUM_RACE_THREADS="$threads" GUM_RACE_ITERS="$iters" GUM_RACE_TIMEOUT=100000 \
    "$bin" -p "$test" >/tmp/gum-race.log 2>&1 &
  pid=$!
  alive=1
  for _ in $(seq 1 $(( wedge_secs * 2 ))); do
    sleep 0.5
    kill -0 "$pid" 2>/dev/null || { alive=0; break; }
  done
  if [ $alive -eq 1 ]; then
    wedges=$((wedges + 1))
    echo "run $r/$runs: WEDGED (alive >${wedge_secs}s)"
    if [ $sampled -eq 0 ]; then
      sample "$pid" 3 -mayDie >/tmp/gum-wedge.txt 2>&1
      sampled=1
      echo "  sampled -> /tmp/gum-wedge.txt"
    fi
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  else
    echo "run $r/$runs: ok (no wedge)"
    wait "$pid" 2>/dev/null
  fi
  reap
done

echo "=== wedged $wedges/$runs (threads=$threads iters=$iters) ==="
if [ $sampled -eq 1 ]; then
  echo "--- waiter (JS thread) ---"
  grep -m3 -E "spin_acquire_lock|gumjs_memory_patch_code|mspace_malloc" /tmp/gum-wedge.txt | sed 's/^/  /'
  echo "--- churn/holder frames in dlmalloc (glib alloc/free/realloc) ---"
  grep -E "mspace_realloc|mspace_free|try_realloc_chunk|internal_realloc|g_hash_table_maybe_resize|g_variant_unref" /tmp/gum-wedge.txt \
    | grep -vE "spin_acquire_lock" | sort -u | head -6 | sed 's/^/  /'
  echo "(full sample: /tmp/gum-wedge.txt)"
fi
