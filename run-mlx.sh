#!/bin/bash
# Starts mlx_lm.server in the background with an MLX model from the Hugging Face
# cache and returns once the model is loaded (a 1-token test request answers), or
# as soon as the server exits or the request fails. The server keeps running
# after this script (and the ssh session) ends;
# its log is ./mlx-<timestamp>.log next to this script. Stop it with ./stop.sh.
#
# mlx_lm.server is the uv tool in ~/.local/bin (uv tool install mlx-lm), not the
# one in miniforge.
#
# Used by llm-console (Mac tab), e.g.:
#   ~/MLX/run-mlx.sh -model mlx-community/Qwen3.8-27B-4bit -host 192.168.1.101 -port 8080

set -uo pipefail

usage() {
    echo "Usage: $0 [options]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  -model <repo>       Model in the cache (default: mlx-community/Qwen3.8-27B-4bit)" >&2
    echo "  -host <address>     Address to listen on (default: 127.0.0.1)" >&2
    echo "  -port <number>      Port (default: 8080)" >&2
    echo "  -max-tokens <n>     Default max tokens per answer (default: 32768; mlx_lm's own is 512)" >&2
    echo "  -wait <seconds>     How long to wait for the API (default: 300)" >&2
    exit 2
}

server="$HOME/.local/bin/mlx_lm.server"
model=mlx-community/Qwen3.8-27B-4bit
host=127.0.0.1
port=8080
max_tokens=32768
wait_s=300

while [[ $# -gt 0 ]]; do
    case "$1" in
        -model)      model="${2:-}"; shift 2 ;;
        -host)       host="${2:-}"; shift 2 ;;
        -port)       port="${2:-}"; shift 2 ;;
        -max-tokens) max_tokens="${2:-}"; shift 2 ;;
        -wait)       wait_s="${2:-}"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# The models are in /Volumes/Home/hf_models; never download at start.
export HF_HUB_CACHE=/Volumes/Home/hf_models
export HF_HUB_OFFLINE=1

cache_dir="$HF_HUB_CACHE/models--${model//\//--}"
[[ -d "$cache_dir/snapshots" ]] || { echo "No model $model in $HF_HUB_CACHE" >&2; exit 2; }
[[ -x "$server" ]] || { echo "$server not found: uv tool install mlx-lm" >&2; exit 2; }

# Another server on the port would answer /v1/models in our place.
busy=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null)
if [[ -n "$busy" ]]; then
    echo "Port $port is already in use:" >&2
    echo "$busy" >&2
    exit 1
fi

cd "$(dirname "$0")" || exit 2
log="$PWD/mlx-$(date +%Y%m%d-%H%M%S).log"
echo "Starting mlx_lm.server: $model, $host:$port"
nohup "$server" --model "$model" --host "$host" --port "$port" --max-tokens "$max_tokens" \
    </dev/null >"$log" 2>&1 &
pid=$!
echo "pid $pid, log $log"

failed() {
    echo "$1 Last lines of $log:" >&2
    tail -n 20 "$log" >&2
    exit 1
}

# /v1/models answers as soon as the HTTP server is up, even when loading the model
# fails (it is loaded by another thread): only a generated token proves it is in.
base="http://$host:$port"
request="{\"model\": \"$model\", \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}], \"max_tokens\": 1}"
started=$SECONDS
while (( SECONDS - started < wait_s )); do
    kill -0 "$pid" 2>/dev/null || failed "mlx_lm.server exited."
    if curl -fs -o /dev/null --max-time 5 "$base/v1/models"; then
        echo "The API answers; loading the model..."
        left=$(( wait_s - (SECONDS - started) ))
        (( left > 0 )) || break
        body=$(curl -s --max-time "$left" -w '\n%{http_code}' -H 'Content-Type: application/json' \
            -d "$request" "$base/v1/chat/completions")
        code=${body##*$'\n'}
        if [[ $code == 200 ]]; then
            echo "Ready: $base/v1/models ($model loaded in $(( SECONDS - started )) s)"
            exit 0
        fi
        [[ $code == 000 ]] && break   # no answer in time
        failed "The test request failed (HTTP $code: ${body%$'\n'*})."
    fi
    sleep 2
done
echo "$model not loaded after $wait_s s; the server is still running (pid $pid), see $log" >&2
exit 1
