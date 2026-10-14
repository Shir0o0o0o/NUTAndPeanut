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

Le mode avancÃ© permet de modifier le nom, le CPU, la mÃ©moire, le disque, le bridge, le VLAN, le rÃ©seau et lâ€™installation facultative du client NUT sur Proxmox. Si aucun stockage nâ€™autorise encore les snippets, le script peut ajouter ce type de contenu Ã  un stockage Proxmox de type **Directory** aprÃ¨s la confirmation finale.

La liste des stockages compatibles est obtenue avec le filtre natif Proxmox `pvesm status --content images` ou `--content snippets`, comme dans les Community Scripts. Cela fonctionne avec les stockages Directory, LVM, LVM-thin, ZFS, Ceph et les autres types pris en charge par Proxmox.

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

