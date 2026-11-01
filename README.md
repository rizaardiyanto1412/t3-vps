# t3-vps

One command turns a fresh Ubuntu 24.04 VPS into a [T3 Code](https://github.com/pingdotgg/t3code)
host that you control from another computer over [Tailscale](https://tailscale.com).

It sets up:

- **T3 Code** as a background service, with its headless browser for previews and screenshots.
- **[T3 Bridge](https://github.com/rizaardiyanto1412/t3-bridge)**, to chat with a thread from Slack,
  Discord or Telegram.
- **Claude Code and Codex**, using your subscriptions through a local
  [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI).
- **[pstack](https://github.com/rizaardiyanto1412/pstack-t3) skills**, updated daily.
- **Security:** separate users, SSH with keys only, and a firewall that only lets your tailnet in.

## Before you start

1. In Tailscale, enable **MagicDNS** and **HTTPS certificates** (Admin → DNS).
2. Add a tag for the VPS to your tailnet policy:
   ```json
   "tagOwners": { "tag:t3-vps": ["autogroup:admin"] }
   ```
3. Create an auth key (Admin → Settings → Keys): **Pre-approved**, tag `tag:t3-vps`. Tagged
   devices never expire, so the VPS stays on your tailnet.
4. Create the VPS with Ubuntu 24.04 and your SSH key. 4 vCPU and 8 GB RAM is a good start.

## Install

This repo is private, so the download needs a GitHub token. Create a fine-grained token with
**Contents: read** on this repo only, and a short expiry. Log in to the VPS's public address once,
then run:

```sh
read -rs GH_TOKEN   # paste the token, then Enter; it is not shown or saved in history
curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/rizaardiyanto1412/t3-vps/contents/setup.sh \
  | sudo bash -s -- --tailscale-key tskey-auth-...
```

The token is only used for this download. Delete it on GitHub afterwards.

At the end it prints:

- the VPS's tailnet name, for SSH (`ssh t3admin@t3-vps`) and Termius;
- a **pairing link**: in T3 Code on your computer, choose **Add environment** and paste it;
- the **T3 Bridge control panel** link, to add bots.

Public SSH is closed when it finishes. Log in again over Tailscale before you close the first session,
and remove port 22 from your provider's cloud firewall.

| Option | |
|---|---|
| `--hostname NAME` | Name on the tailnet (default `t3-vps`) |
| `--admin-user NAME` | Your login with sudo (default: the sudo caller, or `t3admin`) |
| `--bridge SPEC` | npm spec for T3 Bridge (default `t3-bridge@latest`) |
| `--no-pstack` | Skip the pstack skills |

Running it again is safe. It updates CLIProxyAPI and pstack and keeps your logins, threads and bots.

## Move your subscription logins

From the Mac that runs CLIProxyAPI now:

```sh
./push-auth.sh t3-vps
```

It streams `~/cliproxyapi/auth` to the VPS over SSH, checks that the proxy lists models, and offers to
stop the Mac's proxy, so two proxies do not refresh the same logins.

To sign in on the VPS instead, run the proxy's login as its own user, for example:

```sh
sudo -u cliproxy cliproxyapi -config /var/lib/cliproxy/config.yaml -claude-login -no-browser
```

## How it is secured

| User | Runs | sudo |
|---|---|---|
| `t3admin` | You | Yes |
| `agent` | T3 Code, T3 Bridge, Claude Code, Codex | No |
| `cliproxy` | CLIProxyAPI only | No |

- **Subscription logins** live in `/var/lib/cliproxy/auth`, readable only by `cliproxy`. Agents reach
  the proxy at `127.0.0.1:8317` with a client key. If that key leaks, change it by deleting
  `/etc/t3-vps/proxy-key` and running setup again. The logins themselves never reach the agents.
- **The proxy** is a hardened systemd service (`cliproxy.service`) that can only write its own folder.
- **Network:** ufw denies all inbound traffic except Tailscale. SSH takes keys only and no root login.
- **T3 Code** listens on `127.0.0.1`. Tailscale Serve publishes it to your tailnet over HTTPS. Root
  configures Serve, so agents get no rights to change Tailscale.

Not covered: anyone with root on the VPS, and your VPS provider, can read everything. Keep provider
snapshots off, or keep them private, because they contain the logins.

## Useful commands

```sh
sudo -iu agent                       # become the agent user
sudo -iu agent t3 service status     # T3 Code
sudo -iu agent t3 pair --tailscale   # a new pairing link
systemctl status cliproxy            # the subscription proxy
journalctl -u cliproxy -f
```
