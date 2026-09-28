#!/usr/bin/env bash
# Crée/configure une VM Debian 13 sur Proxmox VE, puis installe NUT et PeaNUT.
# À exécuter en root sur un nœud Proxmox VE (pas dans la future VM).

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ==============================================================================
# VARIABLES À ADAPTER
# ==============================================================================

VMID=125
VM_NAME="nut"
VM_STORAGE="local-lvm"       # Stockage PVE acceptant le contenu "images"
SNIPPET_STORAGE="local"      # Stockage PVE acceptant le contenu "snippets"
BRIDGE="vmbr0"

VM_CORES=1
VM_MEMORY_MB=1024
VM_DISK_SIZE="8G"
VM_IP_CIDR="192.168.1.25/24"
VM_GATEWAY="192.168.1.1"
VM_DNS="192.168.1.1"
VM_USER="nutadmin"
SSH_PUBLIC_KEY=""            # Obligatoire. Exemple : ssh-ed25519 AAAA... admin@pc

# Identifiants USB visibles avec `lsusb` sur Proxmox (4 chiffres hexadécimaux).
# Exemple APC fréquent : 051d:0002. Vérifiez impérativement votre modèle.
USB_VENDOR_ID="051d"
USB_PRODUCT_ID="0002"

# NUT : noms simples, sans espaces. Remplacez les mots de passe avant exécution.
UPS_NAME="apc"
NUT_MONITOR_USER="monmaster"
NUT_MONITOR_PASSWORD="CHANGE_ME_MONITOR_PASSWORD"
NUT_PEANUT_USER="peanut"
NUT_PEANUT_PASSWORD="CHANGE_ME_PEANUT_PASSWORD"

PEANUT_PORT=8080
PEANUT_IMAGE="brandawg93/peanut:latest"

# Image cloud officielle Debian 13 (Trixie) et somme publiée par Debian.
DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
DEBIAN_SHA512_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
IMAGE_CACHE_DIR="/var/lib/vz/template/qcow2"
START_VM=true

# ==============================================================================
# FIN DES VARIABLES
# ==============================================================================

log()  { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local code=$?
  printf '\n\033[1;31m[ERREUR]\033[0m Échec ligne %s (code %s). La VM existante n’a pas été supprimée.\n' "${BASH_LINENO[0]}" "$code" >&2
  exit "$code"
}
trap on_error ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Commande requise absente : $1"
}

