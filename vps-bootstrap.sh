#!/usr/bin/env bash
#
# TeincFood VPS bootstrap — run ONCE on a fresh Hetzner VPS (Debian/Ubuntu)
# as root. Idempotent: safe to re-run; every step checks before changing.
#
# What it does:
#   1. Creates the read-only `hq-observer` user HQ uses for SSH inventory
#      (locked password, no sudo, NOT in the docker group — docker-group
#      membership is root-equivalent, so it is removed if present).
#   2. Installs a root cron (/etc/cron.d/hq-observer-facts, every 5 min)
#      that snapshots `docker ps` / `docker system df` / `docker --version`
#      into /var/lib/hq-observer/facts.json (root:hq-observer, 0640) for
#      the observer to read. The observer never touches the Docker socket.
#   3. Installs Docker Engine (if missing) + enables the service.
#   4. Opens only 22/80/443 in UFW (if UFW is available and inactive).
#   5. Prints an inventory JSON block to paste into HQ
#      (Infrastructure → manual server record) for verification.
#
# What it NEVER does: give the observer sudo or Docker-socket access,
# touch application data, open extra ports, install agents, or phone
# home anywhere. Review it before running.
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

# -- 1. Observer user (read-only by construction: locked password, no sudo, never in the docker group) --
if id hq-observer >/dev/null 2>&1; then
  warn "user hq-observer already exists"
else
  step "Creating user hq-observer (no sudo, locked password)"
  useradd --create-home --shell /bin/bash --user-group hq-observer
  passwd -l hq-observer >/dev/null
fi
# Fixed privilege model: docker-group membership is root-equivalent, so the
# observer must never hold it (early versions of this script granted it —
# re-running removes it).
if id -nG hq-observer 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  step "Removing hq-observer from docker group (root-equivalent)"
  deluser hq-observer docker >/dev/null 2>&1 || gpasswd --delete hq-observer docker >/dev/null 2>&1 || true
else
  warn "hq-observer not in docker group (correct)"
fi
# Belt and braces: the observer must never hold sudo.
rm -f /etc/sudoers.d/hq-observer
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

# -- 2. Server-side facts snapshot (root collects, observer only reads) --
# The observer has no Docker access, so a root cron snapshots Docker state
# into a file the observer can read. The collector never fails the cron
# (|| true guards everywhere; missing docker yields null fields, not errors).
if getent group hq-observer >/dev/null 2>&1; then
  warn "group hq-observer already exists"
else
  step "Creating group hq-observer"
  groupadd hq-observer
fi
install -d -m 0750 -o root -g hq-observer /var/lib/hq-observer
step "Installing facts collector + root cron (every 5 minutes)"
cat > /usr/local/sbin/hq-observer-facts <<'COLLECTOR_EOF'
#!/usr/bin/env bash
# Snapshot Docker state for hq-observer. Runs as root from
# /etc/cron.d/hq-observer-facts. Must never fail the cron and must never
# require docker to exist (missing docker -> null fields, not errors).
set -u
OUT_DIR="/var/lib/hq-observer"
OUT="$OUT_DIR/facts.json"
install -d -m 0750 -o root -g hq-observer "$OUT_DIR" || true
TMP="$(mktemp "$OUT_DIR/.facts.XXXXXX" 2>/dev/null || echo "/tmp/.hq-facts.$$.json")"
trap 'rm -f "$TMP"' EXIT
DOCKER_PRESENT=0
PS_RAW=""
DF_RAW=""
VER_RAW=""
if command -v docker >/dev/null 2>&1; then
  DOCKER_PRESENT=1
  PS_RAW="$(docker ps --format json 2>/dev/null || true)"
  DF_RAW="$(docker system df 2>/dev/null || true)"
  VER_RAW="$(docker --version 2>/dev/null || true)"
