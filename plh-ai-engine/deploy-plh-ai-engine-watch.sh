#!/usr/bin/env bash
set -euo pipefail

LOG="log.txt"
INTERVAL=300
MAX_LOGS=3

# Rotate old logs: keep only MAX_LOGS copies
# log.txt.3 -> delete, log.txt.2 -> log.txt.3, log.txt.1 -> log.txt.2, log.txt -> log.txt.1
for i in $(seq $((MAX_LOGS - 1)) -1 1); do
    next=$((i + 1))
    if [[ -f "${LOG}.$i" ]]; then
        mv "${LOG}.$i" "${LOG}.$next"
    fi
done
if [[ -f "$LOG" ]]; then
    mv "$LOG" "${LOG}.1"
fi
# Truncate the current log to start fresh
> "$LOG"

# Start the real deploy script in the background
bash deploy-plh-ai-engine.sh >> "$LOG" 2>&1 &
DEPLOY_PID=$!

echo "[watch] Started deploy-plh-ai-engine.sh (PID $DEPLOY_PID)"
echo "[watch] Logging to $LOG"
echo "[watch] Checking every $INTERVAL seconds"

LAST_SIZE=0

while kill -0 "$DEPLOY_PID" 2>/dev/null; do
    CURRENT_SIZE=$(stat -c%s "$LOG")

    if (( CURRENT_SIZE > LAST_SIZE )); then
        echo "=== DEPLOY UPDATE ($(date)) ==="
        tail -n 20 "$LOG"
        echo "=== END UPDATE ==="
        LAST_SIZE=$CURRENT_SIZE
    fi

    sleep "$INTERVAL"
done

echo "[watch] Deploy script finished."
echo "=== FINAL 40 LINES ==="
tail -n 40 "$LOG"
echo "=== END FINAL ==="