validate_token() {
  local label=$1 value=$2
  [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || die "$label contient un caractère non autorisé. Utilisez lettres, chiffres, _, . ou -."
}

validate_password() {
  local label=$1 value=$2
  [[ "$value" != CHANGE_ME_* ]] || die "$label doit être remplacé en tête du script."
  (( ${#value} >= 16 )) || die "$label doit contenir au moins 16 caractères."
  [[ "$value" =~ ^[A-Za-z0-9._~!@%+=:-]+$ ]] || die "$label contient un caractère non pris en charge. Utilisez lettres, chiffres et . _ ~ ! @ % + = : -"
}

validate_ipv4() {
  local address=$1 octet
  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local old_ifs=$IFS
  IFS=.
  read -r -a octets <<<"$address"
  IFS=$old_ifs
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

storage_has_content() {
  local storage=$1 wanted=$2 content
  content=$(pvesm config "$storage" 2>/dev/null | awk -F': ' '$1 == "content" {print $2}')
  [[ ",$content," == *",$wanted,"* ]]
}

encode_file() {
  base64 -w 0 "$1"
}

[[ $EUID -eq 0 ]] || die "Exécutez ce script en root sur le nœud Proxmox."
for cmd in qm pvesm pvesh curl sha512sum lsusb awk grep sed base64 ip; do
  require_command "$cmd"
done

[[ -r /etc/pve/.version ]] || die "Ce système ne semble pas être un nœud Proxmox VE."
[[ "$VMID" =~ ^[1-9][0-9]{2,8}$ ]] || die "VMID invalide : $VMID"
[[ "$VM_CORES" =~ ^[1-9][0-9]*$ ]] || die "VM_CORES invalide."
[[ "$VM_MEMORY_MB" =~ ^[1-9][0-9]*$ ]] || die "VM_MEMORY_MB invalide."
[[ "$PEANUT_PORT" =~ ^[0-9]+$ ]] && (( PEANUT_PORT >= 1 && PEANUT_PORT <= 65535 )) || die "PEANUT_PORT invalide."
[[ "$USB_VENDOR_ID" =~ ^[0-9A-Fa-f]{4}$ && "$USB_PRODUCT_ID" =~ ^[0-9A-Fa-f]{4}$ ]] || die "Les IDs USB doivent avoir exactement 4 chiffres hexadécimaux."
[[ "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]] ]] || die "Renseignez une clé publique SSH valide dans SSH_PUBLIC_KEY."
validate_token "VM_USER" "$VM_USER"
validate_token "UPS_NAME" "$UPS_NAME"
validate_token "NUT_MONITOR_USER" "$NUT_MONITOR_USER"
validate_token "NUT_PEANUT_USER" "$NUT_PEANUT_USER"
validate_password "NUT_MONITOR_PASSWORD" "$NUT_MONITOR_PASSWORD"
validate_password "NUT_PEANUT_PASSWORD" "$NUT_PEANUT_PASSWORD"

VM_IP="${VM_IP_CIDR%/*}"
PREFIX="${VM_IP_CIDR#*/}"
[[ "$VM_IP" != "$VM_IP_CIDR" && "$PREFIX" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || die "VM_IP_CIDR invalide."
validate_ipv4 "$VM_IP" || die "Adresse IPv4 invalide dans VM_IP_CIDR."
validate_ipv4 "$VM_GATEWAY" || die "VM_GATEWAY n’est pas une adresse IPv4 valide."
validate_ipv4 "$VM_DNS" || die "VM_DNS n’est pas une adresse IPv4 valide."
ip -4 route get "$VM_GATEWAY" >/dev/null 2>&1 || warn "La passerelle $VM_GATEWAY n’est pas joignable depuis la table de routage du nœud ; vérifiez le VLAN/bridge."

pvesm status --storage "$VM_STORAGE" >/dev/null 2>&1 || die "Stockage VM introuvable : $VM_STORAGE"
pvesm status --storage "$SNIPPET_STORAGE" >/dev/null 2>&1 || die "Stockage snippets introuvable : $SNIPPET_STORAGE"
storage_has_content "$VM_STORAGE" images || die "$VM_STORAGE n’accepte pas le contenu 'images'."
storage_has_content "$SNIPPET_STORAGE" snippets || die "$SNIPPET_STORAGE n’accepte pas les snippets. Activez 'Snippets' dans Datacenter > Storage > $SNIPPET_STORAGE > Edit."
[[ -d "/sys/class/net/$BRIDGE" ]] || die "Bridge réseau introuvable : $BRIDGE"

USB_VENDOR_ID=${USB_VENDOR_ID,,}
USB_PRODUCT_ID=${USB_PRODUCT_ID,,}
USB_MATCHES=$(lsusb -d "${USB_VENDOR_ID}:${USB_PRODUCT_ID}" 2>/dev/null | wc -l)
(( USB_MATCHES > 0 )) || die "UPS USB ${USB_VENDOR_ID}:${USB_PRODUCT_ID} absent. Vérifiez avec : lsusb"
(( USB_MATCHES == 1 )) || die "Plusieurs périphériques ${USB_VENDOR_ID}:${USB_PRODUCT_ID} détectés. Utilisez un mapping USB PVE ou adaptez le script pour sélectionner le port physique."

log "Contrôles validés. Téléchargement/vérification de l’image Debian officielle."
mkdir -p "$IMAGE_CACHE_DIR"
IMAGE_PATH="$IMAGE_CACHE_DIR/debian-13-genericcloud-amd64.qcow2"
SUMS_PATH="$IMAGE_CACHE_DIR/SHA512SUMS.trixie"
curl --fail --location --retry 3 --connect-timeout 15 -o "$SUMS_PATH.tmp" "$DEBIAN_SHA512_URL"
mv -f "$SUMS_PATH.tmp" "$SUMS_PATH"
EXPECTED_SHA512=$(awk '$2 == "debian-13-genericcloud-amd64.qcow2" || $2 == "./debian-13-genericcloud-amd64.qcow2" {print $1; exit}' "$SUMS_PATH")
[[ "$EXPECTED_SHA512" =~ ^[0-9a-fA-F]{128}$ ]] || die "Somme SHA-512 de l’image introuvable dans SHA512SUMS."

if [[ -f "$IMAGE_PATH" ]] && printf '%s  %s\n' "$EXPECTED_SHA512" "$IMAGE_PATH" | sha512sum --check --status; then
  log "Image déjà présente et valide."
else
  curl --fail --location --retry 3 --connect-timeout 15 -o "$IMAGE_PATH.tmp" "$DEBIAN_IMAGE_URL"
  printf '%s  %s\n' "$EXPECTED_SHA512" "$IMAGE_PATH.tmp" | sha512sum --check --status || die "La somme SHA-512 de l’image téléchargée est incorrecte."
  mv -f "$IMAGE_PATH.tmp" "$IMAGE_PATH"
fi

WORK_DIR=$(mktemp -d -p /tmp nut-vm-125.XXXXXX)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat >"$WORK_DIR/nut.conf" <<EOF
MODE=netserver
EOF

cat >"$WORK_DIR/ups.conf" <<EOF
[${UPS_NAME}]
    driver = usbhid-ups
    port = auto
    desc = "APC UPS USB"
EOF

cat >"$WORK_DIR/upsd.conf" <<EOF
LISTEN 127.0.0.1 3493
LISTEN ${VM_IP} 3493
EOF

cat >"$WORK_DIR/upsd.users" <<EOF
[${NUT_MONITOR_USER}]
    password = ${NUT_MONITOR_PASSWORD}
    upsmon primary

[${NUT_PEANUT_USER}]
    password = ${NUT_PEANUT_PASSWORD}
    upsmon secondary
EOF

cat >"$WORK_DIR/upsmon.conf" <<EOF
MONITOR ${UPS_NAME}@localhost 1 ${NUT_MONITOR_USER} ${NUT_MONITOR_PASSWORD} primary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
NOTIFYCMD /usr/sbin/upssched
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG /etc/killpower
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
EOF

cat >"$WORK_DIR/install-nut-peanut.sh" <<'GUESTSCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends nut nut-server nut-client docker.io qemu-guest-agent ca-certificates curl
systemctl enable --now qemu-guest-agent docker

install -d -m 0750 -o root -g nut /etc/nut
install -m 0640 -o root -g nut /opt/bootstrap/nut.conf /etc/nut/nut.conf
install -m 0640 -o root -g nut /opt/bootstrap/ups.conf /etc/nut/ups.conf
install -m 0640 -o root -g nut /opt/bootstrap/upsd.conf /etc/nut/upsd.conf
install -m 0640 -o root -g nut /opt/bootstrap/upsd.users /etc/nut/upsd.users
install -m 0640 -o root -g nut /opt/bootstrap/upsmon.conf /etc/nut/upsmon.conf

systemctl enable nut-server nut-monitor
systemctl restart nut-server || true
systemctl restart nut-monitor || true

install -d -m 0755 /opt/peanut
install -d -m 0770 -o 1000 -g 1000 /opt/peanut/config

cat >/etc/systemd/system/peanut.service <<EOF
[Unit]
Description=PeaNUT web interface
Wants=network-online.target docker.service nut-server.service
After=network-online.target docker.service nut-server.service

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f peanut
ExecStartPre=/usr/bin/docker pull __PEANUT_IMAGE__
ExecStart=/usr/bin/docker run --name peanut --network host --volume /opt/peanut/config:/config --env WEB_HOST=0.0.0.0 --env WEB_PORT=__PEANUT_PORT__ __PEANUT_IMAGE__
ExecStop=/usr/bin/docker stop -t 20 peanut

[Install]
WantedBy=multi-user.target
EOF
sed -i 's|__PEANUT_IMAGE__|__PEANUT_IMAGE_VALUE__|g; s|__PEANUT_PORT__|__PEANUT_PORT_VALUE__|g' /etc/systemd/system/peanut.service
systemctl daemon-reload
systemctl enable --now peanut.service

cat >/etc/motd <<EOF
NUT + PeaNUT
- Interface PeaNUT : http://__VM_IP_VALUE__:__PEANUT_PORT_VALUE__
- Serveur NUT      : __VM_IP_VALUE__:3493
- UPS              : __UPS_NAME_VALUE__
- Test              : upsc __UPS_NAME_VALUE__@localhost
EOF

systemctl --no-pager --full status peanut.service || true
upsc '__UPS_NAME_VALUE__@localhost' || true
GUESTSCRIPT

sed -i \
  -e "s|__PEANUT_IMAGE_VALUE__|$PEANUT_IMAGE|g" \
  -e "s|__PEANUT_PORT_VALUE__|$PEANUT_PORT|g" \
  -e "s|__VM_IP_VALUE__|$VM_IP|g" \
  -e "s|__UPS_NAME_VALUE__|$UPS_NAME|g" \
  "$WORK_DIR/install-nut-peanut.sh"
chmod 0700 "$WORK_DIR/install-nut-peanut.sh"

SNIPPET_VOLUME="${SNIPPET_STORAGE}:snippets/vm-${VMID}-nut-cloud-init.yml"
SNIPPET_FILE=$(pvesm path "$SNIPPET_VOLUME" 2>/dev/null) || die "Impossible de déterminer le chemin du stockage snippets."
mkdir -p "$(dirname "$SNIPPET_FILE")"
SSH_PUBLIC_KEY_YAML=${SSH_PUBLIC_KEY//\'/\'\'}

cat >"$SNIPPET_FILE.tmp" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
timezone: Europe/Paris
users:
  - default
  - name: ${VM_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - '${SSH_PUBLIC_KEY_YAML}'
ssh_pwauth: false
disable_root: true
package_update: false
write_files:
  - path: /opt/bootstrap/nut.conf
    permissions: '0600'
    encoding: b64
    content: $(encode_file "$WORK_DIR/nut.conf")
  - path: /opt/bootstrap/ups.conf
    permissions: '0600'
    encoding: b64
    content: $(encode_file "$WORK_DIR/ups.conf")
  - path: /opt/bootstrap/upsd.conf
    permissions: '0600'
    encoding: b64
    content: $(encode_file "$WORK_DIR/upsd.conf")
  - path: /opt/bootstrap/upsd.users
    permissions: '0600'
    encoding: b64
    content: $(encode_file "$WORK_DIR/upsd.users")
  - path: /opt/bootstrap/upsmon.conf
    permissions: '0600'
    encoding: b64
    content: $(encode_file "$WORK_DIR/upsmon.conf")
  - path: /opt/bootstrap/install-nut-peanut.sh
    permissions: '0700'
    encoding: b64
    content: $(encode_file "$WORK_DIR/install-nut-peanut.sh")
runcmd:
  - [/opt/bootstrap/install-nut-peanut.sh]
final_message: "NUT et PeaNUT installés en $UPTIME secondes"
EOF
install -m 0600 "$SNIPPET_FILE.tmp" "$SNIPPET_FILE"
rm -f "$SNIPPET_FILE.tmp"

VM_EXISTS=false
if qm status "$VMID" >/dev/null 2>&1; then
  VM_EXISTS=true
  EXISTING_NAME=$(qm config "$VMID" | awk -F': ' '$1 == "name" {print $2}')
  [[ "$EXISTING_NAME" == "$VM_NAME" ]] || die "La VM $VMID existe sous le nom '$EXISTING_NAME', pas '$VM_NAME'. Refus de la modifier."
  warn "La VM $VMID existe déjà : aucun disque ne sera supprimé ni remplacé."
else
  log "Création de la VM $VMID."
  qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --machine q35 \
    --cpu host \
    --cores "$VM_CORES" \
    --memory "$VM_MEMORY_MB" \
    --balloon 0 \
    --scsihw virtio-scsi-single \
    --net0 "virtio,bridge=$BRIDGE" \
    --agent "enabled=1,fstrim_cloned_disks=1" \
    --serial0 socket \
    --vga serial0 \
    --onboot 1 \
    --startup "order=1,up=60"
fi

if ! qm config "$VMID" | grep -q '^scsi0:'; then
  log "Import du disque Debian dans $VM_STORAGE."
  if ! qm config "$VMID" | grep -q '^unused[0-9]:'; then
    qm importdisk "$VMID" "$IMAGE_PATH" "$VM_STORAGE"
  fi
  IMPORTED_VOLUME=$(qm config "$VMID" | awk -F': ' '/^unused[0-9]+:/ {print $2; exit}' | cut -d, -f1)
  [[ -n "$IMPORTED_VOLUME" ]] || die "Volume importé introuvable dans la configuration de la VM."
  qm set "$VMID" --scsi0 "${IMPORTED_VOLUME},discard=on,ssd=1"
  qm disk resize "$VMID" scsi0 "$VM_DISK_SIZE"
elif [[ "$VM_EXISTS" == true ]]; then
  warn "Le disque scsi0 existant est conservé tel quel ; sa taille n’est pas modifiée."
fi

if ! qm config "$VMID" | grep -q '^ide2:.*cloudinit'; then
  qm set "$VMID" --ide2 "${VM_STORAGE}:cloudinit"
fi

log "Application du matériel, du réseau cloud-init et du passthrough USB."
printf '%s\n' "$SSH_PUBLIC_KEY" >"$WORK_DIR/ssh.pub"
qm set "$VMID" \
  --name "$VM_NAME" \
  --cores "$VM_CORES" \
  --memory "$VM_MEMORY_MB" \
  --balloon 0 \
  --net0 "virtio,bridge=$BRIDGE" \
  --ipconfig0 "ip=$VM_IP_CIDR,gw=$VM_GATEWAY" \
  --nameserver "$VM_DNS" \
  --ciuser "$VM_USER" \
  --sshkeys "$WORK_DIR/ssh.pub" \
  --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "$SNIPPET_FILE")" \
  --usb0 "host=${USB_VENDOR_ID}:${USB_PRODUCT_ID}" \
  --boot "order=scsi0" \
  --onboot 1 \
  --agent "enabled=1,fstrim_cloned_disks=1"

qm cloudinit update "$VMID"

if [[ "$START_VM" == true ]]; then
  if [[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]]; then
    warn "La VM est déjà démarrée. Redémarrez-la si vous venez de modifier cloud-init ou l’USB."
  else
    qm start "$VMID"
    log "VM démarrée. L’installation dans Debian continue en arrière-plan pendant quelques minutes."
  fi
fi

cat <<EOF

Terminé.

  VM              : ${VMID} (${VM_NAME})
  Adresse          : ${VM_IP}
  SSH              : ssh ${VM_USER}@${VM_IP}
  PeaNUT           : http://${VM_IP}:${PEANUT_PORT}
  Serveur NUT      : ${VM_IP}:3493
  UPS NUT          : ${UPS_NAME}
  USB              : ${USB_VENDOR_ID}:${USB_PRODUCT_ID}

Après le premier démarrage :
  1. Attendez la fin de cloud-init : ssh ${VM_USER}@${VM_IP} 'cloud-init status --wait'
  2. Testez l’UPS :              ssh ${VM_USER}@${VM_IP} 'sudo upsc ${UPS_NAME}@localhost'
  3. Ouvrez PeaNUT et ajoutez le serveur 127.0.0.1:3493 avec l’utilisateur ${NUT_PEANUT_USER}.

Le mot de passe PeaNUT/NUT est celui défini dans NUT_PEANUT_PASSWORD.
EOF
