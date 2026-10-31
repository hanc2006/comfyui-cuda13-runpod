#!/usr/bin/env bash
# Container start: SSH -> volume layout -> node-pack deps -> File Browser -> llama-server -> ComfyUI (supervised).
#
# Env options:
#   COMFY_BASE        ComfyUI data on the volume: custom_nodes, input, output, user
#                     (default /workspace/ComfyUI)
#   COMFY_MODELS      models only, kept apart from everything else (default /workspace/models)
#   COMFY_ARGS        extra ComfyUI flags, e.g. "--highvram"
#   SKIP_NODE_DEPS=1  skip the requirements check for volume node packs
#   FILEBROWSER_ENABLED   true (default) / false -> File Browser on :8080, root /workspace
#   FILEBROWSER_PASSWORD  admin password (min 12 chars). Unset: one is generated on first
#                         start and saved in /workspace/.filebrowser/admin-password.txt
#   LLAMA_ENABLED     1/true/yes/on -> start llama-server (default: off, not started)
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

# ---- File Browser (web file manager for /workspace, login required) ----
is_on() { case "${1:-}" in 1|true|TRUE|True|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac; }
if is_on "${FILEBROWSER_ENABLED:-true}"; then
  FB_DIR=/workspace/.filebrowser; FB_DB="$FB_DIR/filebrowser.db"; FB_PWFILE="$FB_DIR/admin-password.txt"
  mkdir -p "$FB_DIR" && chmod 700 "$FB_DIR"
  fb() { filebrowser -d "$FB_DB" "$@" >/dev/null 2>&1; }
  if [ ! -f "$FB_DB" ]; then
    PW="${FILEBROWSER_PASSWORD:-$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)}"
    fb config init && fb users add admin "$PW" --perm.admin \
      || { echo "[entrypoint] File Browser setup failed (password must be 12+ chars)"; rm -f "$FB_DB"; }
    [ -z "${FILEBROWSER_PASSWORD:-}" ] && [ -f "$FB_DB" ] && { umask 077; echo "$PW" > "$FB_PWFILE"; \
      echo "[entrypoint] File Browser admin password generated: see $FB_PWFILE"; }
  elif [ -n "${FILEBROWSER_PASSWORD:-}" ]; then
    fb users update admin --password "$FILEBROWSER_PASSWORD" && rm -f "$FB_PWFILE" \
      || echo "[entrypoint] FILEBROWSER_PASSWORD not applied (must be 12+ chars)"
  fi
  if [ -f "$FB_DB" ]; then
    fb config set --address 0.0.0.0 --port 8080 --root /workspace
    echo "[entrypoint] File Browser on :8080 (user admin)"
    filebrowser -d "$FB_DB" > /workspace/.filebrowser/filebrowser.log 2>&1 &
  fi
fi

# ---- Optional llama-server (shares the GPU with ComfyUI) ----
if is_on "${LLAMA_ENABLED:-false}"; then
  if [ -z "${LLAMA_ARG_MODEL:-}" ]; then
    echo "[entrypoint] LLAMA_ENABLED is on but LLAMA_ARG_MODEL is empty - llama-server not started"
  elif [ -f "$LLAMA_ARG_MODEL" ]; then
    export LLAMA_ARG_HOST="${LLAMA_ARG_HOST:-0.0.0.0}" LLAMA_ARG_PORT="${LLAMA_ARG_PORT:-8089}" \
           LLAMA_ARG_N_GPU_LAYERS="${LLAMA_ARG_N_GPU_LAYERS:-999}"
    echo "[entrypoint] llama-server: $LLAMA_ARG_MODEL on :$LLAMA_ARG_PORT (log /workspace/llama-server.log)"
    # shellcheck disable=SC2086  # LLAMA_ARGS is intentionally word-split
    LD_LIBRARY_PATH=/opt/llama llama-server ${LLAMA_ARGS:-} > /workspace/llama-server.log 2>&1 &
  else
    echo "[entrypoint] LLAMA_ARG_MODEL=$LLAMA_ARG_MODEL not found - llama-server not started"
  fi
fi

# ---- ComfyUI, supervised ----
# This script stays the container's main process and runs ComfyUI as a child, so
# stopping/crashing ComfyUI no longer stops the container (SSH, File Browser and
# llama-server keep running). Commands inside the pod:
#   comfyui-restart   restart ComfyUI
#   comfyui-stop      stop it and keep it stopped (e.g. to run it by hand)
#   comfyui-start     let the supervisor start it again
STOP_FILE=/tmp/comfyui.stop
rm -f "$STOP_FILE"
CHILD=0
on_term() { [ "$CHILD" -gt 0 ] && kill -TERM "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; exit 0; }
trap on_term TERM INT

cd /opt/ComfyUI
while true; do
  if [ -f "$STOP_FILE" ]; then sleep 2 & wait $!; continue; fi
  # shellcheck disable=SC2086  # COMFY_ARGS is intentionally word-split
  python3 main.py --listen 0.0.0.0 --port 8188 --base-directory "$BASE" --models-directory "$MODELS" ${COMFY_ARGS:-} &
  CHILD=$!
  RC=0; wait "$CHILD" || RC=$?
  CHILD=0
  if [ -f "$STOP_FILE" ]; then
    echo "[entrypoint] ComfyUI stopped (exit $RC) - run comfyui-start to start it again"
  else
    echo "[entrypoint] ComfyUI exited (code $RC) - restarting in 3 s"
    sleep 3 & wait $!
  fi
done
