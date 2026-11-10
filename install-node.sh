#!/usr/bin/env bash
# install-node.sh — OFFLINE Kubernetes node installer for Debian 13.
#
#   sudo ./install-node.sh base [--hostname NAME]   # all nodes: steps 1-11 of the manual procedure
#   sudo ./install-node.sh init                     # first control-plane only: kubeadm init
#   sudo ./install-node.sh cilium                   # first control-plane only: Helm install of Cilium
#   sudo ./install-node.sh join <kubeadm join ...>  # other cp / worker nodes (paste the join command)
#   sudo ./install-node.sh import-images <dir>      # any node: import <dir>/images.tar (add-ons)
#   sudo ./install-node.sh metrics-server <dir>     # first cp: install metrics-server from <dir>/chart
#   sudo ./install-node.sh alias-images            # any k8s node: make digest-pinned images visible to the CRI (idempotent)
#   sudo ./install-node.sh join-info                # on a cp: new token + new certificate key
#   sudo ./install-node.sh join-cmd [worker|control-plane]  # on a cp: prints ONLY the join arguments (for automation; cp variant expects PKI files to be copied)
set -euo pipefail

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bundle.env
source <(tr -d '\r' < "$BUNDLE/bundle.env")     # versions (fixed by the bundle)
# shellcheck source=cluster.env
source <(tr -d '\r' < "$BUNDLE/cluster.env")    # IPs / VIP / pod CIDR (edit per environment)

