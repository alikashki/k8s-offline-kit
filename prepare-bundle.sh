#!/usr/bin/env bash
# prepare-bundle.sh — run ONCE on an ONLINE Debian 13 (trixie) machine, as root.
# Use a throw-away VM with the same architecture as the target nodes.
# Output: ./k8s-offline.tar.gz  (debs incl. haproxy/keepalived + local apt repo + container images
#         + cilium chart + install-node.sh + install-lb.sh + bundle.env + cluster.env)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bundle.env
source "$HERE/bundle.env"

log(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
OUT="$HERE/k8s-offline"
REPO="$OUT/repo"; IMGS="$OUT/images"; CHARTS="$OUT/charts"
rm -rf "$OUT"; mkdir -p "$REPO/partial" "$IMGS" "$CHARTS" /etc/apt/keyrings

log "1/6 Adding upstream apt repos (builder only)"
apt-get update
apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl gnupg lsb-release apt-utils

curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor --yes -o /usr/share/keyrings/helm.gpg
echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
  > /etc/apt/sources.list.d/helm-stable-debian.list
apt-get update

log "2/6 Downloading .deb files with ALL dependencies"
if [[ -n "${K8S_PKG_VERSION:-}" ]]; then
  PKGS=(containerd.io "kubelet=$K8S_PKG_VERSION" "kubeadm=$K8S_PKG_VERSION" "kubectl=$K8S_PKG_VERSION" helm haproxy keepalived)
else
  PKGS=(containerd.io kubelet kubeadm kubectl helm haproxy keepalived)
fi
# Empty dpkg status => apt believes nothing is installed => downloads the full dependency closure
: > /tmp/empty-dpkg-status
apt-get install -y --download-only --no-install-recommends \
  -o Dir::Cache::archives="$REPO" \
  -o Dir::State::status=/tmp/empty-dpkg-status \
  "${PKGS[@]}"
rm -rf "$REPO/partial" "$REPO/lock"

log "3/6 Building a local flat apt repository"
( cd "$REPO"
  apt-ftparchive packages . > Packages
  gzip -kf Packages
  apt-ftparchive release . > Release )

log "4/6 Preparing tools to discover images (containerd + kubeadm + helm)"
apt-get install -y containerd.io helm
systemctl enable --now containerd
for _ in $(seq 1 30); do ctr version >/dev/null 2>&1 && break; sleep 1; done

TMPK="$(mktemp -d)"
dpkg-deb -x "$(ls "$REPO"/kubeadm_*.deb | head -1)" "$TMPK"
KUBEADM="$TMPK/usr/bin/kubeadm"
K8S_FULL="$("$KUBEADM" version -o short)"
echo "Kubernetes version in bundle: $K8S_FULL"

mapfile -t K8S_IMAGES < <("$KUBEADM" config images list --kubernetes-version "$K8S_FULL")

helm repo add cilium https://helm.cilium.io/ >/dev/null
helm repo update >/dev/null
helm pull cilium/cilium --version "$CILIUM_VERSION" -d "$CHARTS"
mapfile -t CILIUM_IMAGES < <(
  helm template cilium "$CHARTS/cilium-${CILIUM_VERSION}.tgz" --namespace kube-system "${CILIUM_SET[@]}" \
  | sed -nE 's/^[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' | sort -u
)

ALL_IMAGES=("${K8S_IMAGES[@]}" "${CILIUM_IMAGES[@]}")
printf '%s\n' "${ALL_IMAGES[@]}" > "$OUT/images.list"
echo "Images:"; cat "$OUT/images.list"

log "5/6 Pulling + exporting images (linux/$ARCH)"
for img in "${ALL_IMAGES[@]}"; do
  ctr -n k8s.io images pull --platform "linux/$ARCH" "$img"
done
ctr -n k8s.io images export --platform "linux/$ARCH" "$IMGS/images.tar" "${ALL_IMAGES[@]}"

log "6/6 Packing"
for f in install-node.sh install-lb.sh bundle.env cluster.env; do
  [[ -f "$HERE/$f" ]] || { echo "missing $HERE/$f"; exit 1; }
  cp "$HERE/$f" "$OUT/"
done
chmod +x "$OUT"/*.sh
echo "$K8S_FULL" > "$OUT/VERSION"
( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum > SHA256SUMS )
tar -C "$HERE" -czf "$HERE/k8s-offline.tar.gz" k8s-offline
ls -lh "$HERE/k8s-offline.tar.gz"
echo "Done. Copy k8s-offline.tar.gz to EVERY node (LB, control-plane, worker), extract it (e.g. into /opt)"
echo "and run install-lb.sh (LB nodes) or install-node.sh (k8s nodes)."
