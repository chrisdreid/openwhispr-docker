# openwhispr-docker

Self-contained Docker image for the [multi-model-audio-transcript-server](./multi-model-audio-transcript-server/README.md) (Whisper + Parakeet, OpenWhispr-compatible). Mounts a host model directory so models are downloaded once and reused across container restarts.

## Prerequisites

- Docker 20.10+ with Compose v2 (`docker compose ...`)
- NVIDIA Container Toolkit installed (`docker info | grep -i nvidia` should show the `nvidia` runtime)
- An NVIDIA GPU on the host (or change `DEVICE=cpu` in `.env`)

## Quick start

```bash
./setup.sh                # creates .env + ./models, links existing host caches
docker compose up -d      # builds the image (first run) and starts the server
docker compose logs -f    # watch model loading
curl http://127.0.0.1:8080/health
```

Point OpenWhispr at `http://127.0.0.1:8080`.

## Configuration (`.env`)

| Var | Default | Notes |
|---|---|---|
| `MODEL` | `turbo` | One of `tiny`, `base`, `small`, `medium`, `turbo`, `large-v3`, `distil-large-v3`, `parakeet`, `parakeet-v3` |
| `DEVICE` | `cuda` | `cuda` or `cpu` |
| `COMPUTE_TYPE` | `int8` | Pascal → `int8`, Turing → `float16`/`int8_float16`, Ampere+ → `float16` |
| `MODEL_DIR` | `./models` | Host directory holding `huggingface/` and `parakeet/` subdirs |
| `BIND_HOST` | `127.0.0.1` | Use `0.0.0.0` to expose on the LAN |
| `PORT` | `8080` | Host port |

After changing `.env`, `docker compose up -d` recreates the container.

## How models are mounted

The container expects two paths inside the model directory and mounts them to the locations the server already uses:

```
${MODEL_DIR}/huggingface  →  /root/.cache/huggingface
${MODEL_DIR}/parakeet     →  /root/.cache/local-transcribe/parakeet
```

`setup.sh` symlinks these to your existing host caches (`~/.cache/huggingface` and `~/.cache/local-transcribe/parakeet`) when present, so nothing already downloaded is re-fetched. To use a different location for the models entirely, point `MODEL_DIR` at any directory and `setup.sh` will create the subdirs there.

## Hooking up the `openwhispr` GUI launcher

The Linux `openwhispr` package installs a tiny shell wrapper at `/usr/local/bin/openwhispr` that forks `/opt/openwhispr/openwhispr`. `openwhispr-wrapper.sh` in this repo extends that wrapper to:

- auto-`docker compose up -d` the transcription server if `/health` doesn't respond
- read `PORT` from `.env` so port changes follow automatically
- show toasts via `notify-send` when starting / failing
- support `openwhispr --stop` (or `openwhispr stop`) to kill the GUI **and** `docker compose down` the server in one shot

Install (overwrites a system file — review the diff first):

```bash
diff /usr/local/bin/openwhispr ./openwhispr-wrapper.sh
sudo cp /usr/local/bin/openwhispr /usr/local/bin/openwhispr.bak     # backup
sudo install -m 755 ./openwhispr-wrapper.sh /usr/local/bin/openwhispr
```

Use:

```bash
openwhispr            # ensures container is up, then launches GUI
openwhispr --stop     # closes GUI and takes the container down
```

Rollback:

```bash
sudo mv /usr/local/bin/openwhispr.bak /usr/local/bin/openwhispr
```

If you move this repo, set `WHISPR_COMPOSE_DIR` in your shell environment to point at the new location — the wrapper honors that override.

## Switching models

```bash
sed -i 's/^MODEL=.*/MODEL=parakeet-v3/' .env
docker compose up -d
docker compose logs -f
```

The first request after a fresh model is slower while the model loads into VRAM; subsequent requests are hot.

## Troubleshooting

- **`could not select device driver "nvidia"`** — install `nvidia-container-toolkit` and restart Docker.
- **CUDA OOM** — pick a smaller model in `.env` (`turbo` → `small` → `base`).
- **Parakeet runs on CPU even with `DEVICE=cuda`** — expected. The PyPI `sherpa-onnx` wheel has no CUDA support; only Whisper uses the GPU.
- **Health check stays "unhealthy" for ~2 min after start** — the `start_period` is 120 s to cover model load. If still unhealthy after that, check `docker compose logs whispr`.
