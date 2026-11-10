#!/usr/bin/env bash
# install-lb.sh — HAProxy + keepalived for the Kubernetes API (Debian 13), fully offline.
#
#   sudo ./install-lb.sh --role master --hostname lb1
#   sudo ./install-lb.sh --role slave  --hostname lb2
#
# All data comes from cluster.env (next to this script, or --env FILE):
#   VIP, HOSTS_ENTRIES (cpN entries become haproxy backends),
#   VRRP_INTERFACE, VRRP_PREFIX, VRRP_ID, VRRP_AUTH_PASS
# Options : --role master|slave (required)  --hostname NAME  --env FILE  --repo DIR
#           --auth-pass X  --interface IF  --prefix N  --vrid N      (override cluster.env)
# Packages: if haproxy/keepalived are not installed they are installed from the bundle repo
#           next to this script (./repo) or from --repo DIR.
set -euo pipefail

die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
log(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
[[ $EUID -eq 0 ]] || die "run as root (sudo)"
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE=""; NEW_HOSTNAME=""; ENV_FILE="$SCRIPT_DIR/cluster.env"; REPO=""
O_PASS=""; O_IFACE=""; O_PREFIX=""; O_VRID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:?}"; shift 2 ;;
    --hostname) NEW_HOSTNAME="${2:?}"; shift 2 ;;
    --env) ENV_FILE="${2:?}"; shift 2 ;;
    --repo) REPO="$(cd "${2:?}" && pwd)"; shift 2 ;;
    --auth-pass) O_PASS="${2:?}"; shift 2 ;;
    --interface) O_IFACE="${2:?}"; shift 2 ;;
    --prefix) O_PREFIX="${2:?}"; shift 2 ;;
    --vrid) O_VRID="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/!p}' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[[ -f "$ENV_FILE" ]] || die "cluster.env not found: $ENV_FILE"
# shellcheck source=cluster.env
source <(tr -d '\r' < "$ENV_FILE")      # tolerate Windows line endings

# defaults + CLI overrides
IFACE="${O_IFACE:-${VRRP_INTERFACE:-eth1}}"
PREFIX="${O_PREFIX:-${VRRP_PREFIX:-24}}"
VRID="${O_VRID:-${VRRP_ID:-51}}"
AUTH_PASS="${O_PASS:-${VRRP_AUTH_PASS:-}}"
if [[ -z "$REPO" && -d "$SCRIPT_DIR/repo" ]]; then REPO="$SCRIPT_DIR/repo"; fi

# ---- validation ----
case "$ROLE" in
  master)       STATE="MASTER"; PRIORITY=255 ;;
  slave|backup) STATE="BACKUP"; PRIORITY=254 ;;
  *) die "--role must be master or slave" ;;
