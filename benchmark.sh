#!/bin/bash
#=============================================================================
# benchmark.sh — CPU/memory comparison: ICC (FFTW) vs ICC-G (Goertzel)
#
# Sender runs inside mahimahi shell; receiver runs locally on host.
#
# Usage (from HOST):
#   ./benchmark.sh [duration_s] [trials]
#
#   Mahimahi params (env vars, with defaults):
#     MM_DELAY=10                        # one-way delay (ms)
#     MM_TRACE_DL=/path/to/downlink      # mm-link downlink trace
#     MM_TRACE_UL=/path/to/uplink        # mm-link uplink trace
#
# Output: bench_results/
#   {ICC,ICC-G}_trial{N}_{time,perf,rss}.{txt,csv}
#   comparison.csv
#=============================================================================
set -euo pipefail

DURATION=${1:-30}
TRIALS=${2:-5}
OUTDIR=bench_results
PORT=8888

MM_DELAY=${MM_DELAY:-10}
MM_TRACE_DL=${MM_TRACE_DL:-}
MM_TRACE_UL=${MM_TRACE_UL:-}

TIME_CMD=$(command -v /usr/bin/time 2>/dev/null || echo "time")
PERF_OK=false
perf stat -e instructions:u true 2>/dev/null && PERF_OK=true

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
mkdir -p "$OUTDIR"

# ═════════════════════════════════════════════════════════════════════
# run_trials — called inside mahimahi (or directly on host if testing)
# ═════════════════════════════════════════════════════════════════════
run_trials() {
    local SERVER_IP="${MAHIMAHI_BASE:-127.0.0.1}"
    local COMMON_ARGS="serverip=$SERVER_IP offduration=0 onduration=$((DURATION * 1000)) \
lamda_conf=do_ss:compete:auto_theta:auto:1 Bd_conf=10 Rc_conf=30 \
traffic_params=deterministic,num_cycles=1"

    echo "=============================================="
    echo " Benchmark: ICC vs ICC-G"
    echo " Duration: ${DURATION}s  |  Trials: $TRIALS  |  perf: $PERF_OK"
    echo " server: $SERVER_IP:$PORT"
    echo "=============================================="
    echo ""

    for ALGO in ICC ICC-G; do
        local CCTYPE="icc"
        [[ "$ALGO" == "ICC-G" ]] && CCTYPE="iccG"

        for T in $(seq 1 $TRIALS); do
            local NAME="${ALGO}_trial${T}"
            printf "  [%-18s]  " "$NAME"

            local PERF_FILE="/tmp/bench_$$_${ALGO}_${T}.perf"
            local PERF_PREFIX=""
            $PERF_OK && PERF_PREFIX="perf stat -e instructions,cycles,branches,branch-misses,cache-references,cache-misses -o $PERF_FILE --"

            # ── Launch sender ────────────────────────────────
            $PERF_PREFIX $TIME_CMD -v -o "$OUTDIR/${NAME}_time.txt" \
                ./sender $COMMON_ARGS cctype=$CCTYPE \
                > "$OUTDIR/${NAME}_stdout.txt" 2>&1 &
            local PID=$!

            # ── RSS sampling every 0.5s (works across mahimahi netns) ─
            (
                echo "timestamp_s,VmRSS_kB"
                local T0
                T0=$(date +%s.%N)
                while kill -0 $PID 2>/dev/null; do
                    local TS ELAPSED RSS
                    TS=$(date +%s.%N)
                    ELAPSED=$(echo "$TS - $T0" | bc -l 2>/dev/null || echo 0)
                    RSS=$(awk '/VmRSS/{print $2}' /proc/$PID/status 2>/dev/null)
                    echo "$ELAPSED,${RSS:-0}"
                    sleep 0.5
                done
            ) > "$OUTDIR/${NAME}_rss.csv" 2>/dev/null &
            local RSS_PID=$!

            wait $PID 2>/dev/null; local EXIT=$?
            kill $RSS_PID 2>/dev/null; wait $RSS_PID 2>/dev/null || true
            $PERF_OK && mv "$PERF_FILE" "$OUTDIR/${NAME}_perf.txt" 2>/dev/null || true

            if [ $EXIT -eq 0 ]; then
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}exit=$EXIT${NC}"
            fi
        done
        echo ""
    done
}

# ═════════════════════════════════════════════════════════════════════
# Quick summary
# ═════════════════════════════════════════════════════════════════════
quick_summary() {
    echo "====== Quick Summary ======"
    for ALGO in ICC ICC-G; do
        local SUM_USR=0 SUM_RSS=0 CNT=0
        for T in $(seq 1 $TRIALS); do
            local F="$OUTDIR/${ALGO}_trial${T}_time.txt"
            if [ -f "$F" ]; then
                local USR RSS
                USR=$(awk '/User time \(seconds\):/{print $NF}' "$F" 2>/dev/null || echo 0)
                RSS=$(awk '/Maximum resident set size/{print $NF}' "$F" 2>/dev/null || echo 0)
                SUM_USR=$(echo "$SUM_USR + $USR" | bc -l)
                SUM_RSS=$(echo "$SUM_RSS + $RSS" | bc -l)
                CNT=$((CNT + 1))
            fi
        done
        if [ $CNT -gt 0 ]; then
            printf "  %-6s  avg user_time=%8.3fs   avg max_RSS=%8.0fkB   (n=%d)\n" \
                "$ALGO" "$(echo "scale=3; $SUM_USR/$CNT" | bc -l)" \
                "$(echo "scale=0; $SUM_RSS/$CNT" | bc -l)" "$CNT"
        fi
    done
    echo ""
    echo "Full analysis:  python3 analyze_bench_results.py $OUTDIR"
}

# ═════════════════════════════════════════════════════════════════════
# Dispatch: host (launch receiver + mahimahi) vs inside mahimahi
# ═════════════════════════════════════════════════════════════════════

if [[ -n "${MAHIMAHI_BASE:-}" ]]; then
    # Already inside mahimahi → run trials
    echo "[inside mahimahi — MAHIMAHI_BASE=$MAHIMAHI_BASE]"
    run_trials
    quick_summary
    exit 0
fi

# ── On host ─────────────────────────────────────────────────────
echo "===== Host: starting receiver on port $PORT ====="
./receiver $PORT &
RECV_PID=$!
sleep 0.3
if ! kill -0 $RECV_PID 2>/dev/null; then
    echo "ERROR: receiver failed to start"
    exit 1
fi
echo "  receiver PID=$RECV_PID"
trap "kill $RECV_PID 2>/dev/null; wait $RECV_PID 2>/dev/null || true" EXIT

# Build mahimahi command
MM_CMD="mm-delay $MM_DELAY"
if [[ -n "$MM_TRACE_DL" && -n "$MM_TRACE_UL" ]]; then
    MM_CMD="$MM_CMD mm-link $MM_TRACE_DL $MM_TRACE_UL"
fi
echo "  mahimahi:  $MM_CMD"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

$MM_CMD -- bash -c \
    "cd '$SCRIPT_DIR' && MAHIMAHI_BASE=\$MAHIMAHI_BASE '$0' $DURATION $TRIALS"
MM_EXIT=$?

echo ""
echo "===== mahimahi done (exit=$MM_EXIT) ====="
echo ""
quick_summary
