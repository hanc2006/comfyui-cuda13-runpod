#!/usr/bin/env bash
# Container start: SSH -> volume layout -> node-pack deps -> File Browser -> llama-server -> ComfyUI (supervised).
#
# Env options:
#   COMFY_BASE        ComfyUI data on the volume: custom_nodes, input, output, user
#                     (default /workspace/ComfyUI)
#   COMFY_MODELS      models only, kept apart from everything else (default /workspace/models)
#   COMFY_ARGS        extra ComfyUI flags, e.g. "--highvram"
#   SKIP_NODE_DEPS=1  skip the requirements check for volume node packs
#   NET_WAIT          seconds to wait for DNS before installing them (default 120)
#   FILEBROWSER_ENABLED   true (default) / false -> File Browser on :8080, root /workspace
#   FILEBROWSER_PASSWORD  admin password (min 12 chars). Unset: one is generated on first
#                         start and saved in /workspace/.filebrowser/admin-password.txt
#   LLAMA_ENABLED     1/true/yes/on -> start llama-server (default: off, not started)
#   LLAMA_ARG_MODEL   path to the .gguf llama-server loads (required when enabled; API on :8089)
#   LLAMA_ARG_*       any other llama-server option as env, e.g. LLAMA_ARG_CTX_SIZE=8192
#   LLAMA_ARGS        extra llama-server flags, e.g. "--mmproj /workspace/models/llm/mmproj.gguf"
#   KOKON_ENABLED     true in the Kokon image; false disables its browser service
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
    LOG="$PYTHONUSERBASE/node-deps.log"; : > "$LOG"
    echo "[entrypoint] node-pack requirements changed - installing into $PYTHONUSERBASE"
    echo "[entrypoint] ComfyUI starts when this is done; pip output: tail -f $LOG"

    # The pod's DNS can take a few seconds after the container starts: wait for it
    # (up to NET_WAIT seconds, default 120) instead of failing every install at once.
    net_ready() { getent hosts pypi.org >/dev/null 2>&1 && getent hosts github.com >/dev/null 2>&1; }
    WAITED=0
    until net_ready || [ "$WAITED" -ge "${NET_WAIT:-120}" ]; do
      [ "$WAITED" = 0 ] && echo "[entrypoint] waiting for DNS (pypi.org, github.com)..."
      sleep 2; WAITED=$((WAITED + 2))
    done
    if net_ready; then
      [ "$WAITED" -gt 0 ] && echo "[entrypoint] DNS ready after ${WAITED}s"
    else
      echo "[entrypoint] DNS still not resolving after ${WAITED}s - installing anyway; /etc/resolv.conf:"
      sed 's/^/    /' /etc/resolv.conf || true
    fi

    PIP=(python3 -m pip install --user --no-warn-script-location)
    install_pack() {   # $1 = requirements.txt; returns non-zero when anything failed
      local req=$1 pack START rc=0
      pack=$(basename "$(dirname "$req")")
      printf '\n===== %s (%s) =====\n' "$pack" "$(date '+%F %T')" >> "$LOG"
      START=$SECONDS
      # dlib -> prebuilt dlib-bin wheel. `|| true`: grep exits 1 when no line is left (an
      # empty requirements.txt, like rgthree-comfy's), which must not stop the container.
      grep -iv '^dlib' "$req" > /tmp/req.txt || true
      if "${PIP[@]}" -r /tmp/req.txt >>"$LOG" 2>&1 \
         || "${PIP[@]}" --no-build-isolation -r /tmp/req.txt >>"$LOG" 2>&1; then
        echo "  ok    $pack ($((SECONDS - START))s)"
      else
        echo "  FAIL  $pack ($((SECONDS - START))s, see $LOG)"; rc=1
      fi
      if grep -iq '^dlib' "$req"; then "${PIP[@]}" dlib-bin >>"$LOG" 2>&1 || { echo "  FAIL  dlib-bin for $pack"; rc=1; }; fi
      return $rc
    }
    ALL_START=$SECONDS
    FAILED=()
    for req in "$BASE"/custom_nodes/*/requirements.txt; do
      [ -f "$req" ] || continue
      echo "  ...   $(basename "$(dirname "$req")")"
      install_pack "$req" || FAILED+=("$req")
    done
    # One more try for the ones that failed (a network hiccup, a mirror that was slow).
    if [ "${#FAILED[@]}" -gt 0 ]; then
      echo "[entrypoint] retrying ${#FAILED[@]} failed pack(s) in 10s"
      sleep 10
      RETRY=("${FAILED[@]}"); FAILED=()
      for req in "${RETRY[@]}"; do install_pack "$req" || FAILED+=("$req"); done
    fi
    echo "[entrypoint] node-pack requirements done in $((SECONDS - ALL_START))s"
    # Marked done only when everything installed; otherwise the next start tries again.
    if [ "${#FAILED[@]}" -eq 0 ]; then
      echo "$NEW" > "$STAMP"
    else
      rm -f "$STAMP"
      echo "[entrypoint] ${#FAILED[@]} pack(s) still failing - they are retried on the next start (see $LOG)"
    fi
  fi

  # ---- comfy-env isolated envs (e.g. ComfyUI-SAM3) -> $COMFY_ENV_ROOT (persists on the volume) ----
  # Packs built on comfy-env keep heavy deps in their own env, which only their install.py
  # builds (ComfyUI-Manager would run it; packs copied to the volume never get that).
  # Run it per pack when its comfy-env*.toml files changed; marked done only on success.
  CE_ROOT="${COMFY_ENV_ROOT:-/workspace/.ce}"
  mkdir -p "$CE_ROOT"
  for inst in "$BASE"/custom_nodes/*/install.py; do
    [ -f "$inst" ] && grep -q 'comfy_env' "$inst" || continue
    dir=$(dirname "$inst"); pack=$(basename "$dir")
    sum=$(find "$dir" -maxdepth 3 -name 'comfy-env*.toml' -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)
    mark="$CE_ROOT/.installed-$pack"
    [ "$sum" = "$(cat "$mark" 2>/dev/null || true)" ] && continue
    CE_LOG="$CE_ROOT/install-$pack.log"
    echo "[entrypoint] building the comfy-env env of $pack (first time can take minutes; log: $CE_LOG)"
    START=$SECONDS
    if (cd "$dir" && python3 install.py) > "$CE_LOG" 2>&1; then
      echo "$sum" > "$mark"
      echo "  ok    $pack env ($((SECONDS - START))s)"
    else
      rm -f "$mark"
      echo "  FAIL  $pack env ($((SECONDS - START))s) - retried on the next start; see $CE_LOG"
    fi
  done
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

