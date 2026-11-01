#!/usr/bin/env bash
# Turns a fresh Ubuntu 24.04 VPS into a T3 Code host you control from another computer over
# Tailscale: T3 Code, T3 Bridge, Claude Code and Codex behind a local CLIProxyAPI, pstack, and a
# firewall that only lets your tailnet in. Safe to run again.
#
#   curl -fsSL https://raw.githubusercontent.com/rizaardiyanto1412/t3-vps/main/setup.sh \
#     | sudo bash -s -- --tailscale-key tskey-auth-...
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup.sh --tailscale-key KEY [options]

  --tailscale-key KEY   Tailscale auth key (pre-approved, tagged). Not needed once the VPS is on your tailnet.
  --hostname NAME       Name on the tailnet (default: t3-vps)
  --admin-user NAME     Your login with sudo (default: the sudo caller, or t3admin)
  --bridge SPEC         npm spec for T3 Bridge (default: t3-bridge@latest)
  --no-pstack           Skip the pstack skills
  --skip-tailscale      Test only: no Tailscale, no pairing over the tailnet
  --skip-firewall       Test only: leave SSH and the firewall as they are
EOF
}

TAILSCALE_KEY=""
TS_HOSTNAME="t3-vps"
ADMIN_USER=""
AGENT_USER="agent"
PROXY_USER="cliproxy"
BRIDGE_SPEC="t3-bridge@latest"
PSTACK=1
SKIP_TAILSCALE=0
SKIP_FIREWALL=0
NODE_MAJOR=24
PROXY_DIR="/var/lib/cliproxy"
PROXY_PORT=8317
STATE_DIR="/etc/t3-vps"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tailscale-key) TAILSCALE_KEY="$2"; shift 2 ;;
    --hostname) TS_HOSTNAME="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --bridge) BRIDGE_SPEC="$2"; shift 2 ;;
    --no-pstack) PSTACK=0; shift ;;
    --skip-tailscale) SKIP_TAILSCALE=1; shift ;;
    --skip-firewall) SKIP_FIREWALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: curl ... | sudo bash -s -- --tailscale-key ..."
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "This script supports Ubuntu only (found ${ID:-unknown})."
[[ "${VERSION_ID:-}" == 24.04 ]] || warn "Tested on Ubuntu 24.04; this is ${VERSION_ID:-unknown}."
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) PROXY_ARCH=amd64 ;;
  arm64) PROXY_ARCH=aarch64 ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac

if [[ -z "$ADMIN_USER" ]]; then
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then ADMIN_USER="$SUDO_USER"; else ADMIN_USER="t3admin"; fi
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
exec > >(tee -a /var/log/t3-vps-setup.log) 2>&1
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------------------------
step "System packages and automatic security updates"
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
apt-get -y -q install ca-certificates curl git jq unzip zsh rsync python3 build-essential \
  ufw unattended-upgrades gh openssl
systemctl enable --now unattended-upgrades >/dev/null

if ! swapon --show | grep -q . && [[ ! -f /swapfile ]]; then
  step "Swap (4 GB), so builds and browsers do not run out of memory"
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# ---------------------------------------------------------------------------------------------
TS_NAME=""
TS_IP=""
if [[ $SKIP_TAILSCALE -eq 0 ]]; then
  step "Tailscale"
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
  if [[ "$(tailscale status --json 2>/dev/null | jq -r .BackendState)" != Running ]]; then
    [[ -n "$TAILSCALE_KEY" ]] || die "This VPS is not on your tailnet yet. Pass --tailscale-key."
    tailscale up --auth-key="$TAILSCALE_KEY" --hostname="$TS_HOSTNAME"
  fi
  for _ in $(seq 30); do
    TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    [[ -n "$TS_IP" ]] && break
    sleep 1
  done
  [[ -n "$TS_IP" ]] || die "Tailscale did not get an address. Check: tailscale status"
  TS_NAME="$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
  echo "On the tailnet as $TS_NAME ($TS_IP)"
fi

# ---------------------------------------------------------------------------------------------
step "Users: $ADMIN_USER (you, sudo), $AGENT_USER (agents, no sudo), $PROXY_USER (proxy only)"
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
fi
usermod -aG sudo "$ADMIN_USER"
echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/90-t3-vps-$ADMIN_USER"
chmod 440 "/etc/sudoers.d/90-t3-vps-$ADMIN_USER"
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
ADMIN_KEYS="$ADMIN_HOME/.ssh/authorized_keys"
if [[ ! -s "$ADMIN_KEYS" && -s /root/.ssh/authorized_keys ]]; then
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"
  install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /root/.ssh/authorized_keys "$ADMIN_KEYS"
  echo "Copied root's SSH keys to $ADMIN_USER"
