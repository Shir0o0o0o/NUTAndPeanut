# NUT + PeaNUT pour Proxmox VE

Cet installateur interactif crÃ©e une **nouvelle VM Debian 13** sur Proxmox VE, transmet un onduleur APC en USB, puis installe **NUT Server** et **PeaNUT**. Il peut aussi configurer, avec votre accord, le client NUT sur lâ€™hÃ´te Proxmox afin de permettre son arrÃªt propre.

Le script ne contient ni VMID ni adresse IP imposÃ©s. Il demande les paramÃ¨tres propres Ã  chaque installation.

## Fonctions principales

- rÃ©cupÃ©ration automatique du prochain VMID libre avec `pvesh get /cluster/nextid` ;
- double contrÃ´le du VMID/CTID avant la crÃ©ation, sans modification dâ€™une VM ou dâ€™un conteneur existant ;
- choix entre DHCP et IPv4 statique ;
- bridge, VLAN facultatif, DNS, passerelle, stockage et fuseau horaire configurables ;
- dÃ©tection automatique des pÃ©riphÃ©riques USB APC (`051d:xxxx`) et confirmation de lâ€™identifiant ;
- installation de NUT Server, NUT Monitor, Docker et PeaNUT dans la VM ;
- client NUT de lâ€™hÃ´te Proxmox entiÃ¨rement facultatif ;
- mots de passe NUT alÃ©atoires, affichÃ©s uniquement Ã  la fin de lâ€™installation ;
- vÃ©rification SHA-512 de lâ€™image cloud Debian officielle.

## PrÃ©requis

- Proxmox VE avec accÃ¨s `root` ;
- un stockage acceptant les images de VM ;
- un stockage acceptant le contenu **Snippets** ;
- une clÃ© publique SSH ;
- lâ€™onduleur APC branchÃ© en USB et visible avec `lsusb` ;
- un accÃ¨s Internet depuis le nÅ“ud pour tÃ©lÃ©charger Debian et les paquets.

Pour activer les snippets : **Datacenter â†’ Storage â†’ votre stockage â†’ Edit â†’ Snippets**.

## Installation

La mÃ©thode la plus prudente consiste Ã  tÃ©lÃ©charger puis relire le script :

```bash
curl -fLo install-nut-vm.sh https://raw.githubusercontent.com/Shir0o0o0o/NUTAndPeanut/main/install-nut-vm.sh
less install-nut-vm.sh
chmod +x install-nut-vm.sh
./install-nut-vm.sh
```

Lâ€™assistant affiche un rÃ©sumÃ© et demande une confirmation avant de crÃ©er quoi que ce soit.

Lâ€™assistant reprend le fonctionnement familier des Community Scripts Proxmox : il commence par proposer **ParamÃ¨tres par dÃ©faut** ou **AvancÃ©s**, puis utilise des fenÃªtres de sÃ©lection claires. Le mode par dÃ©faut crÃ©e une VM avec 1 cÅ“ur, 1 Go de RAM, un disque de 8 Go et le DHCP sur `vmbr0`. Il ne demande que le stockage lorsquâ€™un choix est nÃ©cessaire et une confirmation finale.

Le mode avancÃ© permet de modifier le nom, le CPU, la mÃ©moire, le disque, le bridge, le VLAN, le rÃ©seau et lâ€™installation facultative du client NUT sur Proxmox. Si aucun stockage nâ€™autorise encore les snippets, le script peut ajouter ce type de contenu Ã  un stockage Proxmox de type **Directory** aprÃ¨s la confirmation finale. Si aucun stockage Directory nâ€™existe, il crÃ©e un petit stockage local `nut-snippets` dans `/var/lib/vz`, rÃ©servÃ© aux fichiers cloud-init ; le disque de la VM reste sur le stockage choisi.

