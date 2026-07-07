#!/bin/bash
REFRESH=${REFRESH_SECONDS:-30}
OUTPUT=/output/index.html
BAR_WIDTH=20   # characters wide for the ASCII-style bar

mkdir -p /output

# Static hardware info (collected once)
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)
CPU_THREADS=$(grep -c "^processor" /proc/cpuinfo)
CPU_CORES=$(grep "^core id" /proc/cpuinfo | sort -u | wc -l)
CPU_MAX_MHZ=$(awk '{printf "%.0f", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "")
MEM_TOTAL_GiB=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)

bar_color() {
    local pct=$1
    if   [[ $pct -lt 50 ]]; then echo "#2ecc71"
    elif [[ $pct -lt 80 ]]; then echo "#f39c12"
    else                          echo "#e74c3c"
    fi
}

while true; do
    TIMESTAMP=$(date -u "+%Y-%m-%d %H:%M:%S UTC")

    # CPU utilization: two snapshots 1 second apart
    mapfile -t STAT1 < <(grep '^cpu[0-9]' /proc/stat)
    sleep 1
    mapfile -t STAT2 < <(grep '^cpu[0-9]' /proc/stat)

    declare -a CPU_UTILS=()
    for i in "${!STAT1[@]}"; do
        read -r _ u1 n1 s1 id1 io1 irq1 soft1 steal1 _ <<< "${STAT1[$i]}"
        read -r _ u2 n2 s2 id2 io2 irq2 soft2 steal2 _ <<< "${STAT2[$i]}"
        total1=$((u1+n1+s1+id1+io1+irq1+soft1+steal1))
        total2=$((u2+n2+s2+id2+io2+irq2+soft2+steal2))
        dtotal=$((total2-total1))
        didle=$(( (id2+io2)-(id1+io1) ))
        [[ $dtotal -gt 0 ]] && util=$(( (dtotal-didle)*100/dtotal )) || util=0
        CPU_UTILS+=($util)
    done

    read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
    CPU_CUR_MHZ=$(awk '/cpu MHz/ {sum+=$4; n++} END {printf "%.0f", sum/n}' /proc/cpuinfo)
    MEM_USED_GiB=$(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%.1f", (t-a)/1024/1024}' /proc/meminfo)

    SMI_OUTPUT=$(nvidia-smi 2>&1)

    {
        cat <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>System Status</title>
  <style>
    body { font-family: 'Courier New', monospace; background: #1a1a2e; color: #e0e0e0; padding: 2em; margin: 0 auto; }
    h2 { color: #7fdbff; margin-bottom: 0.8em; }
    h3 { color: #7fdbff; font-size: 0.9em; text-transform: uppercase; letter-spacing: 0.08em; margin: 1.6em 0 0.5em; }
    .hw { border-collapse: collapse; margin-bottom: 0.5em; }
    .hw td { padding: 0.2em 1.5em 0.2em 0; vertical-align: top; }
    .hw td:first-child { color: #7fdbff; white-space: nowrap; }
    .cores { display: grid; grid-template-columns: repeat(2, 1fr); gap: 0.15em 2em; margin-top: 0.5em; }
    .core-row { display: flex; align-items: center; gap: 0.5em; white-space: nowrap; }
    .core-label { color: #7fdbff; width: 4.5em; text-align: right; font-size: 0.85em; }
    .bar-bg { background: #252540; height: 10px; flex: 1; max-width: 160px; }
    .bar-fg { height: 100%; }
    .core-pct { font-size: 0.85em; width: 3em; }
    pre { white-space: pre; margin-top: 0; }
    .ts { color: #555; font-size: 0.85em; margin-top: 1.5em; }
  </style>
</head>
<body>
  <h2>System Status</h2>
HTMLHEAD

        # --- CPU / RAM summary table ---
        echo '  <table class="hw">'
        printf '    <tr><td>CPU</td><td>%s</td></tr>\n' "$CPU_MODEL"
        printf '    <tr><td>Cores</td><td>%s cores / %s threads</td></tr>\n' "$CPU_CORES" "$CPU_THREADS"
        if [[ -n "$CPU_MAX_MHZ" ]]; then
            printf '    <tr><td>Clock</td><td>%s MHz avg &nbsp;/&nbsp; %s MHz max boost</td></tr>\n' "$CPU_CUR_MHZ" "$CPU_MAX_MHZ"
        else
            printf '    <tr><td>Clock</td><td>%s MHz avg</td></tr>\n' "$CPU_CUR_MHZ"
        fi
        printf '    <tr><td>Load</td><td>%s &nbsp; %s &nbsp; %s &nbsp;<span style="color:#555">(1m 5m 15m)</span></td></tr>\n' "$LOAD1" "$LOAD5" "$LOAD15"
        printf '    <tr><td>RAM</td><td>%s GiB used &nbsp;/&nbsp; %s GiB total</td></tr>\n' "$MEM_USED_GiB" "$MEM_TOTAL_GiB"
        echo '  </table>'

        # --- Per-core bars ---
        echo '  <h3>CPU cores</h3>'
        echo '  <div class="cores">'
        for i in "${!CPU_UTILS[@]}"; do
            util=${CPU_UTILS[$i]}
            color=$(bar_color "$util")
            printf '    <div class="core-row"><span class="core-label">CPU%-2d</span><div class="bar-bg"><div class="bar-fg" style="width:%d%%;background:%s"></div></div><span class="core-pct">%d%%</span></div>\n' \
                "$i" "$util" "$color" "$util"
        done
        echo '  </div>'

        # --- nvidia-smi output ---
        echo '  <h3>GPU</h3>'
        printf '  <pre>%s</pre>\n' "$SMI_OUTPUT"

        printf '  <p class="ts">Last updated: %s &mdash; refreshes every %ss</p>\n' "$TIMESTAMP" "$REFRESH"
        echo '</body>'
        echo '</html>'

    } > "${OUTPUT}.tmp"

    mv "${OUTPUT}.tmp" "$OUTPUT"
    sleep $((REFRESH - 1))
done