esac
ip_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
[[ "${VIP:-}" =~ $ip_re ]] || die "VIP missing or invalid in $ENV_FILE (value seen: [$(printf '%q' "${VIP:-}")])"
[[ "$AUTH_PASS" =~ ^[0-9A-Za-z]{1,8}$ ]] || die "VRRP_AUTH_PASS missing/invalid (1-8 alphanumerics, same on both LBs)"
[[ ${#HOSTS_ENTRIES[@]} -gt 0 ]] || die "HOSTS_ENTRIES is empty in $ENV_FILE"
ip link show "$IFACE" >/dev/null 2>&1 || die "interface $IFACE not found (VRRP_INTERFACE / --interface)"

# haproxy backends = HOSTS_ENTRIES whose first name is cpN
BACKENDS=""; CP_COUNT=0
for entry in "${HOSTS_ENTRIES[@]}"; do
  read -r ip name _ <<<"$entry"
  [[ "$ip" =~ $ip_re ]] || die "bad IP in HOSTS_ENTRIES: '$entry'"
  if [[ "$name" =~ ^cp[0-9]+$ ]]; then
    BACKENDS+="    server ${name} ${ip}:6443 check fall 3 rise 2"$'\n'
    CP_COUNT=$((CP_COUNT+1))
  fi
done
[[ $CP_COUNT -gt 0 ]] || die "no cpN entries found in HOSTS_ENTRIES"
echo "Role: $ROLE ($STATE/$PRIORITY)  VIP: $VIP/$PREFIX on $IFACE  backends: $CP_COUNT control-planes"

backup(){ if [[ -f "$1" ]]; then cp -a "$1" "$1.bak.$(date +%s)"; fi; }

# ---- 1. hostname + /etc/hosts ----
log "1/5 Hostname and /etc/hosts"
if [[ -n "$NEW_HOSTNAME" ]]; then hostnamectl set-hostname "$NEW_HOSTNAME"; fi
sed -i '/# BEGIN k8s-cluster/,/# END k8s-cluster/d' /etc/hosts
{ echo "# BEGIN k8s-cluster"; printf '%s\n' "${HOSTS_ENTRIES[@]}"; echo "# END k8s-cluster"; } >> /etc/hosts

# ---- 2. packages (offline) ----
log "2/5 Packages (haproxy, keepalived) from the local bundle"
if dpkg -s haproxy keepalived >/dev/null 2>&1; then
  echo "haproxy and keepalived already installed"
else
  [[ -n "$REPO" && -f "$REPO/Packages" ]] || die "haproxy/keepalived are not installed and no bundle repo found (expected $SCRIPT_DIR/repo or --repo DIR)"
  echo "deb [trusted=yes] file:$REPO ./" > /etc/apt/lb-offline.list
  APT=(apt-get -o Dir::Etc::SourceList=/etc/apt/lb-offline.list -o Dir::Etc::SourceParts=/dev/null -o APT::Get::List-Cleanup=false)
  "${APT[@]}" update
  "${APT[@]}" install -y --no-install-recommends haproxy keepalived
fi

# ---- 3. haproxy ----
log "3/5 HAProxy config"
backup /etc/haproxy/haproxy.cfg
{
cat <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5s
    timeout client 3h
    timeout server 3h
    option clitcpka
    option srvtcpka

frontend kubernetes-apiserver
    bind 0.0.0.0:6443
    mode tcp
    default_backend kubernetes-apiserver-backend

backend kubernetes-apiserver-backend
    mode tcp
    option tcp-check
    balance roundrobin
EOF
printf '%s' "$BACKENDS"
} > /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl enable haproxy
systemctl restart haproxy

# ---- 4. keepalived ----
log "4/5 keepalived config (role=$ROLE -> state $STATE, priority $PRIORITY)"
cat > /usr/local/bin/check_haproxy.sh <<'EOF'
#!/usr/bin/env bash
systemctl is-active --quiet haproxy
EOF
chmod 0755 /usr/local/bin/check_haproxy.sh
chown root:root /usr/local/bin/check_haproxy.sh

# keepalived >= 2.x refuses to run vrrp_script as root unless script security is on and a
# non-root user is set. The check only calls "systemctl is-active", which needs no privileges.
id keepalived_script >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin keepalived_script

mkdir -p /etc/keepalived
backup /etc/keepalived/keepalived.conf
cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
      enable_script_security
      script_user keepalived_script
}

vrrp_script keepalived_check {
      script "/usr/local/bin/check_haproxy.sh"
      interval 2
      timeout 2
      rise 3
      fall 3
}

vrrp_instance VI_1 {
        state ${STATE}
        interface ${IFACE}
        virtual_router_id ${VRID}
        priority ${PRIORITY}
        advert_int 1
        authentication {
              auth_type PASS
              auth_pass ${AUTH_PASS}
        }
        virtual_ipaddress {
              ${VIP}/${PREFIX}
        }

        track_script {
                keepalived_check
        }
}
EOF
chmod 640 /etc/keepalived/keepalived.conf
keepalived -t -f /etc/keepalived/keepalived.conf
systemctl enable keepalived
systemctl restart keepalived

# ---- 5. verify ----
log "5/5 Verification"
sleep 3
systemctl is-active haproxy keepalived
ss -ltn | grep -q ':6443 ' && echo "haproxy listening on :6443" || echo "WARNING: nothing listening on :6443"
if ip -4 addr show dev "$IFACE" | grep -q "inet ${VIP}/"; then
  echo "VIP ${VIP} is active on this node"
else
  echo "VIP ${VIP} is not on this node (expected on a slave while the master is up)"
fi