La découverte et la validation utilisent la même commande native : `pvesm status --content images` ou `--content snippets`. Seules les lignes dont l'état vaut exactement `active` sont proposées. Proxmox applique les capacités et les contenus par défaut de chaque backend (Directory, ZFS, LVM, LVM-thin, Ceph, NFS, etc.). Une erreur de commande interrompt la sélection ; elle n'est jamais interprétée comme une liste vide. `pvesm config` n'existe pas et n'est plus utilisé. La lecture de `/etc/pve/storage.cfg`, section par section, sert à identifier les Directory et à conserver les contenus existants lorsqu'on ajoute les snippets. Si le contenu existant ne peut pas être lu, l'ajout est refusé.

### Téléchargement et disque VM : deux destinations indépendantes

Le choix **stockage du disque VM** détermine la destination de `qm importdisk` et du disque cloud-init. Un pool ZFS ou LVM-thin compatible `images` convient à cet usage ; il ne fournit pas nécessairement de dossier pour télécharger un fichier qcow2.

Le choix **Téléchargement Debian** demande séparément un dossier absolu **déjà existant et monté**, sur la partition dédiée au téléchargement. Le script affiche sa partition et l'espace libre, puis utilise son sous-dossier `nut-peanut-cache`. Il ne partitionne, ne formate et ne monte aucun disque. Vérifiez la partition affichée : un dossier existant peut aussi se trouver sur la racine. Le dossier proposé par défaut est `/var/lib/vz` ; il ne désigne pas automatiquement votre partition dédiée. Le cache Debian est conservé et vérifié par SHA-512 avant réutilisation.

Exemple : choisissez `/mnt/downloads` pour le téléchargement (après avoir monté la partition) et `ssdpool` pour le disque VM. Le résumé et la confirmation affichent les deux destinations. La variable `IMAGE_CACHE_DIR` préremplit le dossier proposé.

### Diagnostic du stockage `ssdpool`

Ces commandes sont en lecture seule :

```bash
pvesm status
pvesm status --content images
pvesm status --content snippets
pvesh get /storage/ssdpool --output-format json
cat /etc/pve/storage.cfg
findmnt -T /mnt/downloads
df -h /mnt/downloads
```

`ssdpool` doit apparaître avec l'état `active` dans la liste filtrée `images`. Sinon, le script l'exclut et propose les autres cibles compatibles ; s'il n'en existe aucune, il s'arrête avec un diagnostic. Vérifiez le contenu autorisé, l'activation, la disponibilité sur le nœud et le backend. Le script ne force jamais l'ajout de `images` à un backend incompatible.

### Vérifications sans Proxmox

```bash
bash -n install-nut-vm.sh
bash tests/storage.sh
```

Les simulations remplacent les commandes Proxmox : ZFS, LVM-thin avec contenu par défaut, Ceph, Directory, snippets NFS, stockages inactifs/désactivés, échec de commande, absence de cible, nom de stockage déjà pris et protections VMID/CTID. Elles ne déploient aucune VM.

Une clÃ© SSH existante du compte `root` est rÃ©utilisÃ©e automatiquement. Si aucune clÃ© nâ€™existe, une clÃ© dÃ©diÃ©e est crÃ©Ã©e sous `/root/.ssh/nut-peanut_ed25519` ; aucune saisie manuelle de clÃ© nâ€™est nÃ©cessaire.

## RÃ©seau

### DHCP

Le mode DHCP ne force aucune adresse. Une rÃ©servation DHCP est fortement recommandÃ©e, surtout si vous activez le client NUT sur Proxmox. Dans ce cas, lâ€™assistant demande lâ€™adresse IP rÃ©servÃ©e ou un nom DNS stable de la VM.

### Adresse statique

Lâ€™assistant demande lâ€™adresse avec son prÃ©fixe CIDR, la passerelle et le DNS. Exemple : `192.168.10.50/24`.

## Onduleur USB APC

