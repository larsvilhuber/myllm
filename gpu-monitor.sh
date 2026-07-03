#!/bin/bash
REFRESH=${REFRESH_SECONDS:-30}
OUTPUT=/output/index.html

mkdir -p /output

declare -A PROC_MEM
declare -A PROC_FULLNAME

while true; do
    TIMESTAMP=$(date -u "+%Y-%m-%d %H:%M:%S UTC")

    # GPU summary
    mapfile -t GPU_LINES < <(nvidia-smi \
        --query-gpu=index,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.limit \
        --format=csv,noheader 2>/dev/null)

    # Per-process memory (compute processes only)
    PROC_MEM=()
    PROC_FULLNAME=()
    while IFS=',' read -r pid pname mem; do
        pid=$(echo "$pid" | xargs)
        pname=$(echo "$pname" | xargs)
        mem=$(echo "$mem" | xargs)
        [[ -n "$pid" ]] && PROC_MEM[$pid]="$mem"
        [[ -n "$pid" ]] && PROC_FULLNAME[$pid]="$pname"
    done < <(nvidia-smi --query-compute-apps=pid,process_name,used_gpu_memory --format=csv,noheader 2>/dev/null)

    # Per-process utilization from pmon (all types: compute + graphics)
    mapfile -t PMON_LINES < <(nvidia-smi pmon -c 1 2>/dev/null | grep -v '^#' | grep -v '^ *$')

    {
        cat <<HTMLHEAD
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>GPU Status</title>
  <meta http-equiv="refresh" content="${REFRESH}">
  <style>
    body { font-family: 'Courier New', monospace; background: #1a1a2e; color: #e0e0e0; padding: 2em; max-width: 1100px; margin: 0 auto; }
    h2, h3 { color: #7fdbff; margin-bottom: 0.4em; }
    h3 { margin-top: 1.8em; font-size: 1em; text-transform: uppercase; letter-spacing: 0.08em; }
    table { border-collapse: collapse; width: 100%; margin-top: 0.6em; }
    th { color: #7fdbff; padding: 0.6em 1em; text-align: left; border-bottom: 2px solid #2a2a4e; white-space: nowrap; }
    td { padding: 0.45em 1em; border-bottom: 1px solid #252540; white-space: nowrap; }
    tr:hover td { background: #252540; }
    .dim { color: #555; }
    .ts { color: #555; font-size: 0.85em; margin-top: 1.8em; }
    .badge-C { color: #7fdbff; }
    .badge-G { color: #adff2f; }
  </style>
</head>
<body>
  <h2>GPU Status</h2>
  <table>
    <tr><th>#</th><th>GPU</th><th>Temp</th><th>GPU&nbsp;%</th><th>Mem&nbsp;%</th><th>Mem&nbsp;Used</th><th>Mem&nbsp;Total</th><th>Power</th><th>Limit</th></tr>
HTMLHEAD

        for line in "${GPU_LINES[@]}"; do
            IFS=',' read -r idx name temp gpu_util mem_util mem_used mem_total power power_limit <<< "$line"
            idx=$(echo "$idx" | xargs)
            name=$(echo "$name" | xargs)
            temp=$(echo "$temp" | xargs)
            gpu_util=$(echo "$gpu_util" | xargs)
            mem_util=$(echo "$mem_util" | xargs)
            mem_used=$(echo "$mem_used" | xargs)
            mem_total=$(echo "$mem_total" | xargs)
            power=$(echo "$power" | xargs)
            power_limit=$(echo "$power_limit" | xargs)
            printf '    <tr><td>%s</td><td>%s</td><td>%s&deg;C</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
                "$idx" "$name" "$temp" "$gpu_util" "$mem_util" "$mem_used" "$mem_total" "$power" "$power_limit"
        done

        echo '  </table>'
        echo '  <h3>Processes</h3>'
        echo '  <table>'
        echo '    <tr><th>GPU</th><th>PID</th><th>Type</th><th>App</th><th>SM&nbsp;%</th><th>Mem&nbsp;%</th><th>Enc&nbsp;%</th><th>Dec&nbsp;%</th><th>Mem&nbsp;Used</th></tr>'

        if [[ ${#PMON_LINES[@]} -eq 0 ]]; then
            echo '    <tr><td colspan="9" class="dim">No active processes</td></tr>'
        else
            for line in "${PMON_LINES[@]}"; do
                read -r gpu pid type sm mem enc dec jpg ofa cmd <<< "$line"
                [[ -z "$pid" || "$pid" == "-" ]] && continue

                mem_used="${PROC_MEM[$pid]:-—}"

                # Prefer full path from compute-apps; fall back to pmon command name
                if [[ -n "${PROC_FULLNAME[$pid]}" ]]; then
                    app=$(basename "${PROC_FULLNAME[$pid]}")
                else
                    app="$cmd"
                fi

                # Format dash values as dimmed
                fmt_val() {
                    [[ "$1" == "-" ]] && echo '<span class="dim">—</span>' || echo "$1"
                }

                printf '    <tr><td>%s</td><td>%s</td><td class="badge-%s">%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
                    "$gpu" "$pid" "$type" "$type" "$app" \
                    "$(fmt_val "$sm")" "$(fmt_val "$mem")" "$(fmt_val "$enc")" "$(fmt_val "$dec")" \
                    "$mem_used"
            done
        fi

        printf '  </table>\n  <p class="ts">Last updated: %s &mdash; refreshes every %ss</p>\n</body>\n</html>\n' \
            "$TIMESTAMP" "$REFRESH"
    } > "${OUTPUT}.tmp"

    mv "${OUTPUT}.tmp" "$OUTPUT"
    sleep "$REFRESH"
done
