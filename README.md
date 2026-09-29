# VM NUT + PeaNUT pour Proxmox VE

Ce dépôt contient un installateur interactif qui crée la VM **125** sous **Debian 13**, configure son réseau statique, passe l’UPS APC en USB, puis installe **NUT Server** et **PeaNUT**.

## Installation rapide

Connectez-vous en `root` au nœud Proxmox, branchez l’UPS, puis lancez :

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Shir0o0o0o/NUTAndPeanut/main/install-nut-vm.sh)"
```

L’assistant détecte les stockages compatibles et l’UPS APC, demande la clé publique SSH et affiche un résumé avant toute création. Les mots de passe NUT sont générés automatiquement et affichés à la fin.

## Avant de commencer

1. Sur le nœud Proxmox, branchez l’UPS puis relevez son identifiant :

   ```bash
   lsusb
   ```

   Une ligne APC ressemble souvent à `ID 051d:0002`, mais utilisez les valeurs réellement affichées.

2. Préparez une clé publique SSH. L’assistant vous demandera de la coller.

3. Vérifiez qu’au moins un stockage Proxmox autorise le type de contenu **Snippets** : **Datacenter > Storage > stockage > Edit**.

## Exécution

Vous pouvez aussi télécharger le script, l’inspecter, puis l’exécuter localement :

```bash
curl -fLo install-nut-vm.sh https://raw.githubusercontent.com/Shir0o0o0o/NUTAndPeanut/main/install-nut-vm.sh
less install-nut-vm.sh
chmod +x install-nut-vm.sh
./install-nut-vm.sh
```

Le script doit être exécuté en `root` directement sur Proxmox VE. Il vérifie l’image Debian avec la somme SHA-512 publiée par Debian et demande une confirmation finale avant de créer la VM.

### Mode non interactif

Toutes les options peuvent être fournies comme variables d’environnement. Dans ce mode, `SSH_PUBLIC_KEY` est obligatoire et `ASSUME_YES=true` supprime la confirmation :

```bash
SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
VMID=125 \
VM_IP_CIDR=192.168.1.25/24 \
ASSUME_YES=true \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Shir0o0o0o/NUTAndPeanut/main/install-nut-vm.sh)"
```

## Après le déploiement

Attendez la fin de l’initialisation :

```bash
ssh nutadmin@192.168.1.25 'cloud-init status --wait'
ssh nutadmin@192.168.1.25 'sudo upsc apc@localhost'
```

Ouvrez ensuite `http://192.168.1.25:8080`. Dans PeaNUT, ajoutez un serveur NUT avec :

- hôte : `127.0.0.1` ;
- port : `3493` ;
- utilisateur : valeur de `NUT_PEANUT_USER` ;
- mot de passe : valeur de `NUT_PEANUT_PASSWORD`.

## Relance et sécurité

- Une nouvelle exécution ne supprime jamais une VM 125 existante ni son disque.
- Le script refuse de modifier une VM 125 existante si elle ne porte pas le nom attendu `nut`.
- Le fichier cloud-init contient les identifiants NUT et est créé avec le mode `0600`.
- L’utilisateur Debian n’accepte que l’authentification SSH par clé.
- Si la VM existe déjà et tourne, le script ne la redémarre pas automatiquement.
- Sur une VM déjà initialisée, cloud-init peut considérer ses étapes « une fois par instance » comme terminées. Le script met bien à jour la configuration Proxmox, mais ne force pas une réinitialisation cloud-init dans l’invité.
- Le passthrough par Vendor/Product ID suppose qu’un seul périphérique possède cette paire d’identifiants.

## Sécurité

- Le dépôt ne contient aucun mot de passe, jeton ou clé SSH personnelle.
- Ne placez jamais une clé privée dans `SSH_PUBLIC_KEY` : seule la ligne du fichier `.pub` est attendue.
- Lire un script avant de l’envoyer directement à `bash` reste la méthode la plus prudente.
- Pour une installation reproductible, utilisez à terme l’URL d’une version GitHub figée plutôt que la branche `main`.
