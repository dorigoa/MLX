# MLX

Scripts that start and stop `mlx_vlm.server` on MacStudio1 (`192.168.1.101`), with an MTP drafter for
speculative decoding. They are made for [llm-console](https://github.com/dorigoa/llm-console) (Mac tab,
MLX card), which runs them over ssh, and work by hand too.

Until 23/11/2026 they started `mlx_lm.server`. `mlx_vlm.server` replaced it because it has `/metrics`
(the speeds and tokens of each request, for llm-console's live line) and MTP speculative decoding for
Qwen3.8, about twice as fast.

| Script | What it does |
|---|---|
| `run-mlx.sh` | Starts the server in the background and returns once the model is loaded: `/health` says `model_ready`, then a 1-token test request answers. It fails as soon as the server exits, `/health` reports a load failure or the test request fails, or after `-wait` seconds. |
| `stop.sh` | Stops the server and waits until it has exited: SIGTERM, then SIGKILL after 30 s. Nothing running is not an error. |

## Installing mlx-vlm

MLX runs only on Apple silicon Macs. The scripts expect `mlx_vlm.server` in `~/.local/bin`, installed
with [uv](https://docs.astral.sh/uv/) as a tool, in its own environment. Not `uvx`, which may pick
another version at another start; and not a `pip install` into a shared Python (miniforge, Homebrew),
which can clash with other packages: on MacStudio1, miniforge's mlx_lm broke on its `huggingface-hub`
version.

1. Install uv, if it is missing. It goes into `~/.local/bin`; open a new shell so that it is on the
   `PATH`.

   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```

2. Install mlx-vlm. uv picks the Python itself (3.13 on MacStudio1). The scripts were tested with
   0.8.0: `uv tool install mlx-vlm==0.8.0` installs that version, and `uv tool upgrade mlx-vlm` moves
   to the latest. `run-mlx.sh` reads `/health` and llm-console reads `/metrics`: check both after an
   upgrade.

   ```bash
   uv tool install mlx-vlm==0.8.0
   ```
   ```bash
   ~/.local/bin/mlx_vlm.server --help
   ```

3. Download the model and its MTP drafter into the cache the scripts read, `/Volumes/Home/hf_models`.
   `run-mlx.sh` starts offline, so each snapshot must have every file of the repository, not only the
   weights; otherwise the load fails with `IncompleteSnapshotError`. `hf download` with no file names
   fetches them all.

   ```bash
   HF_HUB_CACHE=/Volumes/Home/hf_models uvx --from huggingface_hub hf download mlx-community/Qwen3.8-27B-4bit
   ```
   ```bash
   HF_HUB_CACHE=/Volumes/Home/hf_models uvx --from huggingface_hub hf download mlx-community/Qwen3.8-27B-MTP-4bit
   ```

   Another MLX model (e.g. from [mlx-community](https://huggingface.co/mlx-community)) goes into the
   cache the same way, and `-model <repo>` starts it. A drafter works only with its own model: give
   `-draft-model none` for a model without one. The weights must fit under the GPU's wired memory
   limit (`sysctl iogpu.wired_limit_mb`), with room for the KV cache: otherwise the model loads, but
   the test request fails with `[METAL] … Insufficient Memory`. Qwen3.8-27B 4 bit (15,310 MiB of
   weights) fits at 20000; `mlx-community/gemma-4-31B-it-qat-4bit` (27,481 MiB) does not at 26000.

   Gemma-4-31B-it 4 bit (`mlx-community/gemma-4-31B-it-4bit`, 17,559 MiB) has a drafter too, Google's
   "assistant" (`gemma4_assistant`, which mlx_vlm runs as MTP):

   ```bash
   HF_HUB_CACHE=/Volumes/Home/hf_models uvx --from huggingface_hub hf download mlx-community/gemma-4-31B-it-assistant-bf16
   ```

   With `-draft-model mlx-community/gemma-4-31B-it-assistant-bf16` it went from 18.7-19.0 tok/s to
   24.1 (prose), 35.7 (code) and 42.2 tok/s (thinking), with 42%, 78% and 98% of the drafts
   accepted; peak memory 20.4 GB.

4. Try it by hand. `run-mlx.sh` returns once the model has answered a 1-token request.

   ```bash
   ~/MLX/run-mlx.sh
   ```
   ```bash
   curl -s http://127.0.0.1:8080/health
   ```
   ```bash
   ~/MLX/stop.sh
   ```

## Usage

```bash
~/MLX/run-mlx.sh -model mlx-community/Qwen3.8-27B-4bit -draft-model mlx-community/Qwen3.8-27B-MTP-4bit -host 192.168.1.101 -port 8080
```
```bash
~/MLX/stop.sh
```

`run-mlx.sh` takes these options:
- `-model`: a model in the Hugging Face cache, `mlx-community/Qwen3.8-27B-4bit` by default;
- `-draft-model`: its drafter in the cache, `mlx-community/Qwen3.8-27B-MTP-4bit` by default, or `none`;
- `-host`, `-port`: default `127.0.0.1:8080`;
- `-max-tokens`: the default answer length, thinking included, 32768 (a request can send its own);
- `-kv-bits`: KV cache quantization, 8 bits by default, or `none`;
- `-thinking-budget`: the default maximum length of a thinking block, 4096 tokens (a request can send its own `thinking_budget`). Past it, mlx_vlm closes the block and the model answers;
- `-no-thinking`: thinking is on by default (`--enable-thinking`); with this flag it is off unless the
  request turns it on;
- `-no-apc`: no prefix caching between requests;
- `-apc-blocks`: the prefix cache's size, in blocks of 16 tokens (mlx_vlm's default: 2048);
- `-wait`: seconds to wait for the model, 300 by default.

With no options it runs the same server as:

```bash
APC_ENABLED=1 APC_DISK_ENABLED=0 uvx --from mlx-vlm mlx_vlm.server --model mlx-community/Qwen3.8-27B-4bit --draft-model mlx-community/Qwen3.8-27B-MTP-4bit --host 127.0.0.1 --port 8080 --max-tokens 32768 --kv-bits 8 --enable-thinking --thinking-budget 4096
```

How it runs:
- it checks first that nothing listens on the port (`lsof`);
- `mlx_vlm.server` is the uv tool in `~/.local/bin` (`uv tool install mlx-vlm`);
- models come from `HF_HUB_CACHE=/Volumes/Home/hf_models`, offline (`HF_HUB_OFFLINE=1`): nothing is
  downloaded at start;
- the model and the drafter load in the background: `/health` answers at once, with `model_ready` false
  until they are in, and requests get 503 meanwhile. Loading Qwen3.8-27B 4 bit with its drafter takes
  about 15 s, test request included;
- prefix caching (APC) is on, in memory only (`APC_ENABLED=1 APC_DISK_ENABLED=0`): a request that
  starts like the one before, as the next turn of a conversation does, reuses its KV instead of
  computing the whole prompt again. With Qwen3.8-27B 4 bit, a 22.5k-token conversation takes 117 s of
  prefill on its first turn and 0.3-0.6 s on the next ones (37k tokens: 206 s, then 0.4 s). One
  conversation at a time; mlx_vlm's pool of 2048 blocks of 16 tokens is about 2.6 GiB, roughly 65k
  tokens of context at 8-bit KV. `-apc-blocks <n>` changes it, `-no-apc` turns it off. On disk it
  would write about 1.5 GB per request at 37k tokens, so that stays off;
- each start writes its log to `./mlx-<timestamp>.log`, next to the scripts (git ignores the logs).
  When the run fails, the server may still be running: `stop.sh` stops it.

A client must send `model` (mlx_vlm answers 422 without it), with the id of the model it serves,
e.g. `mlx-community/Qwen3.8-27B-4bit`. Each answer has `timings`, with the MTP drafts:
`draft_n_accepted` of `draft_n`. `/metrics` (JSON) has the last requests' speeds and tokens, but not
the drafts.