fi

if ! id "$AGENT_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$AGENT_USER"
fi
for group in sudo admin wheel; do gpasswd -d "$AGENT_USER" "$group" >/dev/null 2>&1 || true; done
rm -f "/etc/sudoers.d/90-t3-vps-$AGENT_USER"
AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
AGENT_UID="$(id -u "$AGENT_USER")"
chmod 750 "$AGENT_HOME"
install -d -m 755 -o "$AGENT_USER" -g "$AGENT_USER" "$AGENT_HOME/Code"

if ! id "$PROXY_USER" >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin -d "$PROXY_DIR" "$PROXY_USER"
fi

# Lingering starts the agent's systemd manager at boot, so T3 Code and the bridge run with nobody logged in.
loginctl enable-linger "$AGENT_USER"
for _ in $(seq 30); do [[ -S "/run/user/$AGENT_UID/bus" ]] && break; sleep 1; done
[[ -S "/run/user/$AGENT_UID/bus" ]] || die "The systemd user manager for $AGENT_USER did not start."

# Runs a command as the agent with its own home, PATH and systemd user manager.
as_agent() {
  runuser -u "$AGENT_USER" -- env -i \
    HOME="$AGENT_HOME" USER="$AGENT_USER" LOGNAME="$AGENT_USER" SHELL=/bin/bash LANG=C.UTF-8 \
    PATH="$AGENT_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="/run/user/$AGENT_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$AGENT_UID/bus" \
    bash -c "cd ~ && $1"
}

# ---------------------------------------------------------------------------------------------
step "Node.js $NODE_MAJOR"
if ! command -v node >/dev/null || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get -y -q install nodejs
fi
node --version

# ---------------------------------------------------------------------------------------------
step "CLIProxyAPI (subscription logins, readable only by $PROXY_USER)"
install -d -m 700 -o "$PROXY_USER" -g "$PROXY_USER" "$PROXY_DIR" "$PROXY_DIR/auth"
PROXY_TAG="$(curl -fsSL https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest | jq -r .tag_name)"
PROXY_VERSION="${PROXY_TAG#v}"
INSTALLED_PROXY="$(cat "$STATE_DIR/proxy-version" 2>/dev/null || true)"
if [[ "$INSTALLED_PROXY" != "$PROXY_VERSION" || ! -x /usr/local/bin/cliproxyapi ]]; then
  work="$(mktemp -d)"
  asset="CLIProxyAPI_${PROXY_VERSION}_linux_${PROXY_ARCH}.tar.gz"
  base="https://github.com/router-for-me/CLIProxyAPI/releases/download/$PROXY_TAG"
  curl -fsSL -o "$work/$asset" "$base/$asset"
  curl -fsSL -o "$work/checksums.txt" "$base/checksums.txt"
  (cd "$work" && grep " $asset\$" checksums.txt | sha256sum -c -) || die "CLIProxyAPI download failed its checksum."
  tar -xzf "$work/$asset" -C "$work" cli-proxy-api
  install -m 755 "$work/cli-proxy-api" /usr/local/bin/cliproxyapi
  rm -rf "$work"
  echo "$PROXY_VERSION" >"$STATE_DIR/proxy-version"
fi
echo "CLIProxyAPI $PROXY_VERSION"

if [[ ! -s "$STATE_DIR/proxy-key" ]]; then
  (umask 077 && openssl rand -hex 32 >"$STATE_DIR/proxy-key")
fi
PROXY_KEY="$(cat "$STATE_DIR/proxy-key")"
# Rewritten on every run so the key and the auth folder always match this script.
cat >"$PROXY_DIR/config.yaml" <<EOF
# Written by t3-vps setup.sh; changes are replaced on the next run.
config-version: 8
server:
  host: "127.0.0.1"
  port: $PROXY_PORT
management:
  allow-remote: false
  secret-key: ""
access:
  api-keys:
    - "$PROXY_KEY"
routing:
  strategy: "round-robin"
  session-affinity: true
oauth:
  auth-dir: "$PROXY_DIR/auth"
observability:
  logs:
    debug: false
    logging-to-file: false
  usage:
    usage-statistics-enabled: false
EOF
chown "$PROXY_USER:$PROXY_USER" "$PROXY_DIR/config.yaml"
chmod 600 "$PROXY_DIR/config.yaml"

