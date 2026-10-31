# comfyui-cuda13-runpod

A clean ComfyUI image for RunPod: Debian 13 slim, Python 3.13, PyTorch for CUDA 13.0, an
optional `llama-server` (llama.cpp, CUDA 13), and SSH. Nothing app-specific is baked in —
node packs, models and outputs live on the network volume, so the image stays small and
generic and the data survives pod restarts.

## What lives where

| Path | Where | Contents |
|---|---|---|
| `/opt/ComfyUI` | image | ComfyUI code |
| `/opt/llama` | image | `llama-server` + the CUDA libs it needs |
| `/workspace/models` | volume | **models only** (`checkpoints`, `loras`, `vae`, `diffusion_models`, `text_encoders`, …) |
| `/workspace/ComfyUI` | volume | `custom_nodes`, `input`, `output`, `user` |
| `/workspace/.python` | volume | Python packages of the node packs in `custom_nodes` |

On every start the entrypoint creates any missing standard model folders (existing files are
never touched), copies ComfyUI-Manager into `custom_nodes` if it is not there, and installs
the node packs' `requirements.txt` into `/workspace/.python` **only when they changed** — the
first start after adding packs is slow, later starts are fast. Install log:
`/workspace/.python/node-deps.log`.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `COMFY_MODELS` | `/workspace/models` | models folder |
| `COMFY_BASE` | `/workspace/ComfyUI` | custom_nodes / input / output / user |
| `COMFY_ARGS` | – | extra ComfyUI flags, e.g. `--highvram` |
| `COMFY_CORS_PORT` | – | e.g. `8774`: allow `https://<pod>-8774.proxy.runpod.net` (a web UI on that port) to call ComfyUI |
| `SKIP_NODE_DEPS` | `0` | `1` = skip the node-pack requirements check |
| `LLAMA_ENABLED` | `false` | `true` = start `llama-server` on port 8089 |
| `LLAMA_ARG_MODEL` | – | `.gguf` to load, e.g. `/workspace/models/llm/model.gguf` (required when enabled) |
| `LLAMA_ARG_*` | – | any llama-server option, e.g. `LLAMA_ARG_CTX_SIZE=8192` |
| `LLAMA_ARGS` | – | extra flags, e.g. `--mmproj /workspace/models/llm/mmproj.gguf --api-key <secret>` |
| `PUBLIC_KEY` | set by RunPod | SSH key for `root` (password login is disabled) |

## RunPod template

- **Image:** `<dockerhub-user>/comfyui-cuda13:latest`
- **Ports:** `8188/http` (ComfyUI), `22/tcp` (SSH), plus `8774/http` / `8089/http` if used
- **Volume:** network volume mounted at `/workspace`
- **GPU filter:** CUDA 13.x drivers. PyTorch is built for CUDA 13.0; llama.cpp's CUDA 13
  image uses 13.4 libraries and relies on CUDA 13 minor-version compatibility on older 13.x
  drivers — if `llama-server` fails with a CUDA error, pick hosts with CUDA ≥ 13.4.

## Moving an existing install to this layout

If models are currently in `/workspace/ComfyUI/models`, move them once (from a pod shell):

```bash
mkdir -p /workspace/models
cp -rn /workspace/ComfyUI/models/. /workspace/models/ && rm -rf /workspace/ComfyUI/models
```

## Build

Pushing to `main` builds and pushes the image with GitHub Actions
(`.github/workflows/docker.yml`). Set these repository secrets first:

- `DOCKERHUB_USERNAME` – your Docker Hub user
- `DOCKERHUB_TOKEN` – a Docker Hub access token

Tags pushed: `latest` and the short commit SHA. The workflow can also be started by hand
(**Actions → Build and push image → Run workflow**) with an optional torch version pin and
ComfyUI ref.

Local build:

```bash
docker buildx build --platform linux/amd64 -t <dockerhub-user>/comfyui-cuda13:latest --push .
```

### Build arguments

| Arg | Default | Purpose |
|---|---|---|
| `LLAMA_IMAGE` | `ghcr.io/ggml-org/llama.cpp:server-cuda13` | source of `llama-server`; pin with `@sha256:<digest>` |
| `TORCH_INDEX` | `https://download.pytorch.org/whl/cu130` | PyTorch wheel index |
| `TORCH_VERSION` | empty (newest) | pin torch + torchaudio, e.g. `2.11.0` |
| `COMFY_REF` | `master` | ComfyUI branch or tag |
| `MANAGER_REF` | `main` | ComfyUI-Manager branch or tag |
