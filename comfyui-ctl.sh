#!/usr/bin/env bash
# =============================================================================
# comfyui-ctl.sh - control the ComfyUI process that entrypoint.sh supervises.
# Installed in the image as four commands (symlinks to this file):
#
#   comfyui-start   [FLAGS...]   start ComfyUI (after it was stopped or crashed)
#   comfyui-restart [FLAGS...]   stop it and start it again right away
#   comfyui-stop                 stop it and keep it stopped
#   comfyui-args                 show the startup flags ComfyUI runs with
#
# Extra startup flags
#   Flags given to comfyui-start / comfyui-restart are added to ComfyUI's command
#   line and kept for later restarts, until you change them:
#     comfyui-restart --use-split-cross-attention --reserve-vram 2
#     comfyui-restart                      # same extra flags as last time
#     comfyui-restart --defaults           # drop the extra flags
#     comfyui-restart --help               # list all ComfyUI flags (restarts nothing)
#   They are checked with ComfyUI's own option parser first; a flag ComfyUI does
#   not know (e.g. --medvram, which is an Automatic1111 flag) is reported and
#   nothing is restarted.
#   They last until the pod restarts (kept in /tmp). For flags on every start,
#   set the pod/template variable COMFY_ARGS instead.
#
# Base flags (always set by entrypoint.sh): --listen 0.0.0.0 --port 8188
#   --base-directory /workspace/ComfyUI --models-directory /workspace/models
# =============================================================================
set -euo pipefail

STOP_FILE=/tmp/comfyui.stop          # present = supervisor keeps ComfyUI stopped
RESTART_FILE=/tmp/comfyui.restart    # present = start again right after exiting
ARGS_FILE=/tmp/comfyui.args          # extra flags, one per line
COMFY_CODE="${COMFY_CODE:-/opt/ComfyUI}"
PATTERN='^python3 main.py --listen'  # anchored: matches ComfyUI only, never a shell

cmd="$(basename "$0")"
case "$cmd" in
  comfyui-start|comfyui-restart|comfyui-stop|comfyui-args) ;;
  *) cmd="comfyui-${1:-}"; shift || true ;;
esac

running() { pgrep -f "$PATTERN" >/dev/null; }

# COMFY_ARGS as the container got it. SSH shells don't inherit the container's
# environment, so read it from the main process (PID 1).
container_comfy_args() {
  local env1
  if env1="$( { tr '\0' '\n' < /proc/1/environ; } 2>/dev/null )"; then
    printf '%s\n' "$env1" | sed -n 's/^COMFY_ARGS=//p' | head -1
  else
    printf '%s\n' "${COMFY_ARGS:-}"
  fi
}

# Check flags with ComfyUI's own parser (fast: no torch import).
validate() {
  # shellcheck disable=SC2046  # COMFY_ARGS is intentionally word-split
  COMFY_CODE="$COMFY_CODE" python3 - $(container_comfy_args) "$@" <<'PY'
import os, sys
sys.path.insert(0, os.environ["COMFY_CODE"])
import comfy.cli_args as c
c.parser.prog = "ComfyUI"
c.parser.print_usage = lambda *a: None   # show only the error line, not the full usage
c.parser.parse_args(sys.argv[1:])   # prints the problem and exits 2 if a flag is wrong
PY
}

# Store new extra flags (if any were given); returns non-zero if they are invalid.
set_flags() {
  [ $# -eq 0 ] && return 0
  if [ "$1" = "--defaults" ]; then
    rm -f "$ARGS_FILE"; echo "Extra flags cleared."; return 0
  fi
  for f in "$@"; do
    case "$f" in -h|--help)   # list ComfyUI's flags; change nothing
      COMFY_CODE="$COMFY_CODE" python3 -c 'import os,sys; sys.path.insert(0,os.environ["COMFY_CODE"]); import comfy.cli_args as c; c.parser.prog="ComfyUI"; c.parser.print_help()'
      exit 0 ;;
    esac
  done
  if ! validate "$@"; then
    echo "Not applied: fix the flags above (ComfyUI would not start with them)." >&2
    return 1
  fi
  printf '%s\n' "$@" > "$ARGS_FILE"
  echo "Extra flags: $*"
}

show() {
  echo "Base:       --listen 0.0.0.0 --port 8188 --base-directory ... --models-directory ..."
  echo "COMFY_ARGS: $(container_comfy_args)"
  if [ -s "$ARGS_FILE" ]; then echo "Extra:      $(paste -sd' ' "$ARGS_FILE")"; else echo "Extra:      (none)"; fi
  if running; then echo "ComfyUI:    running"; else echo "ComfyUI:    stopped"; fi
}

case "$cmd" in
  comfyui-restart)
    set_flags "$@" || exit 1
    if running; then
      touch "$RESTART_FILE"
      pkill -f "$PATTERN"
    else
      rm -f "$STOP_FILE" "$RESTART_FILE"
    fi
    echo "ComfyUI restarting"
    ;;
  comfyui-start)
    if running; then
      echo "ComfyUI is already running (use comfyui-restart to change its flags)."
      exit 0
    fi
    set_flags "$@" || exit 1
    rm -f "$STOP_FILE"; echo "ComfyUI starting"
    ;;
  comfyui-stop)
    touch "$STOP_FILE"; rm -f "$RESTART_FILE"
    pkill -f "$PATTERN" || true
    echo "ComfyUI stopped (comfyui-start to start it again)"
    ;;
  comfyui-args)
    show
    ;;
  *)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
