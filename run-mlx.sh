#!/bin/bash
# Starts mlx_vlm.server in the background with an MLX model from the Hugging Face
# cache and, by default, its MTP drafter for speculative decoding. Returns once the
# model is loaded (/health says model_ready, then a 1-token test request answers),
# or as soon as the server exits or the load fails. The server keeps running after
# this script (and the ssh session) ends; its log is ./mlx-<timestamp>.log next to
# this script. Stop it with ./stop.sh.
#
# mlx_vlm.server is the uv tool in ~/.local/bin (uv tool install mlx-vlm), not uvx:
# the version stays the one installed. Unlike mlx_lm.server it has /metrics (JSON)
# and MTP speculative decoding for Qwen3.8.
#
# Prefix caching (APC) is on, in memory only: a request that starts like the one
# before (the next turn of a conversation, as an agent sends it) reuses its KV
# instead of computing the whole prompt again (0.5 s instead of ~2 min at 22k
# tokens). It keeps one conversation; mlx_vlm's pool of 2048 blocks of 16 tokens
# is about 2.6 GiB (-apc-blocks changes it).
#
# Used by llm-console (Mac tab), e.g.:
#   ~/MLX/run-mlx.sh -model mlx-community/Qwen3.8-27B-4bit \
#       -draft-model mlx-community/Qwen3.8-27B-MTP-4bit -host 192.168.1.101 -port 8080

set -uo pipefail

usage() {
    echo "Usage: $0 [options]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  -model <repo>         Model in the cache (default: mlx-community/Qwen3.8-27B-4bit)" >&2
    echo "  -draft-model <repo>   Drafter in the cache, matching the model, or none" >&2
    echo "                        (default: mlx-community/Qwen3.8-27B-MTP-4bit)" >&2
    echo "  -host <address>       Address to listen on (default: 127.0.0.1)" >&2
    echo "  -port <number>        Port (default: 8080)" >&2
    echo "  -max-tokens <n>       Default max tokens per answer, thinking included (default: 32768)" >&2
    echo "  -kv-bits <n>          KV cache quantization bits, or none (default: 8)" >&2
    echo "  -thinking-budget <n>  Default max tokens of a thinking block (default: 4096)" >&2
    echo "  -no-thinking          Thinking off unless the request turns it on" >&2
    echo "  -no-apc               No prefix caching between requests" >&2
    echo "  -apc-blocks <n>       Prefix cache size in blocks of 16 tokens (default: 2048)" >&2
    echo "  -wait <seconds>       How long to wait for the model (default: 300)" >&2
    exit 2
}

server="$HOME/.local/bin/mlx_vlm.server"
model=mlx-community/Qwen3.8-27B-4bit
draft_model=mlx-community/Qwen3.8-27B-MTP-4bit
host=127.0.0.1
port=8080
max_tokens=32768
kv_bits=8
thinking_budget=4096
thinking=1
apc=1
apc_blocks=
wait_s=300

while [[ $# -gt 0 ]]; do
    case "$1" in
        -model)           model="${2:-}"; shift 2 ;;
        -draft-model)     draft_model="${2:-}"; shift 2 ;;
        -host)            host="${2:-}"; shift 2 ;;
        -port)            port="${2:-}"; shift 2 ;;
        -max-tokens)      max_tokens="${2:-}"; shift 2 ;;
        -kv-bits)         kv_bits="${2:-}"; shift 2 ;;
        -thinking-budget) thinking_budget="${2:-}"; shift 2 ;;
        -no-thinking)     thinking=0; shift ;;
        -no-apc)          apc=0; shift ;;
        -apc-blocks)      apc_blocks="${2:-}"; shift 2 ;;
        -wait)            wait_s="${2:-}"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# The models are in /Volumes/Home/hf_models; never download at start.
export HF_HUB_CACHE=/Volumes/Home/hf_models
export HF_HUB_OFFLINE=1
# mlx_vlm reads the prefix cache settings from the environment. Not on disk: it
# would write about 1.5 GB per request at 37k tokens.
export APC_ENABLED=$apc APC_DISK_ENABLED=0
if [[ -n $apc_blocks ]]; then export APC_NUM_BLOCKS=$apc_blocks; else unset APC_NUM_BLOCKS; fi

in_cache() {
    [[ -d "$HF_HUB_CACHE/models--${1//\//--}/snapshots" ]] || { echo "No model $1 in $HF_HUB_CACHE" >&2; exit 2; }
}
in_cache "$model"
args=(--model "$model" --host "$host" --port "$port" --max-tokens "$max_tokens"
      --thinking-budget "$thinking_budget")
if [[ $draft_model != none ]]; then
    in_cache "$draft_model"
    args+=(--draft-model "$draft_model")
fi
[[ $kv_bits != none ]] && args+=(--kv-bits "$kv_bits")
(( thinking )) && args+=(--enable-thinking)
[[ -x "$server" ]] || { echo "$server not found: uv tool install mlx-vlm" >&2; exit 2; }

# Another server on the port would answer in our place.
busy=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null)
if [[ -n "$busy" ]]; then
    echo "Port $port is already in use:" >&2
    echo "$busy" >&2
    exit 1
fi

cd "$(dirname "$0")" || exit 2
log="$PWD/mlx-$(date +%Y%m%d-%H%M%S).log"
echo "Starting mlx_vlm.server: $model, drafter $draft_model, $host:$port, prefix cache $( ((apc)) && echo on || echo off)"
nohup "$server" "${args[@]}" </dev/null >"$log" 2>&1 &
pid=$!
echo "pid $pid, log $log"

failed() {
    echo "$1 Last lines of $log:" >&2
    tail -n 20 "$log" >&2
    exit 1
}

# The model (and the drafter) load in the background: /health answers at once and
# says model_ready once they are in, or lists the failure in preload_failures;
# requests get 503 meanwhile. Then only a generated token proves that it works.
base="http://$host:$port"
request="{\"model\": \"$model\", \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}], \"max_tokens\": 1}"
started=$SECONDS
said=
while (( SECONDS - started < wait_s )); do
    kill -0 "$pid" 2>/dev/null || failed "mlx_vlm.server exited."
    health=$(curl -fs --max-time 5 "$base/health")
    if [[ -n $health ]]; then
        [[ -n $said ]] || { echo "The API answers; loading the model..."; said=1; }
        grep -Eq '"preload_failures": ?\{\}' <<<"$health" || failed "Loading the model failed."
        if grep -Eq '"model_ready": ?true' <<<"$health"; then
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
    fi
    sleep 2
done
echo "$model not loaded after $wait_s s; the server is still running (pid $pid), see $log" >&2
exit 1