Le script recherche les identifiants `051d:xxxx`. Il propose lâ€™identifiant trouvÃ©, mais vous laisse le corriger. Il refuse de continuer si aucun pÃ©riphÃ©rique ou plusieurs pÃ©riphÃ©riques possÃ¨dent finalement la paire sÃ©lectionnÃ©e.

Exemple constatÃ© sur certains modÃ¨les APC :

```text
051d:0003
```

Utilisez toujours la valeur rÃ©ellement affichÃ©e par `lsusb` sur votre hÃ´te.

## Client NUT Proxmox facultatif

Si vous choisissez de lâ€™installer, le script :

1. installe `nut-client` sur lâ€™hÃ´te ;
2. sauvegarde les fichiers NUT existants avec un suffixe horodatÃ© ;
3. configure lâ€™hÃ´te comme client secondaire du serveur NUT de la VM ;
4. laisse le redÃ©marrage du service Ã  effectuer aprÃ¨s la fin de lâ€™initialisation de la VM.

Commande Ã  lancer une fois NUT opÃ©rationnel dans la VM :

```bash
systemctl restart nut-monitor
systemctl status nut-monitor --no-pager
```

## AprÃ¨s la crÃ©ation

En DHCP, retrouvez lâ€™adresse de la VM dans votre serveur DHCP ou avec lâ€™agent invitÃ© Proxmox lorsque celui-ci est prÃªt. En statique, utilisez lâ€™adresse saisie pendant lâ€™installation.

Attendez la fin de cloud-init, puis vÃ©rifiez NUT :

```bash
ssh nutadmin@ADRESSE_DE_LA_VM 'cloud-init status --wait'
ssh nutadmin@ADRESSE_DE_LA_VM 'sudo upsc apc@localhost'
```

PeaNUT est exposÃ© sur le port `8080` par dÃ©faut. Ajoutez ensuite le serveur NUT local `127.0.0.1:3493` dans PeaNUT avec les identifiants affichÃ©s par lâ€™installateur.

## SÃ©curitÃ© et limites

- Le VMID est calculÃ© automatiquement et revÃ©rifiÃ© juste avant `qm create`.
- Si ce numÃ©ro appartient entre-temps Ã  une VM ou Ã  un conteneur, le script sâ€™arrÃªte.
- Le script ne rÃ©utilise, ne reconfigure et ne supprime jamais un invitÃ© existant.
- Le snippet cloud-init contient temporairement les identifiants NUT et est crÃ©Ã© avec des permissions restrictives.
- Seule lâ€™authentification SSH par clÃ© est activÃ©e pour lâ€™utilisateur Debian.
- Les fichiers NUT existants de lâ€™hÃ´te sont sauvegardÃ©s avant configuration du client facultatif.
- Aucun dÃ©ploiement rÃ©el ne peut Ãªtre garanti sans test sur une installation Proxmox ; relisez toujours le script avant exÃ©cution.

## Reprise Debian 13 : Docker et USB

La fin du script hote confirme le demarrage de la VM, pas la reussite de cloud-init. Debian 13 separe le moteur docker.io du client docker-cli : les deux sont maintenant installes explicitement, ainsi que usbutils pour lsusb.

Dans une VM deja creee avec l'erreur docker: command not found :

```bash
sudo apt-get update
sudo apt-get install -y docker-cli usbutils
sudo bash /opt/bootstrap/install-guest.sh
sudo docker ps --filter name=peanut
```

Cette reprise utilise le bootstrap existant et sa configuration NUT generee. Elle recree le conteneur PeaNUT en conservant /opt/peanut/config. Ne relancez pas l'installateur Proxmox. Le statut historique de cloud-init peut rester en erreur apres cette reparation manuelle : verifiez les services directement.

Si NUT signale no USB buses found, verifiez lsusb et /dev/bus/usb dans la VM, puis le peripherique et la configuration USB de la VM sur Proxmox. Le message seul ne distingue pas un probleme de passthrough d'un probleme de visibilite pour le service.

Simulation du bootstrap sans installation reelle : bash tests/guest.sh