# ---- Optional Kokon browser service (included in the Kokon image only) ----
if is_on "${KOKON_ENABLED:-false}"; then
  if ! command -v kokon-service >/dev/null || ! id kokon >/dev/null 2>&1; then
    echo "[entrypoint] KOKON_ENABLED is on but Kokon is not installed in this image" >&2
    exit 1
  fi
  : "${QLS_DATA_DIR:?QLS_DATA_DIR must be set}"
  : "${QLS_CONFIG_DIR:?QLS_CONFIG_DIR must be set}"
  : "${QLS_OUTPUT_DIR:?QLS_OUTPUT_DIR must be set}"
  mkdir -p "$QLS_DATA_DIR" "$QLS_CONFIG_DIR" "$QLS_OUTPUT_DIR"
  chown kokon:kokon "$QLS_DATA_DIR" "$QLS_CONFIG_DIR" "$QLS_OUTPUT_DIR"
  echo "[entrypoint] Kokon on :39152 (log $QLS_DATA_DIR/kokon-service.log)"
  runuser -u kokon -- kokon-service --persistent --remote > "$QLS_DATA_DIR/kokon-service.log" 2>&1 &
fi

# ---- ComfyUI, supervised ----
# This script stays the container's main process and runs ComfyUI as a child, so
# stopping/crashing ComfyUI no longer stops the container (SSH, File Browser and
# llama-server keep running). ComfyUI is NOT restarted automatically: when it exits
# it stays stopped until one of these commands is run inside the pod:
#   comfyui-start     start it again
#   comfyui-restart   stop it and start it again right away
#   comfyui-stop      stop it (e.g. to run it by hand)
STOP_FILE=/tmp/comfyui.stop          # present = stay stopped
RESTART_FILE=/tmp/comfyui.restart    # present = start again right after exiting
ARGS_FILE=/tmp/comfyui.args          # extra flags from comfyui-start/-restart
rm -f "$STOP_FILE" "$RESTART_FILE" "$ARGS_FILE"
CHILD=0
on_term() { [ "$CHILD" -gt 0 ] && kill -TERM "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; exit 0; }
trap on_term TERM INT

cd /opt/ComfyUI
while true; do
  if [ -f "$STOP_FILE" ]; then sleep 2 & wait $!; continue; fi
  # extra flags saved by comfyui-start / comfyui-restart (one per line)
  EXTRA=()
  [ -s "$ARGS_FILE" ] && mapfile -t EXTRA < "$ARGS_FILE"
  echo "[entrypoint] ComfyUI flags: ${COMFY_ARGS:-} ${EXTRA[*]}"
  # shellcheck disable=SC2086  # COMFY_ARGS is intentionally word-split
  python3 main.py --listen 0.0.0.0 --port 8188 --base-directory "$BASE" --models-directory "$MODELS" ${COMFY_ARGS:-} "${EXTRA[@]}" &
  CHILD=$!
  RC=0; wait "$CHILD" || RC=$?
  CHILD=0
  if [ -f "$RESTART_FILE" ]; then
    rm -f "$RESTART_FILE" "$STOP_FILE"
    echo "[entrypoint] ComfyUI restarting"
  else
    touch "$STOP_FILE"
    echo "[entrypoint] ComfyUI exited (code $RC) and stays stopped - run comfyui-start to start it"
  fi
done
