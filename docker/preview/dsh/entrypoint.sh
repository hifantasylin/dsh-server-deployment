#!/bin/bash
# dsh-preview 启动入口（以 dsh 用户运行）：
#   首次：官方 web profile auto-init -> 注入通用插件基线 -> 写 Rouba brand
#         patch -> pnpm install（数据入命名卷 dsh-home）
#   启动：dsh web (127.0.0.1:WEB_PORT) + socat 桥 (0.0.0.0:BRIDGE_PORT)
set -e

BASE=/opt/deepseek-harness
DSH_BIN="$BASE/app/node_modules/@deepseek-ai/dsh/lib/bin.js"
HOME_DIR="${DSH_HOME_DIR:-/home/dsh/dsh-home}"
WEB_PORT="${DSH_WEB_PORT:-3101}"
BRIDGE_PORT="${DSH_BRIDGE_PORT:-3102}"

mkdir -p "$HOME_DIR"
PROFILE_DIR="$HOME_DIR/profiles/web"
PROFILE_JSON="$PROFILE_DIR/package.json"
PATCH_FILE="$PROFILE_DIR/cordis.patch.yml"

if [ ! -f "$PROFILE_JSON" ]; then
  echo "[entry] first boot: auto-init web profile (DSH_HOME=$HOME_DIR) ..."
  DSH_HOME="$HOME_DIR" node "$DSH_BIN" --profile web --host 127.0.0.1 --port 33999 --no-open \
    >/home/dsh/first-boot.log 2>&1 &
  IPID=$!
  sleep 12
  kill "$IPID" 2>/dev/null || true
  sleep 1
  if [ ! -f "$PROFILE_JSON" ]; then
    echo "[entry] auto-init FAILED:"; tail -30 /home/dsh/first-boot.log; exit 1
  fi
  echo "[entry] injecting universal plugin baseline ..."
  node /usr/local/bin/inject-profile.mjs "$PROFILE_JSON"
  cat > "$PATCH_FILE" <<'YAML'
# Rouba owns the brand slots: disable the shipped official occupant first
# (same sidebar.brand.* / conversation.hero.brand.* slot names), then mount
# the Rouba brand occupant.
- id: ui-brand-official
  disabled: true
- insert:
    - id: roubaai-brand
      name: '@deepseek-ai/dsh-client-ui-brand-rouba'
YAML
  cd "$PROFILE_DIR"
  rm -rf node_modules pnpm-lock.yaml
  pnpm install >>/home/dsh/first-boot.log 2>&1 || { echo "[entry] pnpm install FAILED:"; tail -30 /home/dsh/first-boot.log; exit 1; }
fi

echo "[entry] starting dsh web on 127.0.0.1:$WEB_PORT ..."
DSH_HOME="$HOME_DIR" HOME="$HOME_DIR" nohup node "$DSH_BIN" --profile web --host 127.0.0.1 --port "$WEB_PORT" --no-open \
  >/home/dsh/web.log 2>&1 &
WEB_PID=$!

for i in $(seq 1 20); do
  grep -q 'dsh web:' /home/dsh/web.log && break
  kill -0 "$WEB_PID" 2>/dev/null || break
  sleep 1
done

if grep -q 'dsh web:' /home/dsh/web.log; then
  echo "[entry] socat bridge 0.0.0.0:$BRIDGE_PORT -> 127.0.0.1:$WEB_PORT ..."
  nohup socat TCP-LISTEN:"$BRIDGE_PORT",fork,reuseaddr TCP:127.0.0.1:"$WEB_PORT" >/home/dsh/socat.log 2>&1 &
  BRIDGE_PID=$!
else
  echo "[entry] web may not be up yet; log tail:"; tail -40 /home/dsh/web.log
fi

echo "[entry] dsh web ready: $(grep -o 'dsh web: http[^ ]*' /home/dsh/web.log | head -1)"
echo "[entry] container access via http://localhost:$BRIDGE_PORT/?token=... (nginx upstream)"

# 保持前台并随任一子进程退出退出
trap 'kill $WEB_PID $BRIDGE_PID 2>/dev/null || true' EXIT TERM INT
while kill -0 "$WEB_PID" 2>/dev/null; do sleep 3; done
wait
