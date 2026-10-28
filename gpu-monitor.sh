#!/bin/bash
# Generates a static, btop-style system status page (CPU / RAM / GPU) with
# rolling history sparklines. Needs only bash, awk and nvidia-smi.
REFRESH=${REFRESH_SECONDS:-5}
OUTPUT=/output/index.html
HIST_DIR=/tmp/hist
HIST_N=120      # samples kept per series

mkdir -p /output "$HIST_DIR"

# ---------------------------------------------------------------- static info
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)
CPU_THREADS=$(grep -c "^processor" /proc/cpuinfo)
CPU_CORES=$(grep "^core id" /proc/cpuinfo | sort -u | wc -l)
CPU_MAX_MHZ=$(awk '{printf "%.0f", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "")
[[ -z $CPU_MAX_MHZ || $CPU_MAX_MHZ == 0 ]] && CPU_MAX_MHZ=5000
MEM_TOTAL_GiB=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)

declare -a GPU_IDS=()
declare -A G_NAME G_UUID G_DRV G_VBIOS G_BUS G_VRAM G_PLIM G_MAXSM G_MAXMEM G_MAXGEN G_MAXW UUID2IDX

collect_gpu_static() {
    local rows idx name uuid drv vbios bus vram plim maxsm maxmem maxgen maxw
    rows=$(nvidia-smi --query-gpu=index,name,uuid,driver_version,vbios_version,pci.bus_id,memory.total,power.limit,clocks.max.sm,clocks.max.memory,pcie.link.gen.max,pcie.link.width.max \
        --format=csv,noheader,nounits 2>/dev/null) || return
    GPU_IDS=()
    while IFS=, read -r idx name uuid drv vbios bus vram plim maxsm maxmem maxgen maxw; do
        [[ -z $idx ]] && continue
        idx=${idx// /}; uuid=${uuid// /}
        GPU_IDS+=("$idx")
        G_NAME[$idx]=$(xargs <<< "$name"); G_UUID[$idx]=$uuid
        G_DRV[$idx]=${drv// /}; G_VBIOS[$idx]=${vbios// /}; G_BUS[$idx]=${bus// /}
        G_VRAM[$idx]=${vram// /}; G_PLIM[$idx]=${plim// /}
        G_MAXSM[$idx]=${maxsm// /}; G_MAXMEM[$idx]=${maxmem// /}
        G_MAXGEN[$idx]=${maxgen// /}; G_MAXW[$idx]=${maxw// /}
        UUID2IDX[$uuid]=$idx
    done <<< "$rows"
}

# -------------------------------------------------------------------- helpers
num()  { [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$1" || echo 0; }
pct()  { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) { p = a*100/b; if (p > 100) p = 100; printf "%d", p } else print 0 }'; }
esc()  { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g' <<< "$1"; }

bar_color() {
    if   [[ $1 -lt 50 ]]; then echo "#2ecc71"
    elif [[ $1 -lt 80 ]]; then echo "#f39c12"
    else                       echo "#e74c3c"
    fi
}

push() {  # push <series> <value>
    local f=$HIST_DIR/$1
    echo "$2" >> "$f"
    if [[ $(wc -l < "$f") -gt $HIST_N ]]; then
        tail -n "$HIST_N" "$f" > "$f.t" && mv "$f.t" "$f"
    fi
}

spark() {  # spark <series> <ymax> <color> [points]  -> inline SVG area chart
    local f=$HIST_DIR/$1 n=${4:-$HIST_N}
    if [[ ! -s $f ]]; then echo '<svg class="spark"></svg>'; return; fi
    tail -n "$n" "$f" | awk -v max="$2" -v col="$3" -v N="$n" '
        { v[NR] = $1 }
        END {
            if (max <= 0) max = 1
            off = N - NR
            for (i = 1; i <= NR; i++) {
                r = v[i] / max; if (r > 1) r = 1; if (r < 0) r = 0
                pts = pts sprintf("%d,%.1f ", off + i - 1, 98 - r * 96)
            }
            printf "<svg class=\"spark\" viewBox=\"0 0 %d 100\" preserveAspectRatio=\"none\">", N - 1
            printf "<polygon points=\"%d,100 %s%d,100\" fill=\"%s\" fill-opacity=\".22\"/>", off, pts, N - 1, col
            printf "<polyline points=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"1.5\" vector-effect=\"non-scaling-stroke\"/></svg>\n", pts, col
        }'
}

chart() {  # chart <label> <value-text> <series> <ymax> <color>
    printf '<div class="chart"><div class="ch-head"><span>%s</span><b style="color:%s">%s</b></div>%s</div>\n' \
        "$1" "$5" "$2" "$(spark "$3" "$4" "$5")"
}

chart2() {  # chart2 <label> <seriesA> <maxA> <colA> <textA> <seriesB> <maxB> <colB> <textB>
    printf '<div class="chart"><div class="ch-head"><span>%s</span><span><b style="color:%s">%s</b> <b style="color:%s">%s</b></span></div><div class="overlay">%s%s</div></div>\n' \
        "$1" "$4" "$5" "$8" "$9" "$(spark "$2" "$3" "$4")" "$(spark "$6" "$7" "$8")"
}

gauge() {  # gauge <label> <value-text> <pct>
    printf '<div class="grow"><span class="gl">%s</span><div class="gauge"><div class="fill" style="width:%d%%;background:%s"></div></div><span class="gv">%s</span></div>\n' \
        "$1" "$3" "$(bar_color "$3")" "$2"
}

proc_label() {  # proc_label <pid> -> "command" and sets PROC_CTR
    local pid=$1 cmd first
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-90)
    if [[ -z $cmd ]]; then cmd="pid $pid"; else
        first=${cmd%% *}
        cmd="${first##*/}${cmd#"$first"}"
    fi
    PROC_CTR=$(grep -o '[0-9a-f]\{64\}' "/proc/$pid/cgroup" 2>/dev/null | head -1 | cut -c1-12)
    echo "$cmd"
}

PALETTE=('#7fdbff' '#b48ead' '#ebcb8b' '#a3be8c' '#d08770' '#88c0d0' '#e5a0c8')

# ----------------------------------------------------------------- main loop
while true; do
    TIMESTAMP=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
    [[ ${#GPU_IDS[@]} -eq 0 ]] && collect_gpu_static

    # CPU utilization: two snapshots 1 second apart (line 0 = aggregate)
    mapfile -t STAT1 < <(grep '^cpu' /proc/stat)
    sleep 1
    mapfile -t STAT2 < <(grep '^cpu' /proc/stat)

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
    CPU_TOTAL=${CPU_UTILS[0]}
    push cpu_total "$CPU_TOTAL"

    read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
    CPU_CUR_MHZ=$(awk '/cpu MHz/ {sum+=$4; n++} END {printf "%.0f", sum/n}' /proc/cpuinfo)
    read -r MEM_USED_KB MEM_TOTAL_KB < <(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {print t-a, t}' /proc/meminfo)
    MEM_USED_GiB=$(awk -v k="$MEM_USED_KB" 'BEGIN {printf "%.1f", k/1024/1024}')
    MEM_PCT=$(pct "$MEM_USED_KB" "$MEM_TOTAL_KB")

    # GPU dynamic data
    mapfile -t GPU_ROWS < <(nvidia-smi --query-gpu=index,utilization.gpu,utilization.memory,memory.used,power.draw,temperature.gpu,fan.speed,clocks.sm,clocks.mem,pcie.link.gen.current,pcie.link.width.current,pstate \
        --format=csv,noheader,nounits 2>/dev/null)
    declare -A GP_PROCS=()
    while IFS=, read -r uuid pid mem; do
        [[ -z $pid ]] && continue
        uuid=${uuid// /}; pid=${pid// /}; mem=$(num "${mem// /}")
        gi=${UUID2IDX[$uuid]:-}
        [[ -n $gi ]] && GP_PROCS[$gi]+="$pid $mem"$'\n'
    done < <(nvidia-smi --query-compute-apps=gpu_uuid,pid,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null)

    {
        cat <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
HTMLHEAD
        printf '  <noscript><meta http-equiv="refresh" content="%s"></noscript>\n' "$REFRESH"
        cat <<'HTMLHEAD'
  <title>System Status</title>
  <style>
    :root { --bg:#1a1a2e; --pane:#202040; --track:#2a2a4a; --fg:#e0e0e0; --dim:#6c6c8c; --accent:#7fdbff; }
    * { box-sizing: border-box; }
    body { font-family: 'Courier New', monospace; background: var(--bg); color: var(--fg); margin: 0 auto; padding: 1.2em; max-width: 1400px; font-size: 14px; }
    a.back { color: var(--accent); text-decoration: none; font-size: 0.9em; }
    a.back:hover { text-decoration: underline; }
    h2 { color: var(--accent); margin: 0.4em 0 0.8em; }
    .pane { background: var(--pane); border: 1px solid #33335a; border-radius: 4px; padding: 0.7em 0.9em; margin-bottom: 1em; }
    .pane > h3 { color: var(--accent); font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.08em; margin: 0 0 0.6em; display: flex; justify-content: space-between; gap: 1em; }
    .pane > h3 small { color: var(--dim); text-transform: none; letter-spacing: 0; }
    .cols { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 0.9em 1.5em; }
    table.hw { border-collapse: collapse; width: 100%; }
    table.hw td { padding: 0.1em 1em 0.1em 0; vertical-align: top; }
    table.hw td:first-child { color: var(--dim); white-space: nowrap; }
    table.hw th { color: var(--accent); text-align: left; padding: 0.4em 0 0.2em; font-weight: normal; border-bottom: 1px solid #33335a; }

    .spark { width: 100%; height: 100%; display: block; overflow: visible; }
    .chart { background: var(--bg); border: 1px solid #2c2c50; padding: 0.3em 0.5em 0.4em; display: flex; flex-direction: column; min-width: 0; }
    .chart .spark { height: 3.6em; }
    .ch-head { display: flex; justify-content: space-between; font-size: 0.85em; margin-bottom: 0.2em; gap: 0.5em; }
    .ch-head span { color: var(--dim); }
    .chart.big .spark { height: 5.5em; }
    .charts { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 0.6em; }

    /* btop-style segmented gauge */
    .grow { display: grid; grid-template-columns: 5em 1fr 9em; align-items: center; gap: 0.6em; margin: 0.25em 0; }
    .gl { color: var(--dim); }
    .gv { text-align: right; font-size: 0.9em; white-space: nowrap; }
    .gauge { position: relative; height: 14px; background: var(--track); }
    .gauge .fill { height: 100%; }
    .gauge::after { content: ""; position: absolute; inset: 0;
      background: repeating-linear-gradient(90deg, transparent 0 4px, var(--pane) 4px 6px); }

    .cgrid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 0 1.2em; margin-top: 0.6em; }
    .cgrid .grow { grid-template-columns: 1.8em 1fr 3em; margin: 0.1em 0; }
    .cgrid .gauge { height: 10px; }
    .gpane { display: grid; grid-template-columns: 3fr 2fr; gap: 1em 1.5em; align-items: start; }
    .gcharts { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.5em; }
    .gcharts .ch-head { flex-direction: column; gap: 0; }
    .gcharts .spark { height: 5.5em; }
    .overlay { position: relative; height: 5.5em; }
    .overlay .spark { position: absolute; inset: 0; height: 100%; }
    .prow { display: grid; grid-template-columns: minmax(0, 3fr) 4em minmax(0, 2fr) 6.5em; gap: 0.6em; align-items: center; padding: 0.2em 0; border-top: 1px solid #2c2c50; }
    .prow .pn { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .prow .pn small { color: var(--dim); margin-left: 0.6em; }
    .prow .pg { color: var(--dim); }
    .prow .gauge { height: 12px; }
    .prow .pm { text-align: right; white-space: nowrap; }
    .none { color: var(--dim); font-size: 0.9em; padding-top: 0.4em; border-top: 1px solid #2c2c50; }
    .ts { color: #555; font-size: 0.85em; margin-top: 1em; }
    @media (max-width: 600px) {
      body { padding: 0.8em; }
      .grow { grid-template-columns: 4em 1fr 7em; }
      .cgrid { grid-template-columns: repeat(2, 1fr); }
      .gpane { grid-template-columns: 1fr; }
      .gcharts { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .prow { grid-template-columns: 1fr 4em 6em; }
      .prow .gauge { display: none; }
    }
  </style>
</head>
<body>
  <p><a class="back" href="/">&larr; Back to main site</a></p>
  <h2>System Status</h2>
HTMLHEAD

        # ---------------- Hardware (static): CPU + GPUs in one pane ----------------
        echo '  <div class="pane"><h3>Hardware</h3><div class="cols">'
        echo '  <table class="hw"><tr><th colspan="2">CPU</th></tr>'
        printf '    <tr><td>Model</td><td>%s</td></tr>\n' "$(esc "$CPU_MODEL")"
        printf '    <tr><td>Cores</td><td>%s cores / %s threads</td></tr>\n' "$CPU_CORES" "$CPU_THREADS"
        printf '    <tr><td>Max boost</td><td>%s MHz</td></tr>\n' "$CPU_MAX_MHZ"
        printf '    <tr><td>RAM</td><td>%s GiB</td></tr>\n' "$MEM_TOTAL_GiB"
        echo '  </table>'
        for g in "${GPU_IDS[@]}"; do
            echo '  <table class="hw">'
            printf '    <tr><th colspan="2">GPU %s &mdash; %s</th></tr>\n' "$g" "$(esc "${G_NAME[$g]}")"
            printf '    <tr><td>VRAM</td><td>%s MiB</td></tr>\n' "${G_VRAM[$g]}"
            printf '    <tr><td>Power limit</td><td>%s W</td></tr>\n' "${G_PLIM[$g]}"
            printf '    <tr><td>Max clocks</td><td>SM %s / MEM %s MHz</td></tr>\n' "${G_MAXSM[$g]}" "${G_MAXMEM[$g]}"
            printf '    <tr><td>PCIe max</td><td>Gen%s x%s &nbsp;(%s)</td></tr>\n' "${G_MAXGEN[$g]}" "${G_MAXW[$g]}" "${G_BUS[$g]}"
            printf '    <tr><td>Driver</td><td>%s &nbsp;<span style="color:#6c6c8c">vBIOS %s</span></td></tr>\n' "${G_DRV[$g]}" "${G_VBIOS[$g]}"
            echo '  </table>'
        done
        echo '  </div></div>'

        # ---------------- CPU / RAM (dynamic) ----------------
        echo '  <div class="pane"><h3>CPU &amp; Memory'
        printf '<small>%s%% total</small></h3>\n' "$CPU_TOTAL"
        echo '  <div class="cols">'
        echo '  <div>'
        chart "CPU total" "${CPU_TOTAL}%" cpu_total 100 "#7fdbff" | sed 's/class="chart"/class="chart big"/'
        echo '  </div><div>'
        gauge "Clock" "${CPU_CUR_MHZ} / ${CPU_MAX_MHZ} MHz" "$(pct "$CPU_CUR_MHZ" "$CPU_MAX_MHZ")"
        gauge "Load 1m"  "$LOAD1"  "$(pct "$LOAD1"  "$CPU_THREADS")"
        gauge "Load 5m"  "$LOAD5"  "$(pct "$LOAD5"  "$CPU_THREADS")"
        gauge "Load 15m" "$LOAD15" "$(pct "$LOAD15" "$CPU_THREADS")"
        gauge "RAM" "${MEM_USED_GiB} / ${MEM_TOTAL_GiB} GiB" "$MEM_PCT"
        echo '  </div></div>'
        echo '  <div class="cgrid">'
        for ((i=1; i<${#CPU_UTILS[@]}; i++)); do
            gauge "$((i-1))" "${CPU_UTILS[$i]}%" "${CPU_UTILS[$i]}"
        done
        echo '  </div></div>'

        # ---------------- GPUs (dynamic): history left, state right ----------------
        ALL_PROCS=""
        if [[ ${#GPU_ROWS[@]} -eq 0 ]]; then
            echo '  <div class="pane"><h3>GPU</h3><div class="none">nvidia-smi returned no data</div></div>'
        fi
        for row in "${GPU_ROWS[@]}"; do
            IFS=, read -r idx util mutil mused pwr temp fan csm cmem gen width pstate <<< "$row"
            idx=${idx// /}; util=$(num "${util// /}")
            mused=$(num "${mused// /}"); pwr=$(num "${pwr// /}"); temp=$(num "${temp// /}")
            fan=$(num "${fan// /}"); csm=$(num "${csm// /}"); cmem=$(num "${cmem// /}")
            gen=${gen// /}; width=${width// /}; pstate=${pstate// /}
            vram=${G_VRAM[$idx]:-1}; plim=${G_PLIM[$idx]:-1}
            maxsm=${G_MAXSM[$idx]:-1}; maxmem=${G_MAXMEM[$idx]:-1}
            pwr_f=$(awk -v p="$pwr" 'BEGIN {printf "%.0f", p}')
            push "gpu${idx}_vram" "$mused"; push "gpu${idx}_pwr" "$pwr"; push "gpu${idx}_temp" "$temp"
            push "gpu${idx}_csm" "$csm";    push "gpu${idx}_cmem" "$cmem"

            printf '  <div class="pane"><h3>GPU %s &mdash; %s<small>%s &middot; PCIe Gen%s x%s</small></h3>\n' \
                "$idx" "$(esc "${G_NAME[$idx]}")" "$pstate" "$gen" "$width"
            echo '  <div class="gpane"><div class="gcharts">'
            chart "VRAM"  "${mused} MiB"    "gpu${idx}_vram" "$vram" "#b48ead"
            chart "Power" "${pwr_f} W"      "gpu${idx}_pwr"  "$plim" "#ebcb8b"
            chart "Temp"  "${temp}&deg;C"   "gpu${idx}_temp" 100     "#d08770"
            chart2 "SM / Mem clk" "gpu${idx}_csm" "$maxsm" "#a3be8c" "SM ${csm}" "gpu${idx}_cmem" "$maxmem" "#88c0d0" "Mem ${cmem}"
            echo '  </div><div class="gstate">'
            gauge "Util"  "${util}%"                    "$util"
            gauge "VRAM"  "${mused} / ${vram} MiB"      "$(pct "$mused" "$vram")"
            gauge "Power" "${pwr_f} / ${plim%.*} W"     "$(pct "$pwr" "$plim")"
            gauge "Temp"  "${temp}&deg;C fan ${fan}%"   "$temp"
            echo '  </div></div></div>'

            while read -r pid pmem; do
                [[ -z $pid ]] && continue
                col=${PALETTE[$((pid % ${#PALETTE[@]}))]}
                label=$(esc "$(proc_label "$pid")")
                ctr=""; [[ -n $PROC_CTR ]] && ctr="<small>ctr $PROC_CTR</small>"
                ALL_PROCS+=$(printf '%s|<div class="prow"><div class="pn" title="%s"><span style="color:%s">&#9632;</span> %s <small>pid %s</small>%s</div><div class="pg">GPU %s</div><div class="gauge"><div class="fill" style="width:%s%%;background:%s"></div></div><div class="pm">%s MiB</div></div>\n' \
                    "$pmem" "$label" "$col" "$label" "$pid" "$ctr" "$idx" "$(pct "$pmem" "$vram")" "$col" "$pmem")$'\n'
            done <<< "${GP_PROCS[$idx]:-}"
        done

        echo '  <div class="pane"><h3>GPU processes</h3>'
        if [[ -n $ALL_PROCS ]]; then
            sort -t'|' -k1,1nr <<< "$ALL_PROCS" | cut -d'|' -f2-
        else
            echo '  <div class="none">No compute processes</div>'
        fi
        echo '  </div>'

        printf '  <p class="ts">Last updated: %s &mdash; refreshes every %ss</p>\n' "$TIMESTAMP" "$REFRESH"
        cat <<REFRESHJS
  <script>
    // Swap in the new page contents without a full reload (no flicker).
    setInterval(function () {
      fetch(location.pathname, {cache: 'no-store'}).then(function (r) { return r.text(); }).then(function (t) {
        var d = new DOMParser().parseFromString(t, 'text/html');
        if (d.body && d.body.innerHTML.length > 500) {
          document.body.innerHTML = d.body.innerHTML;
        }
      }).catch(function () {});
    }, ${REFRESH} * 1000);
  </script>
REFRESHJS
        echo '</body>'
        echo '</html>'

    } > "${OUTPUT}.tmp"

    mv "${OUTPUT}.tmp" "$OUTPUT"

    unset GP_PROCS

    sleep $((REFRESH > 1 ? REFRESH - 1 : 1))
done
