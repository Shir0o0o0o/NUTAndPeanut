#!/usr/bin/env bash
# Installateur generique NUT + PeaNUT pour Proxmox VE.
# A executer en root sur un noeud Proxmox VE.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

log()  { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[ATTENTION]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2; exit 1; }

require_command() { command -v "$1" >/dev/null 2>&1 || die "Commande requise absente : $1"; }
is_yes() { [[ "${1,,}" =~ ^(o|oui|y|yes|1|true)$ ]]; }

prompt_default() {
  local variable=$1 label=$2 default_value=${3-} answer
  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value] : " answer </dev/tty
    printf -v "$variable" '%s' "${answer:-$default_value}"
  else
    read -r -p "$label : " answer </dev/tty
    printf -v "$variable" '%s' "$answer"
  fi
}

prompt_yes_no() {
  local variable=$1 label=$2 default_value=${3:-non} answer suffix='o/N'
  [[ "$default_value" == oui ]] && suffix='O/n'
  read -r -p "$label [$suffix] : " answer </dev/tty
  answer=${answer:-$default_value}
  if is_yes "$answer"; then printf -v "$variable" '%s' oui; else printf -v "$variable" '%s' non; fi
}

dialog_input() {
  local variable=$1 title=$2 message=$3 default_value=${4-} result
  if result=$(whiptail --title "$title" --inputbox "$message" 10 68 "$default_value" 3>&1 1>&2 2>&3); then
    printf -v "$variable" '%s' "$result"
  else
    die "Installation annulee par l'utilisateur."
  fi
}

dialog_yes_no() {
  local variable=$1 title=$2 message=$3 default_value=${4:-non} rc=0
  local -a default_button=()
  [[ "$default_value" == non ]] && default_button=(--defaultno)
  whiptail --title "$title" "${default_button[@]}" --yesno "$message" 13 72 || rc=$?
  case $rc in
    0) printf -v "$variable" '%s' oui ;;
    1) printf -v "$variable" '%s' non ;;
    *) die "Installation annulee par l'utilisateur." ;;
  esac
}

