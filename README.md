# MLX

Scripts that start and stop `mlx_lm.server` on MacStudio1 (`192.168.1.101`). They are made for
[llm-console](https://github.com/dorigoa/llm-console) (Mac tab, mlx_lm.server card), which runs them
over ssh, and work by hand too.

| Script | What it does |
|---|---|
| `run-mlx.sh` | Starts the server in the background and returns once the model is loaded, that is once a 1-token test request answers. `/v1/models` answers even when loading fails. It fails as soon as the server exits or the request fails, or after `-wait` seconds. |
| `stop.sh` | Stops the server and waits until it has exited: SIGTERM, then SIGKILL after 30 s. Nothing running is not an error. |

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