fi
if command -v python3 >/dev/null 2>&1; then
  DOCKER_PRESENT="$DOCKER_PRESENT" PS_RAW="$PS_RAW" DF_RAW="$DF_RAW" VER_RAW="$VER_RAW" python3 - >"$TMP" <<'PYEOF' || true
import datetime, json, os
present = os.environ.get("DOCKER_PRESENT", "0") == "1"
def parse_ps(raw):
    items = []
    for line in (raw or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            items.append(json.loads(line))
        except Exception:
            continue
    return items
ver = (os.environ.get("VER_RAW", "") or "").strip()
doc = {
    "collected_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "docker_present": present,
    "docker_ps": parse_ps(os.environ.get("PS_RAW", "")) if present else None,
    "docker_df": os.environ.get("DF_RAW", None) if present else None,
    "docker_version": (ver or None) if present else None,
}
print(json.dumps(doc, indent=2))
PYEOF
fi
if [ ! -s "$TMP" ]; then
  if [ "$DOCKER_PRESENT" = "1" ]; then
    printf '{\n  "collected_at": null,\n  "docker_present": true,\n  "docker_ps": [],\n  "docker_df": null,\n  "docker_version": null\n}\n' >"$TMP" || true
  else
    printf '{\n  "collected_at": null,\n  "docker_present": false,\n  "docker_ps": null,\n  "docker_df": null,\n  "docker_version": null\n}\n' >"$TMP" || true
  fi
fi
chmod 0640 "$TMP" || true
chown root:hq-observer "$TMP" || true
mv -f "$TMP" "$OUT" || true
trap - EXIT
COLLECTOR_EOF
chmod 0755 /usr/local/sbin/hq-observer-facts
cat > /etc/cron.d/hq-observer-facts <<'CRON_EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/5 * * * * root /usr/local/sbin/hq-observer-facts >/dev/null 2>&1 || true
CRON_EOF
chmod 0644 /etc/cron.d/hq-observer-facts
/usr/local/sbin/hq-observer-facts || true
if [ -s /var/lib/hq-observer/facts.json ]; then
  step "facts snapshot ready at /var/lib/hq-observer/facts.json"
else
  warn "facts snapshot missing — check /usr/local/sbin/hq-observer-facts output"
fi

# -- 3. Docker Engine (Debian/Ubuntu, official repo) --
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

# -- 4. Firewall: only SSH/HTTP/HTTPS (leaves existing rules alone) --
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

# -- 5. Inventory block: paste into HQ (manual server record) --
step "Collecting inventory (read-only)"
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
DISK=$(df -h / 2>/dev/null | awk 'NR==2 {print $2 " total, " $4 " avail"}' || echo unknown)
DOCKER_V=$(docker --version 2>/dev/null || echo "not running")
PUB_IP="$(curl -fsSL --max-time 8 https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)"
PUB_IP="$(printf '%s' "$PUB_IP" | tr -d '[:space:]')"
if [ -z "$PUB_IP" ]; then
  PUB_IP="unknown"
fi
cat <<EOF

=========================== HQ INVENTORY (paste me) ===========================
{
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "os": "$(. /etc/os-release && echo "$PRETTY_NAME")",
  "ssh_host": "$PUB_IP",
  "ssh_port": 22,
  "memory_kb": $MEM_KB,
  "disk_root": "$DISK",
  "docker": "$DOCKER_V",
  "observer_user": "hq-observer",
  "observer_access": "read-only (no sudo, no docker group)",
  "observer_key_installed": $([ -s /home/hq-observer/.ssh/authorized_keys ] && echo true || echo false),
  "ufw": "$(ufw status 2>/dev/null | head -1 || echo unknown)"
}
===============================================================================

Observer access is read-only: hq-observer has NO sudo and NO docker-group
access. Docker state is exposed via /var/lib/hq-observer/facts.json only
(root cron, every 5 minutes).
Next in HQ: Infrastructure → new server record (provider hetzner/other),
then People/Access as usual. Keep this terminal output out of chat logs.
EOF
