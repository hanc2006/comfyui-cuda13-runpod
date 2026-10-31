#!/usr/bin/env bash
# Container start: SSH -> volume layout -> node-pack deps -> llama-server -> autostart hook -> ComfyUI.
#
# Env options:
#   COMFY_BASE        ComfyUI data on the volume: custom_nodes, input, output, user
#                     (default /workspace/ComfyUI)
#   COMFY_MODELS      models only, kept apart from everything else (default /workspace/models)
#   COMFY_CORS_PORT   e.g. 8774 -> allow https://<pod>-8774.proxy.runpod.net to call ComfyUI
#   COMFY_ARGS        extra ComfyUI flags, e.g. "--highvram"
#   SKIP_NODE_DEPS=1  skip the requirements check for volume node packs
#   LLAMA_ENABLED     1/true/yes/on -> start llama-server (default: off)
#   LLAMA_ARG_MODEL   path to the .gguf llama-server loads (required when enabled; API on :8089)
#   LLAMA_ARG_*       any other llama-server option as env, e.g. LLAMA_ARG_CTX_SIZE=8192
#   LLAMA_ARGS        extra llama-server flags, e.g. "--mmproj /workspace/models/llm/mmproj.gguf"
set -euo pipefail

BASE="${COMFY_BASE:-/workspace/ComfyUI}"
MODELS="${COMFY_MODELS:-/workspace/models}"

# ---- SSH: RunPod injects the account key as PUBLIC_KEY ----
if [ -n "${PUBLIC_KEY:-}" ]; then
  mkdir -p /root/.ssh /run/sshd && chmod 700 /root/.ssh
  echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
  ssh-keygen -A >/dev/null          # per-container host keys
  /usr/sbin/sshd
fi

# ---- Volume layout (an existing /workspace/ComfyUI install is reused as-is) ----
mkdir -p "$BASE"/{custom_nodes,input,output,user} "$MODELS" "$PYTHONUSERBASE"
# Standard model folders (checkpoints, loras, vae, ...) from ComfyUI's own layout;
# existing folders and files are never touched. Node packs add their own (SEEDVR2, ...).
(cd /opt/ComfyUI/models && find . -mindepth 1 -type d -print0) | (cd "$MODELS" && xargs -0 -r mkdir -p)
[ -d "$BASE/custom_nodes/ComfyUI-Manager" ] || cp -r /opt/seed/ComfyUI-Manager "$BASE/custom_nodes/"

# ---- Python deps of volume node packs -> $PYTHONUSERBASE (persists on the volume) ----
# Re-run only when the set of requirements files changes, so normal boots are fast.
if [ "${SKIP_NODE_DEPS:-0}" != 1 ]; then
  STAMP="$PYTHONUSERBASE/.node-reqs.sha"
  NEW=$(find "$BASE/custom_nodes" -maxdepth 2 -name requirements.txt -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)
  if [ "$NEW" != "$(cat "$STAMP" 2>/dev/null || true)" ]; then
    echo "[entrypoint] node-pack requirements changed - installing into $PYTHONUSERBASE"
    LOG="$PYTHONUSERBASE/node-deps.log"; : > "$LOG"
    for req in "$BASE"/custom_nodes/*/requirements.txt; do
      [ -f "$req" ] || continue
      pack=$(basename "$(dirname "$req")")
      grep -iv '^dlib' "$req" > /tmp/req.txt    # dlib -> prebuilt dlib-bin wheel
      if python3 -m pip install --user -q -r /tmp/req.txt >>"$LOG" 2>&1 \
         || python3 -m pip install --user -q --no-build-isolation -r /tmp/req.txt >>"$LOG" 2>&1; then
        echo "  ok    $pack"
      else
        echo "  FAIL  $pack (see $LOG)"
      fi
      grep -iq '^dlib' "$req" && { python3 -m pip install --user -q dlib-bin >>"$LOG" 2>&1 || echo "  FAIL  dlib-bin for $pack"; }
    done
    echo "$NEW" > "$STAMP"
  fi
fi

# ---- Optional llama-server (shares the GPU with ComfyUI) ----
case "${LLAMA_ENABLED:-0}" in 1|true|TRUE|True|yes|YES|on|ON) LLAMA_ON=1 ;; *) LLAMA_ON=0 ;; esac
if [ "$LLAMA_ON" = 1 ]; then
  if [ -z "${LLAMA_ARG_MODEL:-}" ]; then
    echo "[entrypoint] LLAMA_ENABLED is on but LLAMA_ARG_MODEL is empty - llama-server not started"
  elif [ -f "$LLAMA_ARG_MODEL" ]; then
    export LLAMA_ARG_HOST="${LLAMA_ARG_HOST:-0.0.0.0}" LLAMA_ARG_PORT="${LLAMA_ARG_PORT:-8089}" \
           LLAMA_ARG_N_GPU_LAYERS="${LLAMA_ARG_N_GPU_LAYERS:-999}"
    echo "[entrypoint] llama-server: $LLAMA_ARG_MODEL on :$LLAMA_ARG_PORT (log /workspace/llama-server.log)"
    # shellcheck disable=SC2086  # LLAMA_ARGS is intentionally word-split
    llama-server ${LLAMA_ARGS:-} > /workspace/llama-server.log 2>&1 &
  else
    echo "[entrypoint] LLAMA_ARG_MODEL=$LLAMA_ARG_MODEL not found - llama-server not started"
  fi
fi

# ---- Optional hook: start other services kept on the volume ----
if [ -f /workspace/autostart.sh ]; then
  echo "[entrypoint] running /workspace/autostart.sh"
  bash /workspace/autostart.sh > /workspace/autostart.log 2>&1 &
fi

# ---- ComfyUI ----
CORS=()
if [ -n "${COMFY_CORS_PORT:-}" ] && [ -n "${RUNPOD_POD_ID:-}" ]; then
  CORS=(--enable-cors-header "https://${RUNPOD_POD_ID}-${COMFY_CORS_PORT}.proxy.runpod.net")
fi
cd /opt/ComfyUI
# shellcheck disable=SC2086  # COMFY_ARGS is intentionally word-split
exec python3 main.py --listen 0.0.0.0 --port 8188 --base-directory "$BASE" --models-directory "$MODELS" "${CORS[@]}" ${COMFY_ARGS:-}