validate_ipv4() {
  local address=$1 part
  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local old_ifs=$IFS; IFS=.; read -r -a parts <<<"$address"; IFS=$old_ifs
  for part in "${parts[@]}"; do (( 10#$part <= 255 )) || return 1; done
}

validate_cidr() {
  local cidr=$1 address=${1%/*} prefix=${1#*/}
  [[ "$address" != "$cidr" && "$prefix" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
  validate_ipv4 "$address"
}

validate_token() {
  [[ "$2" =~ ^[A-Za-z0-9_.-]+$ ]] || die "$1 contient un caractere non autorise."
}

storage_has_content() {
  local content
  content=$(pvesm config "$1" 2>/dev/null | awk -F': ' '$1 == "content" {print $2}')
  [[ ",$content," == *",$2,"* ]]
}

first_storage_with_content() {
  local storage
  while read -r storage; do
    [[ -n "$storage" ]] && storage_has_content "$storage" "$1" && { printf '%s' "$storage"; return 0; }
  done < <(pvesm status 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}')
  return 1
}

choose_storage() {
  local variable=$1 wanted=$2 label=$3 current choice index storage content free state
  local -a storages=()
  local -a menu=()
  current=${!variable-}
  while read -r storage; do
    [[ -n "$storage" ]] && storage_has_content "$storage" "$wanted" && storages+=("$storage")
  done < <(pvesm status 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}')

  if (( ${#storages[@]} == 0 )) && [[ "$wanted" == snippets ]]; then
    while read -r storage; do
      [[ -n "$storage" ]] || continue
      if pvesm config "$storage" 2>/dev/null | grep -q '^dir:'; then storages+=("$storage"); fi
    done < <(pvesm status 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}')
    (( ${#storages[@]} > 0 )) || die "Aucun stockage de type Directory ne peut accueillir les snippets cloud-init."
    ENABLE_SNIPPETS_STORAGE=oui
    warn "Le type de contenu Snippets n'est active sur aucun stockage. Il sera ajoute au stockage choisi apres votre confirmation finale."
  fi
  (( ${#storages[@]} > 0 )) || die "Aucun stockage actif n'accepte le contenu '$wanted'."
  if (( ${#storages[@]} == 1 )); then
    printf -v "$variable" '%s' "${storages[0]}"
    printf '  %s : %s (selection automatique)\n' "$label" "${storages[0]}"
    return
  fi

  for index in "${!storages[@]}"; do
    storage=${storages[$index]}
    free=$(pvesm status --storage "$storage" 2>/dev/null | awk 'NR > 1 {printf "%.1f GiB libres", $6/1024/1024}')
    state=OFF
    [[ "$storage" == "$current" || ( -z "$current" && $index -eq 0 ) ]] && state=ON
    menu+=("$storage" "${free:-stockage actif}" "$state")
  done
  if choice=$(whiptail --title "STOCKAGE" --radiolist "$label" 16 72 7 "${menu[@]}" 3>&1 1>&2 2>&3); then
    printf -v "$variable" '%s' "$choice"
  else
    die "Installation annulee pendant le choix du stockage."
  fi
}

prepare_ssh_key() {
  local candidate key_path=/root/.ssh/nut-peanut_ed25519
  [[ -n "$SSH_PUBLIC_KEY" ]] && return
  for candidate in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub "$key_path.pub"; do
    if [[ -s "$candidate" ]]; then
      SSH_PUBLIC_KEY=$(<"$candidate")
      SSH_KEY_SOURCE=$candidate
      return
    fi
  done
  install -d -m 0700 /root/.ssh
  ssh-keygen -q -t ed25519 -N '' -C 'nut-peanut-proxmox' -f "$key_path"
  SSH_PUBLIC_KEY=$(<"$key_path.pub")
  SSH_KEY_SOURCE=$key_path
}

next_free_vmid() {
  local candidate
  candidate=$(pvesh get /cluster/nextid --output-format json 2>/dev/null | tr -dc '0-9')
  [[ "$candidate" =~ ^[1-9][0-9]{2,8}$ ]] || die "Impossible d'obtenir le prochain VMID libre."
  printf '%s' "$candidate"
}

guest_id_is_free() {
  ! qm status "$1" >/dev/null 2>&1 && ! pct status "$1" >/dev/null 2>&1
}

detect_apc_usb_ids() {
  lsusb | awk 'tolower($0) ~ /id 051d:[0-9a-f]{4}/ {print tolower($6)}' | sort -u
}

encode_file() { base64 -w 0 "$1"; }

on_error() {
  local code=$?
  printf '\n\033[1;31m[ERREUR]\033[0m Echec ligne %s (code %s). Aucun invite existant n a ete supprime.\n' "${BASH_LINENO[0]}" "$code" >&2
  exit "$code"
}
trap on_error ERR

[[ $EUID -eq 0 ]] || die "Executez ce script en root sur Proxmox."
for cmd in qm pct pvesm pvesh curl sha512sum lsusb awk grep sed base64 openssl ip ssh-keygen whiptail; do require_command "$cmd"; done
[[ -r /etc/pve/.version ]] || die "Ce systeme ne semble pas etre un noeud Proxmox VE."
[[ -r /dev/tty && -w /dev/tty ]] || die "Cet installateur doit etre lance depuis un terminal interactif."

VMID=$(next_free_vmid)
VM_NAME=${VM_NAME:-nut-peanut}
VM_STORAGE=${VM_STORAGE:-$(first_storage_with_content images || true)}
SNIPPET_STORAGE=${SNIPPET_STORAGE:-$(first_storage_with_content snippets || true)}
ENABLE_SNIPPETS_STORAGE=non
BRIDGE=${BRIDGE:-vmbr0}
VLAN_TAG=${VLAN_TAG:-}
VM_CORES=${VM_CORES:-1}
VM_MEMORY_MB=${VM_MEMORY_MB:-1024}
VM_DISK_SIZE=${VM_DISK_SIZE:-8G}
NETWORK_MODE=${NETWORK_MODE:-dhcp}
VM_IP_CIDR=${VM_IP_CIDR:-}
VM_GATEWAY=${VM_GATEWAY:-}
VM_DNS=${VM_DNS:-}
VM_USER=${VM_USER:-nutadmin}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
SSH_KEY_SOURCE='fournie par variable'
TIMEZONE=${TIMEZONE:-Europe/Paris}
UPS_NAME=${UPS_NAME:-apc}
PEANUT_PORT=${PEANUT_PORT:-8080}
PEANUT_IMAGE=${PEANUT_IMAGE:-brandawg93/peanut:latest}
INSTALL_PVE_NUT_CLIENT=${INSTALL_PVE_NUT_CLIENT:-non}
NUT_SERVER_ADDRESS=${NUT_SERVER_ADDRESS:-}
DEBIAN_IMAGE_URL=https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
DEBIAN_SHA512_URL=https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS
IMAGE_CACHE_DIR=${IMAGE_CACHE_DIR:-/var/lib/vz/template/qcow2}

mapfile -t APC_USB_IDS < <(detect_apc_usb_ids)
if (( ${#APC_USB_IDS[@]} == 1 )); then
  USB_ID=${USB_ID:-${APC_USB_IDS[0]}}
else
  USB_ID=${USB_ID:-051d:0003}
fi

clear 2>/dev/null || true
printf '\n============================================================\n'
printf '             NUT + PeaNUT - Proxmox VE\n'
printf '============================================================\n\n'

MODE_RC=0
whiptail --title "NUT + PeaNUT" --yes-button "Par defaut" --no-button "Avances" --yesno \
  "Utiliser les parametres par defaut ?\n\nVMID : prochain libre ($VMID)\nCPU : 1 coeur\nRAM : 1024 Mo\nDisque : 8 Go\nReseau : DHCP sur vmbr0\nVLAN : aucun\nClient NUT Proxmox : non\n\nChoisissez Avances pour personnaliser ces valeurs." \
  20 72 || MODE_RC=$?
case $MODE_RC in
  0) SETTINGS_MODE=default ;;
  1) SETTINGS_MODE=advanced ;;
  *) die "Installation annulee par l'utilisateur." ;;
esac

if [[ "$SETTINGS_MODE" == advanced ]]; then
  dialog_input VM_NAME "NOM DE LA VM" "Nom affiche dans Proxmox" "$VM_NAME"
  dialog_input VM_CORES "PROCESSEURS" "Nombre de coeurs virtuels" "$VM_CORES"
  dialog_input VM_MEMORY_MB "MEMOIRE" "Memoire en Mo" "$VM_MEMORY_MB"
  dialog_input VM_DISK_SIZE "DISQUE" "Taille du disque, par exemple 8G ou 20G" "$VM_DISK_SIZE"
fi

choose_storage VM_STORAGE images "Choisissez le stockage du disque de la VM"
choose_storage SNIPPET_STORAGE snippets "Choisissez le stockage de la configuration cloud-init"

if [[ "$SETTINGS_MODE" == advanced ]]; then
  dialog_input BRIDGE "BRIDGE RESEAU" "Bridge Proxmox utilise par la VM" "$BRIDGE"
  dialog_input VLAN_TAG "VLAN" "Numero du VLAN (laisser vide pour aucun VLAN)" "$VLAN_TAG"
  if NETWORK_CHOICE=$(whiptail --title "RESEAU" --radiolist "Choisissez le mode reseau" 12 68 2 \
    dhcp "Adresse attribuee par votre routeur (recommande pour un premier test)" ON \
    statique "Adresse IP saisie manuellement" OFF 3>&1 1>&2 2>&3); then
    NETWORK_MODE=$NETWORK_CHOICE
  else
    die "Installation annulee pendant le choix du reseau."
  fi
  if [[ "$NETWORK_MODE" == statique ]]; then
    while ! validate_cidr "$VM_IP_CIDR"; do dialog_input VM_IP_CIDR "ADRESSE IP" "Adresse IPv4 avec prefixe CIDR, par exemple 192.168.1.50/24" "$VM_IP_CIDR"; done
    while ! validate_ipv4 "$VM_GATEWAY"; do dialog_input VM_GATEWAY "PASSERELLE" "Adresse IPv4 de votre routeur" "$VM_GATEWAY"; done
    while ! validate_ipv4 "$VM_DNS"; do dialog_input VM_DNS "SERVEUR DNS" "Adresse IPv4 du serveur DNS" "${VM_DNS:-$VM_GATEWAY}"; done
    NUT_SERVER_ADDRESS=${VM_IP_CIDR%/*}
  fi
  dialog_input TIMEZONE "FUSEAU HORAIRE" "Fuseau horaire de la VM" "$TIMEZONE"
fi

if (( ${#APC_USB_IDS[@]} == 1 )); then
  USB_ID=${APC_USB_IDS[0]}
elif (( ${#APC_USB_IDS[@]} > 1 )); then
  dialog_input USB_ID "ONDULEUR APC" "Plusieurs appareils APC ont ete detectes : ${APC_USB_IDS[*]}\nSaisissez vendor:product" "$USB_ID"
else
  dialog_input USB_ID "ONDULEUR APC INTROUVABLE" "Aucun appareil APC n'a ete detecte. Verifiez le cable avec lsusb, puis saisissez vendor:product." "$USB_ID"
fi

prepare_ssh_key

if [[ "$SETTINGS_MODE" == advanced ]]; then
  dialog_yes_no INSTALL_PVE_NUT_CLIENT "CLIENT NUT PROXMOX" \
    "Installer le client NUT sur cet hote ?\n\nOui permettra a Proxmox de s'arreter proprement lorsque l'onduleur est presque vide. Une adresse stable de la VM sera necessaire." non
fi
if [[ "$INSTALL_PVE_NUT_CLIENT" == oui && -z "$NUT_SERVER_ADDRESS" ]]; then
  dialog_input NUT_SERVER_ADDRESS "ADRESSE DU SERVEUR NUT" "Adresse IP reservee ou nom DNS stable de la VM NUT" ""
  [[ -n "$NUT_SERVER_ADDRESS" ]] || die "Une adresse stable est requise pour le client NUT Proxmox."
fi

[[ "$VMID" =~ ^[1-9][0-9]{2,8}$ ]] || die "VMID invalide."
[[ "$VM_CORES" =~ ^[1-9][0-9]*$ ]] || die "Le nombre de processeurs doit etre un entier positif."
[[ "$VM_MEMORY_MB" =~ ^[1-9][0-9]*$ ]] || die "La memoire doit etre un entier positif en Mo."
[[ "$VM_DISK_SIZE" =~ ^[1-9][0-9]*[GM]$ ]] || die "Taille de disque invalide. Exemple attendu : 8G ou 20G."
guest_id_is_free "$VMID" || die "Le VMID/CTID $VMID vient d'etre occupe. Relancez le script pour obtenir un nouvel identifiant."
[[ -n "$VM_STORAGE" && -n "$SNIPPET_STORAGE" ]] || die "Stockage compatible introuvable."
pvesm status --storage "$VM_STORAGE" >/dev/null 2>&1 || die "Stockage VM introuvable : $VM_STORAGE"
pvesm status --storage "$SNIPPET_STORAGE" >/dev/null 2>&1 || die "Stockage snippets introuvable : $SNIPPET_STORAGE"
storage_has_content "$VM_STORAGE" images || die "$VM_STORAGE n'accepte pas le contenu images."
if [[ "$ENABLE_SNIPPETS_STORAGE" != oui ]]; then
  storage_has_content "$SNIPPET_STORAGE" snippets || die "$SNIPPET_STORAGE n'accepte pas le contenu snippets."
fi
[[ -d "/sys/class/net/$BRIDGE" ]] || die "Bridge introuvable : $BRIDGE"
[[ -z "$VLAN_TAG" || "$VLAN_TAG" =~ ^([1-9]|[1-9][0-9]{1,2}|[1-3][0-9]{3}|40[0-8][0-9]|409[0-4])$ ]] || die "VLAN invalide (1 a 4094)."
[[ "$USB_ID" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$ ]] || die "Identifiant USB invalide."
USB_ID=${USB_ID,,}
USB_MATCHES=$( { lsusb -d "$USB_ID" 2>/dev/null || true; } | wc -l)
(( USB_MATCHES == 1 )) || die "Il faut exactement un peripherique USB $USB_ID ; detecte : $USB_MATCHES."
[[ "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]] ]] || die "Cle publique SSH invalide."
[[ "$PEANUT_PORT" =~ ^[0-9]+$ ]] && (( PEANUT_PORT >= 1 && PEANUT_PORT <= 65535 )) || die "Port PeaNUT invalide."
validate_token VM_USER "$VM_USER"
validate_token UPS_NAME "$UPS_NAME"
[[ "$TIMEZONE" =~ ^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$ ]] || die "Fuseau horaire invalide."

NUT_MONITOR_USER=monmaster
NUT_MONITOR_PASSWORD=$(openssl rand -hex 24)
NUT_PEANUT_USER=peanut
NUT_PEANUT_PASSWORD=$(openssl rand -hex 24)
PVE_NUT_USER=pveclient
PVE_NUT_PASSWORD=$(openssl rand -hex 24)

if [[ "$NETWORK_MODE" == statique ]]; then
  IPCONFIG="ip=$VM_IP_CIDR,gw=$VM_GATEWAY"
  NETWORK_SUMMARY="$VM_IP_CIDR (passerelle $VM_GATEWAY)"
else
  IPCONFIG='ip=dhcp'
  NETWORK_SUMMARY='DHCP'
fi
NET0="virtio,bridge=$BRIDGE"
[[ -n "$VLAN_TAG" ]] && NET0+=",tag=$VLAN_TAG"

cat <<EOF

Resume
  VMID            : $VMID (prochain identifiant libre)
  VM              : $VM_NAME, $VM_CORES vCPU, $VM_MEMORY_MB Mo, disque $VM_DISK_SIZE
  Reseau          : $NETWORK_SUMMARY, bridge $BRIDGE${VLAN_TAG:+, VLAN $VLAN_TAG}
  Stockages       : disque=$VM_STORAGE, snippets=$SNIPPET_STORAGE
  USB APC         : $USB_ID
  Fuseau horaire  : $TIMEZONE
  Client Proxmox  : $INSTALL_PVE_NUT_CLIENT${NUT_SERVER_ADDRESS:+ ($NUT_SERVER_ADDRESS)}
EOF
dialog_yes_no CONFIRM "CONFIRMATION" \
  "Creer maintenant la VM $VMID ($VM_NAME) ?\n\nCPU : $VM_CORES coeur(s)\nRAM : $VM_MEMORY_MB Mo\nDisque : $VM_DISK_SIZE sur $VM_STORAGE\nReseau : $NETWORK_SUMMARY\nUSB APC : $USB_ID\nClient NUT Proxmox : $INSTALL_PVE_NUT_CLIENT" non
[[ "$CONFIRM" == oui ]] || die "Operation annulee."

if [[ "$ENABLE_SNIPPETS_STORAGE" == oui ]]; then
  CURRENT_CONTENT=$(pvesm config "$SNIPPET_STORAGE" | awk -F': ' '$1 == "content" {print $2}')
  [[ -n "$CURRENT_CONTENT" ]] || die "Impossible de lire les types de contenu de $SNIPPET_STORAGE."
  pvesm set "$SNIPPET_STORAGE" --content "${CURRENT_CONTENT},snippets"
  log "Le contenu Snippets a ete active sur $SNIPPET_STORAGE."
fi

log "Telechargement et verification de l'image Debian 13 officielle."
mkdir -p "$IMAGE_CACHE_DIR"
IMAGE_PATH="$IMAGE_CACHE_DIR/debian-13-genericcloud-amd64.qcow2"
SUMS_PATH="$IMAGE_CACHE_DIR/SHA512SUMS.trixie"
curl --fail --location --retry 3 --connect-timeout 15 -o "$SUMS_PATH.tmp" "$DEBIAN_SHA512_URL"
mv -f "$SUMS_PATH.tmp" "$SUMS_PATH"
EXPECTED_SHA512=$(awk '$2 == "debian-13-genericcloud-amd64.qcow2" || $2 == "./debian-13-genericcloud-amd64.qcow2" {print $1; exit}' "$SUMS_PATH")
[[ "$EXPECTED_SHA512" =~ ^[0-9a-fA-F]{128}$ ]] || die "Somme SHA-512 introuvable."
if [[ ! -f "$IMAGE_PATH" ]] || ! printf '%s  %s\n' "$EXPECTED_SHA512" "$IMAGE_PATH" | sha512sum --check --status; then
  curl --fail --location --retry 3 --connect-timeout 15 -o "$IMAGE_PATH.tmp" "$DEBIAN_IMAGE_URL"
  printf '%s  %s\n' "$EXPECTED_SHA512" "$IMAGE_PATH.tmp" | sha512sum --check --status || die "Somme SHA-512 incorrecte."
  mv -f "$IMAGE_PATH.tmp" "$IMAGE_PATH"
fi

WORK_DIR=$(mktemp -d -p /tmp "nut-vm-${VMID}.XXXXXX")
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

cat >"$WORK_DIR/nut.conf" <<EOF
MODE=netserver
EOF
cat >"$WORK_DIR/ups.conf" <<EOF
[$UPS_NAME]
    driver = usbhid-ups
    port = auto
    desc = "APC UPS USB"
EOF
cat >"$WORK_DIR/upsd.conf" <<EOF
LISTEN 0.0.0.0 3493
EOF
cat >"$WORK_DIR/upsd.users" <<EOF
[$NUT_MONITOR_USER]
    password = $NUT_MONITOR_PASSWORD
    upsmon primary
[$NUT_PEANUT_USER]
    password = $NUT_PEANUT_PASSWORD
    upsmon secondary
[$PVE_NUT_USER]
    password = $PVE_NUT_PASSWORD
    upsmon secondary
EOF
cat >"$WORK_DIR/upsmon.conf" <<EOF
MONITOR $UPS_NAME@localhost 1 $NUT_MONITOR_USER $NUT_MONITOR_PASSWORD primary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POWERDOWNFLAG /etc/killpower
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
FINALDELAY 5
EOF

cat >"$WORK_DIR/install-guest.sh" <<'GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nut nut-server nut-client docker.io qemu-guest-agent ca-certificates sudo
systemctl enable --now qemu-guest-agent docker
install -d -m 0750 -o root -g nut /etc/nut
for file in nut.conf ups.conf upsd.conf upsd.users upsmon.conf; do
  install -m 0640 -o root -g nut "/opt/bootstrap/$file" "/etc/nut/$file"
done
systemctl enable nut-server nut-monitor
systemctl restart nut-server
systemctl restart nut-monitor
install -d -m 0770 -o 1000 -g 1000 /opt/peanut/config
docker pull __PEANUT_IMAGE__
docker rm -f peanut 2>/dev/null || true
docker run -d --name peanut --restart unless-stopped --network host -v /opt/peanut/config:/config -e WEB_HOST=0.0.0.0 -e WEB_PORT=__PEANUT_PORT__ __PEANUT_IMAGE__
GUEST
sed -i -e "s|__PEANUT_IMAGE__|$PEANUT_IMAGE|g" -e "s|__PEANUT_PORT__|$PEANUT_PORT|g" "$WORK_DIR/install-guest.sh"
chmod 0700 "$WORK_DIR/install-guest.sh"

SNIPPET_VOLUME="${SNIPPET_STORAGE}:snippets/vm-${VMID}-nut-cloud-init.yml"
SNIPPET_FILE=$(pvesm path "$SNIPPET_VOLUME" 2>/dev/null) || die "Impossible de determiner le chemin du snippet."
mkdir -p "$(dirname "$SNIPPET_FILE")"
SSH_PUBLIC_KEY_YAML=${SSH_PUBLIC_KEY//\'/\'\'}
cat >"$SNIPPET_FILE.tmp" <<EOF
#cloud-config
hostname: $VM_NAME
manage_etc_hosts: true
timezone: $TIMEZONE
users:
  - default
  - name: $VM_USER
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - '$SSH_PUBLIC_KEY_YAML'
ssh_pwauth: false
disable_root: true
write_files:
  - {path: /opt/bootstrap/nut.conf, permissions: '0600', encoding: b64, content: $(encode_file "$WORK_DIR/nut.conf")}
  - {path: /opt/bootstrap/ups.conf, permissions: '0600', encoding: b64, content: $(encode_file "$WORK_DIR/ups.conf")}
  - {path: /opt/bootstrap/upsd.conf, permissions: '0600', encoding: b64, content: $(encode_file "$WORK_DIR/upsd.conf")}
  - {path: /opt/bootstrap/upsd.users, permissions: '0600', encoding: b64, content: $(encode_file "$WORK_DIR/upsd.users")}
  - {path: /opt/bootstrap/upsmon.conf, permissions: '0600', encoding: b64, content: $(encode_file "$WORK_DIR/upsmon.conf")}
  - {path: /opt/bootstrap/install-guest.sh, permissions: '0700', encoding: b64, content: $(encode_file "$WORK_DIR/install-guest.sh")}
runcmd:
  - [/opt/bootstrap/install-guest.sh]
EOF
install -m 0600 "$SNIPPET_FILE.tmp" "$SNIPPET_FILE"
rm -f "$SNIPPET_FILE.tmp"

# Protection anti-course : aucun qm set/importdisk n'est execute avant cette verification.
guest_id_is_free "$VMID" || die "Le VMID/CTID $VMID a ete pris pendant la preparation. Aucun invite existant ne sera modifie."

log "Creation de la nouvelle VM $VMID."
qm create "$VMID" --name "$VM_NAME" --ostype l26 --machine q35 --cpu host --cores "$VM_CORES" --memory "$VM_MEMORY_MB" --balloon 0 --scsihw virtio-scsi-single --net0 "$NET0" --agent 'enabled=1,fstrim_cloned_disks=1' --serial0 socket --vga serial0 --onboot 1 --startup 'order=1,up=60'
qm importdisk "$VMID" "$IMAGE_PATH" "$VM_STORAGE"
IMPORTED_VOLUME=$(qm config "$VMID" | awk -F': ' '/^unused[0-9]+:/ {print $2; exit}' | cut -d, -f1)
[[ -n "$IMPORTED_VOLUME" ]] || die "Volume importe introuvable. La VM $VMID est la seule ressource nouvellement creee."
qm set "$VMID" --scsi0 "${IMPORTED_VOLUME},discard=on,ssd=1"
qm disk resize "$VMID" scsi0 "$VM_DISK_SIZE"
qm set "$VMID" --ide2 "${VM_STORAGE}:cloudinit"
printf '%s\n' "$SSH_PUBLIC_KEY" >"$WORK_DIR/ssh.pub"
QM_NETWORK_ARGS=(--ipconfig0 "$IPCONFIG")
[[ "$NETWORK_MODE" == statique ]] && QM_NETWORK_ARGS+=(--nameserver "$VM_DNS")
qm set "$VMID" --ciuser "$VM_USER" --sshkeys "$WORK_DIR/ssh.pub" --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "$SNIPPET_FILE")" --usb0 "host=$USB_ID" --boot 'order=scsi0' "${QM_NETWORK_ARGS[@]}"
qm cloudinit update "$VMID"
qm start "$VMID"

if [[ "$INSTALL_PVE_NUT_CLIENT" == oui ]]; then
  log "Installation du client NUT sur l'hote Proxmox."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y nut-client
  cp -a /etc/nut/nut.conf "/etc/nut/nut.conf.pre-nutandpeanut.$(date +%Y%m%d%H%M%S)"
  cp -a /etc/nut/upsmon.conf "/etc/nut/upsmon.conf.pre-nutandpeanut.$(date +%Y%m%d%H%M%S)"
  printf 'MODE=netclient\n' >/etc/nut/nut.conf
  cat >/etc/nut/upsmon.conf <<EOF
MONITOR $UPS_NAME@$NUT_SERVER_ADDRESS 1 $PVE_NUT_USER $PVE_NUT_PASSWORD secondary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 30
POWERDOWNFLAG /etc/killpower
FINALDELAY 5
EOF
  chmod 0640 /etc/nut/upsmon.conf
  systemctl enable nut-monitor
  warn "Le client NUT est configure. Demarrez-le apres la fin de cloud-init avec : systemctl restart nut-monitor"
fi

cat <<EOF

Installation lancee avec succes.
  VMID       : $VMID
  VM         : $VM_NAME
  Reseau     : $NETWORK_SUMMARY
  USB        : $USB_ID
  PeaNUT     : port $PEANUT_PORT (ouvrez l'adresse de la VM dans un navigateur)

Identifiants NUT a conserver dans un gestionnaire de mots de passe :
  PeaNUT     : $NUT_PEANUT_USER / $NUT_PEANUT_PASSWORD
  Proxmox    : $PVE_NUT_USER / $PVE_NUT_PASSWORD

Attendez la fin de cloud-init dans la VM, puis testez : upsc $UPS_NAME@localhost
EOF