log(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root (sudo)"
export DEBIAN_FRONTEND=noninteractive

# apt that ONLY sees the local bundle repo (never touches the network)
apt_off(){
  apt-get -o Dir::Etc::SourceList=/etc/apt/k8s-offline.list \
          -o Dir::Etc::SourceParts=/dev/null \
          -o APT::Get::List-Cleanup=false "$@"
}
setup_offline_repo(){
  [[ -f "$BUNDLE/repo/Packages" ]] || die "bundle repo not found in $BUNDLE/repo"
  echo "deb [trusted=yes] file:$BUNDLE/repo ./" > /etc/apt/k8s-offline.list
  apt_off update
}

wait_containerd(){
  for _ in $(seq 1 30); do ctr version >/dev/null 2>&1 && return 0; sleep 1; done
  die "containerd did not come up"
}

# The CRI looks images up as "repo@sha256:..." even when a pod says "repo:tag@sha256:...".
# Images imported under the "repo:tag@sha256:..." name are therefore NOT found offline and kubelet
# tries to pull them. This prints the alias name the CRI expects (empty if not digest-pinned).
digest_alias(){
  local img="$1" left name
  [[ "$img" == *@sha256:* ]] || return 0
  left="${img%@*}"; name="$left"
  if [[ "${left##*/}" == *:* ]]; then name="${left%:*}"; fi
  echo "${name}@${img##*@}"
}

alias_digest_images(){
  local img alias list="${1:-$BUNDLE/images.list}"
  while read -r img; do
    [[ -z "$img" ]] && continue
    alias="$(digest_alias "$img")"
    [[ -z "$alias" || "$alias" == "$img" ]] && continue
    ctr -n k8s.io images tag --force "$img" "$alias" 2>/dev/null \
      || ctr -n k8s.io images tag --force --skip-reference-check "$img" "$alias"
    echo "aliased: $alias"
  done < "$list"
}

verify_images(){
  local missing=0 have img a list="${1:-$BUNDLE/images.list}"
  have="$(ctr -n k8s.io images ls -q)"
  while read -r img; do
    [[ -z "$img" ]] && continue
    grep -Fxq -- "$img" <<<"$have" || { echo "MISSING: $img"; missing=1; }
    a="$(digest_alias "$img")"
    if [[ -n "$a" ]]; then grep -Fxq -- "$a" <<<"$have" || { echo "MISSING alias: $a"; missing=1; }; fi
  done < "$list"
  [[ $missing -eq 0 ]] || die "some images are missing after import"
}

# Internal IP of THIS node, looked up in HOSTS_ENTRIES by hostname (nodes may have a NAT NIC with the
# default route plus an internal NIC; kubelet/apiserver must use the internal one).
node_ip(){
  local me entry ip name
  me="${NEW_HOSTNAME:-$(hostname -s)}"
  for entry in "${HOSTS_ENTRIES[@]}"; do
    read -r ip name _ <<<"$entry"
    if [[ "$name" == "$me" ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

base(){
  log "1/8 Hostname and /etc/hosts"
  if [[ -n "${NEW_HOSTNAME:-}" ]]; then hostnamectl set-hostname "$NEW_HOSTNAME"; fi
  sed -i '/# BEGIN k8s-cluster/,/# END k8s-cluster/d' /etc/hosts
  { echo "# BEGIN k8s-cluster"; printf '%s\n' "${HOSTS_ENTRIES[@]}"; echo "# END k8s-cluster"; } >> /etc/hosts

  log "2/8 Disable swap (now and permanently)"
  swapoff -a
  sed -ri '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab

  log "3/8 Kernel modules + sysctl"
  tee /etc/modules-load.d/containerd.conf >/dev/null <<EOF
overlay
br_netfilter
nf_conntrack
EOF
  modprobe overlay
  modprobe br_netfilter
  modprobe nf_conntrack      # kube-proxy sets net.netfilter.nf_conntrack_max; without the module it crash-loops
  [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] || die "nf_conntrack is not available in this kernel (/proc/sys/net/netfilter/nf_conntrack_max missing)"
  tee /etc/sysctl.d/kubernetes.conf >/dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system >/dev/null

  log "4/8 Installing packages from the local bundle"
  setup_offline_repo
  apt_off install -y --no-install-recommends containerd.io kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl

  log "5/8 Configuring containerd (SystemdCgroup + sandbox image)"
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
  PAUSE="$(grep -m1 '/pause:' "$BUNDLE/images.list" || true)"
  if [[ -n "$PAUSE" ]]; then
    sed -i -E "s|^([[:space:]]*sandbox(_image)?[[:space:]]*=[[:space:]]*).*|\1\"$PAUSE\"|" /etc/containerd/config.toml
  fi
  systemctl enable containerd
  systemctl restart containerd
  wait_containerd

  log "6/8 Importing container images"
  ctr -n k8s.io images import "$BUNDLE/images/images.tar"
  alias_digest_images

  log "7/8 Verifying images"
  verify_images

  log "8/8 Enabling kubelet"
  NODE_IP="$(node_ip || true)"
  if [[ -n "$NODE_IP" ]]; then
    ip -4 -o addr show | grep -q "inet ${NODE_IP}/" || die "node IP $NODE_IP (from HOSTS_ENTRIES) is not configured on this machine"
    echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet
    echo "kubelet will use node IP $NODE_IP"
  else
    echo "WARNING: $(hostname -s) not found in HOSTS_ENTRIES; kubelet keeps its default node IP"
  fi
  systemctl enable --now kubelet
  echo "Base setup finished on $(hostname)."
}

setup_kubeconfig(){
  local u="${SUDO_USER:-root}" h
  h="$(getent passwd "$u" | cut -d: -f6)"
  mkdir -p "$h/.kube"
  cp -f /etc/kubernetes/admin.conf "$h/.kube/config"
  chown -R "$(id -u "$u"):$(id -g "$u")" "$h/.kube"
}

init_cp(){
  command -v kubeadm >/dev/null || die "run 'base' first"
  log "kubeadm init (first control-plane)"
  local adv=() ip
  ip="$(node_ip || true)"
  if [[ -n "$ip" ]]; then adv=(--apiserver-advertise-address="$ip"); fi
  kubeadm init \
    --kubernetes-version "$(kubeadm version -o short)" \
    --control-plane-endpoint="$CONTROL_PLANE_ENDPOINT" \
    --upload-certs \
    --pod-network-cidr="$POD_CIDR" \
    "${adv[@]}"
  setup_kubeconfig
}

install_cilium(){
  export KUBECONFIG=/etc/kubernetes/admin.conf
  if ! command -v helm >/dev/null; then setup_offline_repo; apt_off install -y helm; fi
  log "Installing Cilium ${CILIUM_VERSION} from the local chart"
  # upgrade --install: safe to re-run after a failed/timed-out rollout
  helm upgrade --install cilium "$BUNDLE/charts/cilium-${CILIUM_VERSION}.tgz" \
    --namespace kube-system "${CILIUM_SET[@]}"
  # pods stuck in pull/crash backoff from an earlier attempt (e.g. kube-proxy before nf_conntrack was loaded): restart them
  kubectl -n kube-system get pods --no-headers 2>/dev/null | awk '/ImagePullBackOff|ErrImagePull|CrashLoopBackOff/{print $1}' \
    | xargs -r kubectl -n kube-system delete pod || true
  if ! kubectl -n kube-system rollout status daemonset/cilium --timeout=300s; then
    echo
    echo "=================== Cilium rollout FAILED - diagnostics ==================="
    kubectl get nodes -o wide || true
    echo "--- kube-system pods"
    kubectl -n kube-system get pods -o wide || true
    echo "--- cilium pod description (tail)"
    kubectl -n kube-system describe pod -l k8s-app=cilium 2>&1 | tail -45 || true
    echo "--- cilium logs (tail)"
    kubectl -n kube-system logs -l k8s-app=cilium --all-containers --prefix --tail=25 --ignore-errors 2>&1 || true
    echo "--- recent events"
    kubectl -n kube-system get events --sort-by=.lastTimestamp 2>&1 | tail -15 || true
    echo "--- cilium images known to containerd (CRI)"
    ctr -n k8s.io images ls -q 2>&1 | grep -i cilium || echo "(none)"
    exit 1
  fi
}

join_node(){
  [[ $# -gt 0 ]] || die "usage: $0 join kubeadm join <endpoint> --token ... --discovery-token-ca-cert-hash ... [--control-plane --certificate-key ...]"
  [[ "${1:-}" == kubeadm ]] && shift
  [[ "${1:-}" == join ]] && shift
  local extra=() ip
  if [[ " $* " == *" --control-plane "* ]]; then
    ip="$(node_ip || true)"
    if [[ -n "$ip" ]]; then extra=(--apiserver-advertise-address="$ip"); fi
  fi
  kubeadm join "$@" "${extra[@]}"
  if [[ -f /etc/kubernetes/admin.conf ]]; then setup_kubeconfig; fi
}

join_info(){
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl -n kube-system delete secret kubeadm-certs --ignore-not-found
  local key join
  key="$(kubeadm init phase upload-certs --upload-certs | tail -1)"
  join="$(kubeadm token create --print-join-command)"
  echo
  echo "# worker:"
  echo "sudo ./install-node.sh join ${join#kubeadm join }"
  echo "# control-plane:"
  echo "sudo ./install-node.sh join ${join#kubeadm join } --control-plane --certificate-key $key"
  echo
  kubeadm token list
}

join_cmd(){
  # Prints only the arguments for "kubeadm join". For control-plane joins NO --certificate-key is
  # used: the standalone "kubeadm init phase upload-certs" is unreliable offline, so the shared
  # CA/SA files are copied to the joining node (by the Ansible playbook) before the join.
  export KUBECONFIG=/etc/kubernetes/admin.conf
  local role="${1:-worker}" join
  join="$(kubeadm token create --print-join-command)"
  join="${join#kubeadm join }"
  if [[ "$role" == "control-plane" ]]; then
    echo "$join --control-plane"
  else
    echo "$join"
  fi
}

import_images(){
  local dir="${1:?usage: install-node.sh import-images <dir containing images.tar + images.list>}"
  [[ -f "$dir/images.tar" && -f "$dir/images.list" ]] || die "images.tar / images.list not found in $dir"
  ctr -n k8s.io images import "$dir/images.tar"
  alias_digest_images "$dir/images.list"
  verify_images "$dir/images.list"
}

install_metrics_server(){
  local dir="${1:?usage: install-node.sh metrics-server <add-on dir>}" chart
  export KUBECONFIG=/etc/kubernetes/admin.conf
  command -v helm >/dev/null || die "helm is not installed (the 'cilium' step installs it on the first control-plane)"
  chart="$(compgen -G "$dir/chart/metrics-server-*.tgz" | head -1 || true)"
  [[ -n "$chart" ]] || die "no metrics-server chart found in $dir/chart"
  local extra=()
  if declare -p METRICS_SERVER_SET >/dev/null 2>&1; then extra=("${METRICS_SERVER_SET[@]}"); fi

  log "Installing metrics-server ($(basename "$chart"))"
  helm upgrade --install metrics-server "$chart" --namespace kube-system "${extra[@]}"
  if ! kubectl -n kube-system rollout status deployment/metrics-server --timeout=300s; then
    echo "=================== metrics-server rollout FAILED - diagnostics ==================="
    kubectl -n kube-system get pods -l app.kubernetes.io/name=metrics-server -o wide || true
    kubectl -n kube-system describe pod -l app.kubernetes.io/name=metrics-server 2>&1 | tail -40 || true
    kubectl -n kube-system logs -l app.kubernetes.io/name=metrics-server --tail=30 2>&1 || true
    ctr -n k8s.io images ls -q 2>&1 | grep -i metrics-server || echo "(metrics-server image not found in containerd)"
    exit 1
  fi

  log "Waiting for the metrics API (v1beta1.metrics.k8s.io)"
  kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=180s
  local i
  for i in $(seq 1 18); do
    if kubectl top nodes 2>/dev/null; then return 0; fi
    sleep 10
  done
  die "metrics API is Available but 'kubectl top nodes' has no data: kubectl -n kube-system logs deploy/metrics-server"
}

cmd="${1:-}"; [[ $# -gt 0 ]] && shift
case "$cmd" in
  base)
    NEW_HOSTNAME=""
    if [[ "${1:-}" == "--hostname" ]]; then NEW_HOSTNAME="${2:?--hostname needs a value}"; fi
    base ;;
  init)      init_cp ;;
  cilium)    install_cilium ;;
  join)      join_node "$@" ;;
  join-info) join_info ;;
  join-cmd)  join_cmd "$@" ;;
  alias-images) wait_containerd; alias_digest_images; verify_images ;;
  import-images) wait_containerd; import_images "$@" ;;
  metrics-server) install_metrics_server "$@" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac