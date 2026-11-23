#!/bin/bash
# Stops mlx_vlm.server and waits until it has exited (memory free).
# Nothing running is not an error. Used by llm-console (Mac tab).

pattern='[/]mlx_vlm[.]server( |$)'   # [/]: does not match this pattern's own text

pids=$(pgrep -f "$pattern") || { echo "mlx_vlm.server is not running."; exit 0; }
echo "Stopping mlx_vlm.server (pid" $pids")..."
kill $pids 2>/dev/null
for _ in {1..30}; do
    pgrep -f "$pattern" >/dev/null || { echo "mlx_vlm.server stopped."; exit 0; }
    sleep 1
done
echo "Still running after 30 s: sending SIGKILL." >&2
pkill -KILL -f "$pattern"
sleep 1
if pgrep -f "$pattern" >/dev/null; then
    echo "mlx_vlm.server is still running." >&2
    exit 1
fi
echo "mlx_vlm.server stopped."
