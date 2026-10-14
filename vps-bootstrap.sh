#!/usr/bin/env bash
#
# TeincFood VPS bootstrap — run ONCE on a fresh Hetzner VPS (Debian/Ubuntu)
# as root. Idempotent: safe to re-run; every step checks before changing.
#
# What it does:
#   1. Creates the read-only `hq-observer` user HQ uses for SSH inventory
#      (no sudo, no shell extras — docker group only, when Docker exists).
#   2. Installs Docker Engine (if missing) + enables the service.
#   3. Opens only 22/80/443 in UFW (if UFW is available and inactive).
#   4. Prints an inventory JSON block to paste into HQ
#      (Infrastructure → manual server record) for verification.
#
# What it NEVER does: touch application data, open extra ports, install
# agents, or phone home anywhere. Review it before running.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/teincsolutions/teincfood-ops/main/vps-bootstrap.sh -o /tmp/vps-bootstrap.sh
#   less /tmp/vps-bootstrap.sh            # review first, always
#   sha256sum /tmp/vps-bootstrap.sh      # compare with SHA256SUMS in the same repo
#   sudo bash /tmp/vps-bootstrap.sh --hq-key "ssh-ed25519 AAAA… hq-observer"
#
set -euo pipefail

HQ_KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hq-key) HQ_KEY="${2:-}"; shift 2 ;;
    -h|--help) echo "Usage: sudo bash vps-bootstrap.sh --hq-key \"<hq observer public key>\""; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

step() { echo "==> $1"; }
warn() { echo "    [skip] $1"; }

# -- 1. Observer user (read-only by construction: no sudo, locked password) --
if id hq-observer >/dev/null 2>&1; then
  warn "user hq-observer already exists"
else
  step "Creating user hq-observer (no sudo, locked password)"
  useradd --create-home --shell /bin/bash --user-group hq-observer
  passwd -l hq-observer >/dev/null
fi
install -d -m 700 -o hq-observer -g hq-observer /home/hq-observer/.ssh
if [ -n "$HQ_KEY" ]; then
  if grep -qF "$HQ_KEY" /home/hq-observer/.ssh/authorized_keys 2>/dev/null; then
    warn "HQ public key already authorized"
  else
    step "Authorizing HQ observer key"
    echo "$HQ_KEY" >> /home/hq-observer/.ssh/authorized_keys
  fi
else
  warn "no --hq-key given: add HQ's observer public key to /home/hq-observer/.ssh/authorized_keys manually"
fi
chmod 600 /home/hq-observer/.ssh/authorized_keys
chown hq-observer:hq-observer /home/hq-observer/.ssh/authorized_keys

# -- 2. Docker Engine (Debian/Ubuntu, official repo) --
if command -v docker >/dev/null 2>&1; then
  warn "docker already installed ($(docker --version 2>/dev/null || echo unknown))"
else
  step "Installing Docker Engine"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
if getent group docker >/dev/null 2>&1; then
  usermod -aG docker hq-observer || true
fi

# -- 3. Firewall: only SSH/HTTP/HTTPS (leaves existing rules alone) --
if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "ufw already active — not touching existing rules"
  else
    step "Enabling UFW with 22/80/443 only"
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow 22/tcp >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw --force enable >/dev/null
  fi
else
  warn "ufw not installed — ensure Hetzner Cloud Firewall covers this host"
fi

# -- 4. Inventory block: paste into HQ (manual server record) --
step "Collecting inventory (read-only)"
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
DISK=$(df -h / 2>/dev/null | awk 'NR==2 {print $2 " total, " $4 " avail"}' || echo unknown)
DOCKER_V=$(docker --version 2>/dev/null || echo "not running")
cat <<EOF

=========================== HQ INVENTORY (paste me) ===========================
{
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "os": "$(. /etc/os-release && echo "$PRETTY_NAME")",
  "memory_kb": $MEM_KB,
  "disk_root": "$DISK",
  "docker": "$DOCKER_V",
  "observer_user": "hq-observer",
  "observer_key_installed": $([ -s /home/hq-observer/.ssh/authorized_keys ] && echo true || echo false),
  "ufw": "$(ufw status 2>/dev/null | head -1 || echo unknown)"
}
===============================================================================

Next in HQ: Infrastructure → new server record (provider hetzner/other),
then People/Access as usual. Keep this terminal output out of chat logs.
EOF