cat >/etc/systemd/system/cliproxy.service <<EOF
[Unit]
Description=CLIProxyAPI (subscription proxy for Claude Code and Codex)
After=network-online.target
Wants=network-online.target

[Service]
User=$PROXY_USER
Group=$PROXY_USER
WorkingDirectory=$PROXY_DIR
Environment=HOME=$PROXY_DIR
ExecStart=/usr/local/bin/cliproxyapi -config $PROXY_DIR/config.yaml -local-model
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
UMask=0077
ReadWritePaths=$PROXY_DIR

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cliproxy.service >/dev/null
systemctl restart cliproxy.service

# ---------------------------------------------------------------------------------------------
step "Claude Code and Codex for $AGENT_USER, pointed at the proxy"
as_agent 'npm config set prefix ~/.local >/dev/null'
as_agent 'command -v codex >/dev/null || npm install -g --silent @openai/codex'
as_agent 'command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash'

runuser -u "$AGENT_USER" -- env HOME="$AGENT_HOME" PROXY_KEY="$PROXY_KEY" PROXY_PORT="$PROXY_PORT" python3 - <<'PY'
import json, os, pathlib
home = pathlib.Path(os.environ["HOME"])
key, port = os.environ["PROXY_KEY"], os.environ["PROXY_PORT"]

def merge(path, update):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.loads(path.read_text()) if path.exists() and path.read_text().strip() else {}
    update(data)
    path.write_text(json.dumps(data, indent=2) + "\n")
    path.chmod(0o600)

def claude_settings(data):
    env = data.setdefault("env", {})
    env["ANTHROPIC_BASE_URL"] = f"http://127.0.0.1:{port}"
    env["ANTHROPIC_AUTH_TOKEN"] = key

merge(home / ".claude" / "settings.json", claude_settings)
merge(home / ".claude.json", lambda data: data.setdefault("hasCompletedOnboarding", True))

codex = home / ".codex" / "config.toml"
codex.parent.mkdir(parents=True, exist_ok=True)
marker = "# Written by t3-vps setup.sh"
if not codex.exists() or codex.read_text().startswith(marker):
    codex.write_text(f'''{marker}; delete this line to keep your own edits.
model_provider = "cliproxy"
model = "gpt-5.5"

[model_providers.cliproxy]
name = "CLIProxyAPI"
base_url = "http://127.0.0.1:{port}/v1"
wire_api = "responses"
experimental_bearer_token = "{key}"
''')
    codex.chmod(0o600)
PY

# ---------------------------------------------------------------------------------------------
step "Machine notes for the agents"
NOTES='<!-- t3-vps:begin -->
# This machine: headless Linux VPS (t3-vps)

You run inside T3 Code on a Linux VPS with no screen. The user controls it from their MacBook over Tailscale.

- Code lives in `~/Code`. There is no macOS here: no Xcode, simulators, AirDrop, Desktop or Downloads.
- You have no sudo. When something needs root (apt packages, system services), give the user the exact
  command to run as the admin user, and stop.
- Claude Code and Codex reach the subscriptions through a local proxy at `127.0.0.1:8317`. Never print,
  copy or send its key, and do not try to read `/var/lib/cliproxy`.
- The browser for previews and screenshots is T3 Code'"'"'s own headless Chrome.
<!-- t3-vps:end -->'
for file in "$AGENT_HOME/.claude/CLAUDE.md" "$AGENT_HOME/.codex/AGENTS.md"; do
  runuser -u "$AGENT_USER" -- env NOTES="$NOTES" FILE="$file" python3 - <<'PY'
import os, pathlib, re
path = pathlib.Path(os.environ["FILE"])
path.parent.mkdir(parents=True, exist_ok=True)
text = path.read_text() if path.exists() else ""
text = re.sub(r"<!-- t3-vps:begin -->.*?<!-- t3-vps:end -->\n*", "", text, flags=re.S).strip()
path.write_text(os.environ["NOTES"] + "\n" + ("\n" + text + "\n" if text else ""))
PY
done

# ---------------------------------------------------------------------------------------------
step "T3 Code"
as_agent 'test -x ~/.local/bin/t3 || curl -fsSL https://t3.codes/install.sh | sh'
# Lets T3's headless Chrome use its sandbox (AppArmor) and installs the libraries and fonts it needs.
"$AGENT_HOME/.local/bin/t3" browser setup
as_agent 't3 service install'

RUNTIME="$AGENT_HOME/.t3/userdata/server-runtime.json"
for _ in $(seq 60); do [[ -s "$RUNTIME" ]] && break; sleep 1; done
[[ -s "$RUNTIME" ]] || die "T3 Code did not start. Check: sudo -iu $AGENT_USER t3 service status"
T3_PORT="$(jq -r '.port // empty' "$RUNTIME")"
T3_PORT="${T3_PORT:-3773}"

