#!/bin/bash
REFRESH=${REFRESH_SECONDS:-30}
OUTPUT=/output/index.html

mkdir -p /output

# Static hardware info (collected once)
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)
CPU_THREADS=$(grep -c "^processor" /proc/cpuinfo)
CPU_CORES=$(grep "^core id" /proc/cpuinfo | sort -u | wc -l)
CPU_MAX_MHZ=$(awk '{printf "%.0f", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "")
MEM_TOTAL_GiB=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)

while true; do
    TIMESTAMP=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
    SMI_OUTPUT=$(nvidia-smi 2>&1)

    CPU_CUR_MHZ=$(awk '/cpu MHz/ {sum+=$4; n++} END {printf "%.0f", sum/n}' /proc/cpuinfo)
    MEM_AVAIL_GiB=$(awk '/MemAvailable/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
    MEM_USED_GiB=$(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%.1f", (t-a)/1024/1024}' /proc/meminfo)

    {
        cat <<HTMLHEAD
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>GPU Status</title>
  <meta http-equiv="refresh" content="${REFRESH}">
  <style>
    body { font-family: 'Courier New', monospace; background: #1a1a2e; color: #e0e0e0; padding: 2em; margin: 0 auto; }
    h2 { color: #7fdbff; margin-bottom: 0.8em; }
    .hw { border-collapse: collapse; margin-bottom: 2em; }
    .hw td { padding: 0.25em 1.5em 0.25em 0; vertical-align: top; }
    .hw td:first-child { color: #7fdbff; white-space: nowrap; }
    pre { white-space: pre; }
    .ts { color: #555; font-size: 0.85em; margin-top: 1.5em; }
  </style>
</head>
<body>
  <h2>System Status</h2>
  <table class="hw">
    <tr><td>CPU</td><td>${CPU_MODEL}</td></tr>
    <tr><td>Cores</td><td>${CPU_CORES} cores / ${CPU_THREADS} threads</td></tr>
HTMLHEAD

        if [[ -n "$CPU_MAX_MHZ" ]]; then
            printf '    <tr><td>Clock</td><td>%s MHz current &nbsp;/&nbsp; %s MHz max boost</td></tr>\n' \
                "$CPU_CUR_MHZ" "$CPU_MAX_MHZ"
        else
            printf '    <tr><td>Clock</td><td>%s MHz</td></tr>\n' "$CPU_CUR_MHZ"
        fi

        printf '    <tr><td>RAM</td><td>%s GiB used &nbsp;/&nbsp; %s GiB total</td></tr>\n' \
            "$MEM_USED_GiB" "$MEM_TOTAL_GiB"

        cat <<HTMLFOOT
  </table>
  <pre>${SMI_OUTPUT}</pre>
  <p class="ts">Last updated: ${TIMESTAMP} &mdash; refreshes every ${REFRESH}s</p>
</body>
</html>
HTMLFOOT
    } > "${OUTPUT}.tmp"

    mv "${OUTPUT}.tmp" "$OUTPUT"
    sleep "$REFRESH"
done
