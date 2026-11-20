# MLX

Scripts that start and stop `mlx_lm.server` on MacStudio1 (`192.168.1.101`). They are made for
[llm-console](https://github.com/dorigoa/llm-console) (Mac tab, mlx_lm.server card), which runs them
over ssh, and work by hand too.

| Script | What it does |
|---|---|
| `run-mlx.sh` | Starts the server in the background and returns once the model is loaded, that is once a 1-token test request answers. `/v1/models` answers even when loading fails. It fails as soon as the server exits or the request fails, or after `-wait` seconds. |
| `stop.sh` | Stops the server and waits until it has exited: SIGTERM, then SIGKILL after 30 s. Nothing running is not an error. |

## Installing mlx_lm

MLX runs only on Apple silicon Macs. The scripts expect `mlx_lm.server` in `~/.local/bin`, installed
with [uv](https://docs.astral.sh/uv/) as a tool, in its own environment. A `pip install` into a shared
Python (miniforge, Homebrew) can clash with other packages: on MacStudio1, miniforge's mlx_lm broke on
its `huggingface-hub` version.

1. Install uv, if it is missing. It goes into `~/.local/bin`; open a new shell so that it is on the
   `PATH`.

   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```

2. Install mlx-lm. uv picks the Python itself (3.13 on MacStudio1). The scripts were tested with
   0.32.2: `uv tool install mlx-lm==0.32.2` installs that version, and `uv tool upgrade mlx-lm` moves
   to the latest.

   ```bash
   uv tool install mlx-lm
   ```
   ```bash
   ~/.local/bin/mlx_lm.server --help
   ```

3. Download the model into the cache the scripts read, `/Volumes/Home/hf_models`, about 15 GB.
   `run-mlx.sh` starts offline, so the snapshot must have every file of the repository, not only the
   weights; otherwise the load fails with `IncompleteSnapshotError`. `hf download` with no file names
   fetches them all.

   ```bash
   HF_HUB_CACHE=/Volumes/Home/hf_models uvx --from huggingface_hub hf download mlx-community/Qwen3.8-27B-4bit
   ```

   Another MLX model (e.g. from [mlx-community](https://huggingface.co/mlx-community)) goes into the
   cache the same way, and `-model <repo>` starts it.

4. Try it by hand. `run-mlx.sh` returns once the model has answered a 1-token request.

   ```bash
   ~/MLX/run-mlx.sh
   ```
   ```bash
   curl -s http://127.0.0.1:8080/v1/models
   ```
   ```bash
   ~/MLX/stop.sh
   ```

## Usage

```bash
~/MLX/run-mlx.sh -model mlx-community/Qwen3.8-27B-4bit -host 192.168.1.101 -port 8080
```
```bash
~/MLX/stop.sh
```

`run-mlx.sh` takes these options:
- `-model`: a model in the Hugging Face cache, `mlx-community/Qwen3.8-27B-4bit` by default;
- `-host`, `-port`: default `127.0.0.1:8080`;
- `-max-tokens`: the default answer length, 32768 (mlx_lm's own default is 512);
- `-wait`: seconds to wait for the model, 300 by default.

How it runs:
- it checks first that nothing listens on the port (`lsof`);
- `mlx_lm.server` is the uv tool in `~/.local/bin` (`uv tool install mlx-lm`), not the one in
  miniforge;
- models come from `HF_HUB_CACHE=/Volumes/Home/hf_models`, offline (`HF_HUB_OFFLINE=1`): nothing is
  downloaded at start;
- each start writes its log to `./mlx-<timestamp>.log`, next to the scripts (git ignores the logs).

A client must leave `model` out, or send the exact id. Another name gets a 404. If the name is another
model of the cache, mlx_lm loads it.
