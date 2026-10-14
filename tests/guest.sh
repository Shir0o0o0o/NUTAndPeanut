#!/usr/bin/env bash
# Execute le vrai bootstrap avec toutes les actions systeme remplacees.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
awk '/^cat >.*install-guest.sh.*GUEST/ {copy=1; next} copy && /^GUEST$/ {exit} copy {print}' install-nut-vm.sh >"$tmp/guest.sh"
sed -i -e 's/__USB_ID__/051d:0003/g' -e 's/__UPS_NAME__/apc/g' -e 's/__PEANUT_IMAGE__/example\/peanut:test/g' -e 's/__PEANUT_PORT__/8080/g' "$tmp/guest.sh"
cat >"$tmp/runner.sh" <<'RUNNER'
  set +o posix
  set -Eeuo pipefail
  calls=$1
  scenario=$2
  apt-get() { printf "%s\n" "$*" >>"$calls/apt"; }
  systemctl() { :; }
  udevadm() { :; }
  sleep() { :; }
  lsusb() { [[ "$scenario" != usb-missing ]]; }
  upsc() { [[ "$scenario" != driver-failed ]]; }
  install() { :; }
  docker() {
    printf "%s\n" "$*" >>"$calls/docker"
    if [[ "$1" == inspect ]]; then
      if [[ "$scenario" == container-failed ]]; then echo false; else echo true; fi
    fi
    return 0
  }
  source "$calls/guest.sh"
RUNNER
"$BASH" "$tmp/runner.sh" "$tmp" success
grep -q 'install .*docker.io docker-cli usbutils' "$tmp/apt"
grep -q '^pull ' "$tmp/docker"
grep -q '^run -d --name peanut ' "$tmp/docker"
for scenario in usb-missing driver-failed container-failed; do
  rm -f "$tmp/docker"
  rc=0
  "$BASH" "$tmp/runner.sh" "$tmp" "$scenario" >"$tmp/output" 2>&1 || rc=$?
  [[ "$rc" != 0 ]] || { echo "FAIL: bootstrap accepted $scenario"; exit 1; }
  if [[ "$scenario" != container-failed ]] && grep -q '^run ' "$tmp/docker"; then
    echo "FAIL: PeaNUT launched despite $scenario"; exit 1
  fi
done
# Une seule identite d'image pour URL, cache et somme : pas de reutilisation du cloud.
grep -q '^DEBIAN_IMAGE_NAME=debian-13-generic-amd64.qcow2$' install-nut-vm.sh
if grep -q 'debian-13-genericcloud-amd64.qcow2' install-nut-vm.sh; then exit 1; fi
grep -Fq 'IMAGE_PATH="$IMAGE_CACHE_DIR/$DEBIAN_IMAGE_NAME"' install-nut-vm.sh
grep -Fq 'awk -v image="$DEBIAN_IMAGE_NAME"' install-nut-vm.sh
# Executer l'expression reelle sur une liste contenant aussi l'ancienne image.
sum=$(printf '%0128d' 0)
printf '%s  debian-13-genericcloud-amd64.qcow2\n%s  ./debian-13-generic-amd64.qcow2\n' bad "$sum" >"$tmp/SHA512SUMS"
line=$(sed -n '/^EXPECTED_SHA512=/p' install-nut-vm.sh)
DEBIAN_IMAGE_NAME=debian-13-generic-amd64.qcow2
SUMS_PATH="$tmp/SHA512SUMS"
eval "$line"
[[ "$EXPECTED_SHA512" == "$sum" ]] || exit 1
printf 'PASS: generic image, guest dependencies, USB/driver/container failure guards\n'
