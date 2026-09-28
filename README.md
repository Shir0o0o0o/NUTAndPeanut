# VM NUT + PeaNUT pour Proxmox VE

Ce dossier contient un script qui crée la VM **125** sous **Debian 13**, configure son réseau statique, passe l’UPS APC en USB, puis installe **NUT Server** et **PeaNUT**.

## Avant de commencer

1. Sur le nœud Proxmox, branchez l’UPS puis relevez son identifiant :

   ```bash
   lsusb
   ```

   Une ligne APC ressemble souvent à `ID 051d:0002`, mais utilisez les valeurs réellement affichées.

2. Ouvrez `install-nut-vm.sh` et adaptez au minimum :

   - `VM_STORAGE` et `SNIPPET_STORAGE` ;
   - `SSH_PUBLIC_KEY` ;
   - `USB_VENDOR_ID` et `USB_PRODUCT_ID` ;
   - les deux mots de passe NUT marqués `CHANGE_ME` ;
   - bridge, IP, passerelle et DNS si nécessaire.

3. Dans l’interface Proxmox, vérifiez que le stockage choisi pour `SNIPPET_STORAGE` autorise le type de contenu **Snippets** : **Datacenter > Storage > stockage > Edit**.

## Exécution

Copiez le script sur le nœud Proxmox, puis lancez :

```bash
chmod +x install-nut-vm.sh
./install-nut-vm.sh
```

Le script doit être exécuté en `root` directement sur Proxmox VE. Il vérifie l’image Debian avec la somme SHA-512 publiée par Debian.

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

## Hébergement GitHub facultatif

Créez un dépôt privé, par exemple `proxmox-nut-vm`, contenant :

```text
proxmox-nut-vm/
├── install-nut-vm.sh
├── README.md
├── LICENSE
└── .gitignore
```

Ne publiez jamais vos mots de passe ou votre clé privée. Pour un dépôt partagé, laissez les valeurs `CHANGE_ME` dans le script et effectuez vos personnalisations dans une copie locale non suivie par Git. Un dépôt GitHub facilite le téléchargement et les mises à jour, mais n’est pas nécessaire : le script fonctionne seul.
