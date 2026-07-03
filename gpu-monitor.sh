#!/bin/bash
REFRESH=${REFRESH_SECONDS:-30}
OUTPUT=/output/index.html

mkdir -p /output

while true; do
    TIMESTAMP=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
    SMI_OUTPUT=$(nvidia-smi 2>&1)

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
    pre { white-space: pre; }
    .ts { color: #555; font-size: 0.85em; margin-top: 1.5em; }
  </style>
</head>
<body>
  <pre>${SMI_OUTPUT}</pre>
  <p class="ts">Last updated: ${TIMESTAMP} &mdash; refreshes every ${REFRESH}s</p>
</body>
</html>
HTMLHEAD
    } > "${OUTPUT}.tmp"

    mv "${OUTPUT}.tmp" "$OUTPUT"
    sleep "$REFRESH"
done
