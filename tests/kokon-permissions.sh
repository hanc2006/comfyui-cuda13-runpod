#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
for scenario in fresh existing; do
  docker run --rm -i -v "$root/entrypoint.sh:/entrypoint.sh:ro" \
    -e SCENARIO="$scenario" debian:13-slim bash -s <<'SCRIPT'
set -euo pipefail
useradd --create-home --uid 1000 kokon
mkdir -p /opt/ComfyUI/models /workspace
cat > /usr/local/bin/filebrowser <<'EOF'
#!/bin/bash
db=$2
shift 2
if [ "$1 $2" = "config init" ]; then touch "$db"; fi
if [ "$#" -eq 0 ]; then sleep 60; fi
EOF
cat > /usr/local/bin/kokon-service <<'EOF'
#!/bin/bash
echo started > "$QLS_DATA_DIR/logs/service.log"
EOF
cat > /usr/local/bin/python3 <<'EOF'
#!/bin/bash
sleep 60
EOF
chmod +x /usr/local/bin/filebrowser /usr/local/bin/kokon-service /usr/local/bin/python3
if [ "$SCENARIO" = existing ]; then
  mkdir -p /workspace/kokon/{data/logs,config,gallery}
  touch /workspace/kokon/data/logs/service.log
  chmod 700 /workspace/kokon /workspace/kokon/data/logs
  chmod 600 /workspace/kokon/data/logs/service.log
fi
export PYTHONUSERBASE=/workspace/.python SKIP_NODE_DEPS=1 KOKON_ENABLED=true \
  QLS_DATA_DIR=/workspace/kokon/data QLS_CONFIG_DIR=/workspace/kokon/config \
  QLS_OUTPUT_DIR=/workspace/kokon/gallery
bash /entrypoint.sh > /tmp/entrypoint.log 2>&1 &
pid=$!
for i in {1..30}; do
  if [ -f "$QLS_DATA_DIR/logs/service.log" ] && grep -q started "$QLS_DATA_DIR/logs/service.log"; then
    test "$(stat -c %a /workspace/.filebrowser/admin-password.txt)" = 600
    runuser -u kokon -- test -w "$QLS_DATA_DIR/logs"
    kill "$pid"
    echo "$SCENARIO: Kokon can write its logs"
    exit 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/entrypoint.log
test ! -f "$QLS_DATA_DIR/kokon-service.log" || cat "$QLS_DATA_DIR/kokon-service.log"
exit 1
SCRIPT
done