PAIR_ARGS="--ttl 1h --label MacBook"
if [[ $SKIP_TAILSCALE -eq 0 ]]; then
  # Root sets up Tailscale Serve once, so the agent never needs rights to change Tailscale.
  tailscale serve --bg --https=443 "http://127.0.0.1:$T3_PORT" >/dev/null
  PAIR_ARGS="--tailscale $PAIR_ARGS"
fi

# ---------------------------------------------------------------------------------------------
step "T3 Bridge"
as_agent "npx --yes --package='$BRIDGE_SPEC' t3-bridge install"

# ---------------------------------------------------------------------------------------------
if [[ $PSTACK -eq 1 ]]; then
  step "pstack skills"
  as_agent 'if [ -d ~/.agents/pstack-t3-src/.git ]; then git -C ~/.agents/pstack-t3-src pull -q --ff-only; else git clone -q https://github.com/rizaardiyanto1412/pstack-t3 ~/.agents/pstack-t3-src; fi'
  as_agent '"$HOME"/.agents/pstack-t3-src/scripts/install.sh'
  as_agent 'mkdir -p ~/.config/systemd/user && cat > ~/.config/systemd/user/pstack-update.service <<EOF
[Unit]
Description=Update pstack skills

[Service]
Type=oneshot
ExecStart=/bin/sh -c "git -C %h/.agents/pstack-t3-src pull -q --ff-only && %h/.agents/pstack-t3-src/scripts/install.sh"
EOF
cat > ~/.config/systemd/user/pstack-update.timer <<EOF
[Unit]
Description=Update pstack skills daily

[Timer]
OnCalendar=*-*-* 09:15
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload && systemctl --user enable --now pstack-update.timer >/dev/null'
fi

# ---------------------------------------------------------------------------------------------
LOCKED=0
if [[ $SKIP_FIREWALL -eq 0 ]]; then
  if [[ $SKIP_TAILSCALE -eq 1 || -z "$TS_IP" ]]; then
    warn "No Tailscale, so SSH and the firewall stay open. Run again with Tailscale to lock them."
  elif [[ ! -s "$ADMIN_KEYS" ]]; then
    warn "$ADMIN_USER has no SSH key in $ADMIN_KEYS, so password and root login stay on. Add a key and run again."
  else
    step "SSH: keys only, no root login. Firewall: tailnet only"
    cat >/etc/ssh/sshd_config.d/10-t3-vps.conf <<'EOF'
# Written by t3-vps setup.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
    sshd -t && systemctl reload ssh
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow in on tailscale0 >/dev/null
    # WireGuard only; lets Tailscale connect directly instead of through a relay.
    ufw allow 41641/udp >/dev/null
    for rule in OpenSSH 22 22/tcp; do ufw delete allow "$rule" >/dev/null 2>&1 || true; done
    ufw --force enable >/dev/null
    LOCKED=1
  fi
fi

# ---------------------------------------------------------------------------------------------
step "Pairing link for T3 Code on your MacBook (valid 1 hour)"
# shellcheck disable=SC2086
as_agent "t3 pair $PAIR_ARGS" || warn "Pairing failed. Run later: sudo -iu $AGENT_USER t3 pair $PAIR_ARGS"

step "T3 Bridge control panel (keep it private, it works like a password)"
as_agent 'node ~/.local/share/t3-bridge/runtime/cli.cjs link' || true

HOST="${TS_NAME:-$(hostname)}"
cat <<EOF

Done.

  SSH:       ssh $ADMIN_USER@$HOST   (in Termius, set the address to $HOST)
  Agents:    sudo -iu $AGENT_USER
  Proxy:     systemctl status cliproxy   (logins in $PROXY_DIR/auth, readable only by $PROXY_USER)
  Log:       /var/log/t3-vps-setup.log

Next:
  1. In T3 Code on your MacBook: Add environment, then paste the pairing link above.
  2. Copy your subscription logins from the Mac mini: ./push-auth.sh $HOST
  3. Sign GitHub in for the agents: sudo -iu $AGENT_USER gh auth login
     (use a fine-grained token limited to the repos they work on)
EOF
if [[ $LOCKED -eq 1 ]]; then
  cat <<EOF
  4. Public SSH is now closed. Log in again over Tailscale as $ADMIN_USER before you close this session.
     Also remove port 22 from your provider's cloud firewall.
EOF
fi
