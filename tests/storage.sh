#!/usr/bin/env bash
# Simulations uniquement : aucune commande Proxmox reelle n'est executee.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source <(awk '/^trap on_error ERR/ {exit} {print}' install-nut-vm.sh)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export STORAGE_CONFIG_FILE="$tmp/storage.cfg"
cat >"$STORAGE_CONFIG_FILE" <<'CFG'
zfspool: ssdpool
        pool tank/ssd
        content images,rootdir
lvmthin: thin
        thinpool data
        vgname pve
dir: local
        path /var/lib/vz
        content iso,vztmpl,backup
dir: nut-snippets
        path /var/lib/vz
        disable 1
rbd: ceph
        content images
nfs: nas
        content snippets,images
CFG
FAIL_STATUS=0
DIR_ACTIVE=1
WITH_SNIPPETS=0
IMAGES_ACTIVE=1
pvesm() {
  [[ "$1" == status ]] || { echo 'Unexpected/invalid pvesm command' >&2; return 99; }
  (( FAIL_STATUS == 0 )) || { echo 'API failure' >&2; return 1; }
  printf 'Name Type Status Total Used Available %%\n'
  case "${2-}:${3-}" in
    --content:images)
      if (( IMAGES_ACTIVE )); then
        printf 'ssdpool zfspool active 100000 1 99999 0\nthin lvmthin active 100000 1 99999 0\nceph rbd active 100000 1 99999 0\n'
      fi
      printf 'dead zfspool inactive 0 0 0 0\noff dir disabled 0 0 0 0\n'
      ;;
    --content:snippets)
      if (( WITH_SNIPPETS )); then printf 'nas nfs active 100000 1 99999 0\n'; fi
      ;;
    *)
      printf 'ssdpool zfspool active 100000 1 99999 0\n'
      if (( DIR_ACTIVE )); then printf 'local dir active 100000 1 99999 0\n'; fi
      printf 'dead dir inactive 0 0 0 0\nnut-snippets dir disabled 0 0 0 0\n'
      ;;
  esac
  return 0
}
assert_eq() { [[ "$1" == "$2" ]] || { printf 'FAIL: expected <%s>, got <%s>\n' "$2" "$1"; exit 1; }; }
assert_eq "$(list_storages_with_content images)" $'ssdpool\nthin\nceph'
storage_has_content ssdpool images
storage_has_content thin images # contenu par defaut : delegue au filtre natif
if storage_has_content dead images; then exit 1; fi
assert_eq "$(storage_property thin type)" lvmthin
assert_eq "$(storage_property ssdpool content)" images,rootdir
assert_eq "$(storage_property local path)" /var/lib/vz
if storage_exists absent; then exit 1; fi
FAIL_STATUS=1
if list_storages_with_content images; then exit 1; fi
if storage_has_content ssdpool images; then exit 1; else assert_eq "$?" 2; fi
FAIL_STATUS=0
ENABLE_SNIPPETS_STORAGE=non CREATE_SNIPPETS_STORAGE=non SNIPPET_STORAGE=''
choose_storage SNIPPET_STORAGE snippets test
assert_eq "$SNIPPET_STORAGE" local
assert_eq "$ENABLE_SNIPPETS_STORAGE" oui
DIR_ACTIVE=0 ENABLE_SNIPPETS_STORAGE=non CREATE_SNIPPETS_STORAGE=non
choose_storage SNIPPET_STORAGE snippets test
assert_eq "$SNIPPET_STORAGE" nut-snippets-2
assert_eq "$CREATE_SNIPPETS_STORAGE" oui
WITH_SNIPPETS=1 ENABLE_SNIPPETS_STORAGE=non CREATE_SNIPPETS_STORAGE=non
choose_storage SNIPPET_STORAGE snippets test
assert_eq "$SNIPPET_STORAGE" nas
IMAGES_ACTIVE=0
if (choose_storage VM_STORAGE images test); then exit 1; fi
# Cluster inaccessible ou identifiant occupe : toujours refuser.
CLUSTER_OK=0 QM_OCCUPIED=0 PCT_OCCUPIED=0
pvesh() { (( CLUSTER_OK )); }
qm() { (( QM_OCCUPIED )); }
pct() { (( PCT_OCCUPIED )); }
if guest_id_is_free 125; then exit 1; fi
CLUSTER_OK=1 QM_OCCUPIED=1
if guest_id_is_free 125; then exit 1; fi
QM_OCCUPIED=0 PCT_OCCUPIED=1
if guest_id_is_free 125; then exit 1; fi
PCT_OCCUPIED=0
guest_id_is_free 126
# Une commande qm create en echec doit stopper avant importdisk/set/start.
# Passer le chemin comme argument plutot qu'une variable d'environnement.
rc=0
"$BASH" -c 'set -e; calls=$1; qm() { echo "$1" >>"$calls"; return 1; }; qm create 125; qm set 125 --memory 1024' sh "$tmp/qm.calls" || rc=$?
assert_eq "$rc" 1
assert_eq "$(cat "$tmp/qm.calls")" create
printf 'PASS: storage discovery, defaults, inactive/disabled, errors, snippets, VMID guards\n'
