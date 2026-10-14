#!/usr/bin/env bash
# Execute le vrai bootstrap avec toutes les actions systeme remplacees.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
awk '/^cat >.*install-guest.sh.*GUEST/ {copy=1; next} copy && /^GUEST$/ {exit} copy {print}' install-nut-vm.sh >"$tmp/guest.sh"
"$BASH" -c '
  set +o posix
  set -Eeuo pipefail
  calls=$1
  apt-get() { printf "%s\n" "$*" >>"$calls/apt"; }
  systemctl() { :; }
  install() { :; }
  docker() { printf "%s\n" "$*" >>"$calls/docker"; }
  source "$calls/guest.sh"
' sh "$tmp"
grep -q 'install .*docker.io docker-cli usbutils' "$tmp/apt"
grep -q '^pull ' "$tmp/docker"
grep -q '^run -d --name peanut ' "$tmp/docker"
printf 'PASS: guest dependencies and bootstrap reach PeaNUT launch\n'
