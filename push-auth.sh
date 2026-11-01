#!/usr/bin/env bash
# Copies CLIProxyAPI's subscription logins from this Mac to the VPS proxy, checks that the proxy
# sees them, and offers to stop this Mac's proxy so two proxies do not refresh the same logins.
#
#   ./push-auth.sh t3-vps [--user t3admin] [--from ~/cliproxyapi/auth]
set -euo pipefail

HOST=""
ADMIN_USER="t3admin"
FROM="$HOME/cliproxyapi/auth"
LOCAL_LABEL="local.cliproxyapi"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) ADMIN_USER="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    -h|--help) sed -n 2,6p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) HOST="$1"; shift ;;
  esac
done
[[ -n "$HOST" ]] || { echo "Usage: $0 <vps-host> [--user t3admin] [--from DIR]" >&2; exit 2; }
[[ -d "$FROM" ]] || { echo "No auth folder at $FROM" >&2; exit 1; }
count="$(find "$FROM" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
[[ "$count" -gt 0 ]] || { echo "No logins (*.json) in $FROM" >&2; exit 1; }

target="$ADMIN_USER@$HOST"
echo "==> Copying $count login(s) from $FROM to $target"
# Streamed over SSH; nothing is written to disk outside the proxy's own folder.
COPYFILE_DISABLE=1 tar -czf - -C "$FROM" --exclude '.*' . | ssh "$target" '
  set -e
  sudo tar -xzf - -C /var/lib/cliproxy/auth --no-same-owner
  sudo chown -R cliproxy:cliproxy /var/lib/cliproxy/auth
  sudo find /var/lib/cliproxy/auth -type d -exec chmod 700 {} +
  sudo find /var/lib/cliproxy/auth -type f -exec chmod 600 {} +
  sudo systemctl restart cliproxy
'

echo "==> Checking the proxy on $HOST"
models="$(ssh "$target" '
  for i in $(seq 20); do
    out="$(sudo sh -c "curl -fsS -H \"Authorization: Bearer \$(cat /etc/t3-vps/proxy-key)\" http://127.0.0.1:8317/v1/models" 2>/dev/null)" && break
    sleep 1
  done
  printf "%s" "$out" | jq -r ".data | length"
' || true)"
if [[ -z "$models" || "$models" == 0 || "$models" == null ]]; then
  echo "The proxy on $HOST does not list any models yet. Check: ssh $target journalctl -u cliproxy -n 50" >&2
  exit 1
fi
echo "The proxy on $HOST lists $models models."

if launchctl print "gui/$(id -u)/$LOCAL_LABEL" >/dev/null 2>&1; then
  cat <<EOF

This Mac's proxy ($LOCAL_LABEL) is still running with the same logins. Two proxies that refresh
the same login can sign each other out. Stopping it also stops Claude Code and Codex on this Mac
until you point them somewhere else.
EOF
  read -r -p "Stop this Mac's proxy now? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    launchctl bootout "gui/$(id -u)/$LOCAL_LABEL" || true
    launchctl disable "gui/$(id -u)/$LOCAL_LABEL"
    echo "Stopped and disabled. To bring it back: launchctl enable gui/$(id -u)/$LOCAL_LABEL && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$LOCAL_LABEL.plist"
  else
    echo "Left running. Stop it before relying on the VPS: launchctl bootout gui/$(id -u)/$LOCAL_LABEL"
  fi
fi
