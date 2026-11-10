#!/usr/bin/env bash
# prepare-metrics-server.sh — run on an ONLINE Debian 13 machine, as root.
# Builds ./metrics-server-addon.tar.gz (Helm chart + container image) for the offline cluster.
# Independent from k8s-offline.tar.gz: no need to rebuild the main bundle.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bundle.env
source <(tr -d '\r' < "$HERE/bundle.env")
log(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
OUT="$HERE/metrics-server-addon"
rm -rf "$OUT"; mkdir -p "$OUT/chart"

log "1/4 Tools: helm and containerd (ctr)"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release
mkdir -p /etc/apt/keyrings
PKGS=()
if ! command -v ctr >/dev/null; then
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list
  PKGS+=(containerd.io)
fi
if ! command -v helm >/dev/null; then
  curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor --yes -o /usr/share/keyrings/helm.gpg
  echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" > /etc/apt/sources.list.d/helm-stable-debian.list
  PKGS+=(helm)
fi
if [[ ${#PKGS[@]} -gt 0 ]]; then apt-get update; apt-get install -y "${PKGS[@]}"; fi
systemctl enable --now containerd
for _ in $(seq 1 30); do ctr version >/dev/null 2>&1 && break; sleep 1; done

log "2/4 Pulling the Helm chart"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update >/dev/null
VER=()
if [[ -n "${METRICS_SERVER_CHART_VERSION:-}" ]]; then VER=(--version "$METRICS_SERVER_CHART_VERSION"); fi
helm pull metrics-server/metrics-server "${VER[@]}" -d "$OUT/chart"
CHART="$(ls "$OUT"/chart/metrics-server-*.tgz | head -1)"
echo "Chart: $(basename "$CHART")"

log "3/4 Discovering and pulling images (linux/$ARCH)"
mapfile -t IMAGES < <(
  helm template metrics-server "$CHART" --namespace kube-system \
  | sed -nE 's/^[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' | sort -u
)
[[ ${#IMAGES[@]} -gt 0 ]] || { echo "no images found in the chart"; exit 1; }
printf '%s\n' "${IMAGES[@]}" > "$OUT/images.list"
cat "$OUT/images.list"
for img in "${IMAGES[@]}"; do ctr -n k8s.io images pull --platform "linux/$ARCH" "$img"; done
ctr -n k8s.io images export --platform "linux/$ARCH" "$OUT/images.tar" "${IMAGES[@]}"

log "4/4 Packing"
{ basename "$CHART"; cat "$OUT/images.list"; } > "$OUT/VERSION"
tar -C "$HERE" -czf "$HERE/metrics-server-addon.tar.gz" metrics-server-addon
ls -lh "$HERE/metrics-server-addon.tar.gz"
echo "Done. Next: cd ansible && ansible-playbook metrics-server.yml"