# tailscale — the Tailscale client, installed only (joining a tailnet needs an auth key at session time)
# Sandboxes usually have no TUN device: run `tailscaled --tun=userspace-networking` and reach hosts
# through its SOCKS5 / HTTP proxy.
# shellcheck shell=bash

setup() { command -v tailscaled >/dev/null || curl -fsSL https://tailscale.com/install.sh | $SUDO sh; }

status() { command -v tailscale >/dev/null && echo "tailscale=$(ver tailscale version)" || echo "tailscale=missing"; }
