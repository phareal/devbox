# devbox

Scripts d'amorçage d'un poste de développement.

## `ubuntu26-devsetup.sh`

Installeur pour **Ubuntu 26.04 LTS** — bash modulaire, idempotent, relançable sans casse.

```bash
git clone https://github.com/phareal/devbox.git
cd devbox
chmod +x ubuntu26-devsetup.sh

./ubuntu26-devsetup.sh --list        # voir les modules
./ubuntu26-devsetup.sh --dry-run     # simuler
./ubuntu26-devsetup.sh               # modules par défaut
```

### Modules

| Module | Contenu |
|---|---|
| `base` | build-essential, git + git-lfs, curl, jq, python3, outils réseau/archive |
| `shell` | zsh, tmux, fzf, ripgrep, fd, bat, eza, zoxide, starship |
| `docker` | Docker Engine, CLI, Buildx, Compose v2 (dépôt officiel) + groupe `docker` |
| `lazy` | lazygit, lazydocker, dive, ctop |
| `k8s` | kubectl, helm, k9s, kubectx/kubens, kind, minikube, kustomize |
| `jetbrains` | JetBrains Toolbox, PhpStorm, PyCharm Professional |
| `apps` | VS Code (dépôt Microsoft), Postman, GitHub CLI |
| `ssh` | Agent systemd persistant, passphrases en trousseau, `~/.ssh/config`, publication de la clé publique sur GitHub |
| `langs` | Node (fnm + LTS), uv, Go, Rust, PHP + Composer |
| `wm` | Bureau i3 desktop : i3-wm, rofi, polybar (thème colorblocks), picom, dunst |
| `cuda` | Pilote NVIDIA open, CUDA Toolkit, nvidia-container-toolkit |
| `tweaks` | Limites inotify / nofile pour les IDE, défauts git |

`cuda` et `wm` sont **hors des modules par défaut** : il faut `--all`, ou `--only cuda` / `--only wm`.

### Options

```
--all               tous les modules, cuda compris
--only a,b,c        uniquement ces modules
--skip a,b,c        modules par défaut sauf ceux-ci
--list              liste les modules et sort
--dry-run           affiche les actions sans rien exécuter
-y, --yes           aucune question
-h, --help          aide
```

### Notes

- **Ne pas lancer en root.** Le script tourne en utilisateur normal et appelle `sudo` au besoin.
- **Codenames des dépôts tiers.** Docker et NVIDIA ne publient pas forcément `26.04` le jour de la sortie. Le script teste l'URL du dépôt et retombe sur la LTS précédente (`noble` / `ubuntu2404`) avec un avertissement, plutôt que d'échouer sur un 404.
- **kubectl.** La mineure du dépôt `pkgs.k8s.io` est résolue dynamiquement via `dl.k8s.io/release/stable.txt`, pas figée en dur.
- **Rate limit GitHub.** Les binaires (lazygit, k9s, kind…) passent par l'API des releases. Exporte `GITHUB_TOKEN` si tu heurtes la limite anonyme.
- **Isolation des échecs.** Un module qui casse n'arrête pas les suivants ; récapitulatif en fin d'exécution.
- **CUDA.** Installe `cuda-toolkit` et non le métapaquet `cuda`, pour éviter de tirer un pilote concurrent. Redémarrage requis ensuite.
- **Groupe docker.** Déconnexion/reconnexion (ou `newgrp docker`) nécessaire après la première exécution.

### Module `wm` — bureau i3

```bash
./ubuntu26-devsetup.sh --only wm
```

`i3-gaps` n'existe plus : les gaps sont dans i3 mainline depuis la **4.22**, le fork ayant été fusionné en amont puis archivé. Le module installe donc `i3-wm`, et pas le métapaquet `i3` — celui-ci tirerait `i3lock` en dépendance, volontairement écarté ici. **Aucun verrouillage d'écran n'est installé** ; pour en ajouter un : `sudo apt install i3lock xss-lock`.

Installés : `i3-wm`, `rofi`, `polybar`, `picom` (compositeur), `dunst` (notifications), `feh`, `maim` + `xclip` (captures), `playerctl`, `arandr`, `lxappearance`.

Configs de départ écrites **seulement si absentes**, jamais écrasées :

| Fichier | Contenu |
|---|---|
| `~/.config/i3/config` | Gaps, raccourcis vim (`hjkl`), 6 espaces, rofi sur `$mod+d`, captures, son |
| `~/.config/polybar/colorblocks/` | Thème **colorblocks** de [adi1090x/polybar-themes](https://github.com/adi1090x/polybar-themes), adapté desktop |
| `~/.config/rofi/config.rasi` | Thème sombre, mode `drun` avec icônes |
| `~/.config/picom.conf` | Ombres, fondus, coins arrondis (polybar exclu) |

Le thème polybar est cloné depuis adi1090x/polybar-themes puis **adapté à un desktop de dev Ubuntu** — il sort configuré pour un portable Arch :

- `battery` retiré de la barre (BAT1/ACAD codés en dur, sans objet sans batterie) ;
- `mpd` retiré (exige le démon MPD) ;
- `alsa` remplacé par le module `pulseaudio` du thème (PipeWire/Pulse sur Ubuntu) ;
- module réseau branché sur l'**interface réelle** (via `ip route`) : `wired-network` si elle est filaire (`en*`/`eth*`), `network` sinon ;
- scripts Arch-only écartés : `checkupdates` et `updates.sh` (pacman), `pywal.sh` (exige pywal) ;
- polices du thème installées dans `~/.local/share/fonts` (`feather.ttf` porte les icônes — sans elle, des carrés).

Restent utilisables : `launcher.sh` et `powermenu.sh` (rofi). Le lancement passe par le `launch.sh` du thème, câblé dans l'`exec_always` d'i3 ; une config i3 déjà posée par une version précédente du module est migrée automatiquement vers ce chemin, et un thème déjà installé se voit retirer le `color-switch` au passage.

`$mod` est la touche **Super**. Raccourcis principaux :

| Touches | Effet |
|---|---|
| `$mod+Return` | Terminal |
| `$mod+d` | Lanceur rofi |
| `$mod+Tab` | Bascule entre fenêtres |
| `$mod+Shift+q` | Fermer la fenêtre |
| `$mod+r` | Mode redimensionnement |
| `$mod+Shift+e` | Quitter la session |

**i3 est une session X11.** Ubuntu ouvre par défaut une session Wayland : choisis « i3 » via l'engrenage de l'écran de connexion. La config n'inclut aucune section `bar {}`, polybar remplaçant i3bar — en garder une afficherait deux barres superposées.

## `migrate-ssh-keys.sh`

Transfert de `~/.ssh` d'une machine à l'autre, **toujours chiffré**.

```bash
# Sur l'ancienne machine (macOS ou Linux)
./migrate-ssh-keys.sh --export -o ~/ssh-backup

# Transport MANUEL — clé USB, ou :
scp ~/ssh-backup.tar.gz.gpg user@nouvelle-machine:~/

# Sur la nouvelle machine
./migrate-ssh-keys.sh --import ~/ssh-backup.tar.gz.gpg
shred -u ~/ssh-backup.tar.gz.gpg
```

| Option | Effet |
|---|---|
| `--export [-o PREFIXE]` | Archive chiffrée de `~/.ssh` (défaut : `~/ssh-backup-<hôte>-<date>`) |
| `--import ARCHIVE` | Restaure dans `~/.ssh` avec les bonnes permissions |
| `--force` | À l'import, écrase les fichiers existants |
| `--passphrase-file F` | Lit la passphrase dans `F` (première ligne), quand aucun terminal n'est disponible |

Chiffrement : `gpg` s'il est présent, sinon `openssl` (AES-256, PBKDF2 600 000 itérations). L'extension indique l'outil utilisé (`.gpg` / `.enc`) ; les archives `.age` sont acceptées à l'import. **Si aucun des deux n'est disponible, le script refuse d'écrire** plutôt que de produire une archive en clair.

La passphrase est lue par le script lui-même et transmise aux outils par descripteur de fichier — jamais en argument de ligne de commande, où elle serait visible dans la table des processus. `gpg` tourne en `--pinentry-mode loopback` : il n'a donc pas besoin d'un tty, et fonctionne dans un shell non interactif, un script ou un CI. Sans terminal du tout, utilise `--passphrase-file` ou `SSH_MIGRATE_PASSPHRASE`.

Après chiffrement, l'archive est **rouverte et vérifiée** immédiatement (déchiffrement + lecture du tar) : une sauvegarde qu'on ne sait pas relire ne vaut rien.

Seuls les **fichiers réguliers** de premier niveau de `~/.ssh` sont archivés. Les sous-dossiers sont ignorés et signalés — notamment `agent/`, qui contient des sockets que `tar` ne sait pas archiver.

Comportement à l'import :

- les fichiers déjà présents sont **conservés**, jamais écrasés sans `--force` ;
- `known_hosts` et `authorized_keys` sont **fusionnés** (dédoublonnés), pas remplacés ;
- les permissions sont normalisées : `700` sur le dossier, `600` sur les clés privées, `644` sur les `.pub`.

### Ce que ce script ne fait pas

Il n'envoie **rien** sur le réseau. Le transport de l'archive est ton geste, pas le sien.

> Une clé privée ne doit jamais entrer dans un dépôt git, un drive, un mail ou un chat. Sur un dépôt public, elle est compromise en quelques minutes : des bots scannent GitHub en continu, et supprimer le fichier ne l'efface pas de l'historique. La seule réponse à une clé exposée est sa révocation.

Le `.gitignore` de ce dépôt bloque `id_*`, `*.pem`, `*.key`, `*.age`, `*.gpg`, `*.enc` et `ssh-backup*` — un garde-fou contre un `git add -A` distrait.

### Module `ssh` — ne plus jamais retaper sa passphrase

Le problème classique : un `eval $(ssh-agent)` dans le `.bashrc` lance **un agent par terminal**, donc la passphrase est redemandée dans chaque onglet, et les clés se rechargent en boucle.

Ce module installe à la place un agent **unique par session**, géré par systemd :

- `ssh-agent.service` (unité utilisateur) tient un socket fixe dans `$XDG_RUNTIME_DIR` ;
- `SSH_AUTH_SOCK` pointe dessus depuis les shells (`.bashrc` / `.zshrc`) **et** depuis les applications graphiques (`~/.config/environment.d/`), donc les IDE JetBrains et VS Code voient les mêmes clés que le terminal ;
- `ssh-add-keys.service` charge **toutes** les clés privées de `~/.ssh` à l'ouverture de session — détectées par leur en-tête `-----BEGIN ... PRIVATE KEY-----`, pas par leur nom, donc les `.pem` sont pris aussi.

Pour que le chargement soit silencieux, mémorise la passphrase une fois par clé :

```bash
ssh-key-remember ~/.ssh/id_ed25519
```

Elle part dans le trousseau de session (libsecret), qui se déverrouille avec ton mot de passe de session. Ensuite, plus rien à taper — jamais.

| Commande | Rôle |
|---|---|
| `ssh-key-remember <clé>` | Mémorise la passphrase, après l'avoir **vérifiée** contre la clé |
| `ssh-add-all` | Charge dans l'agent les clés absentes ; liste celles dont la passphrase manque |
| `ssh-askpass-secret` | Fournit la passphrase à `ssh-add` depuis le trousseau (appelé automatiquement) |

Vérifier l'état :

```bash
systemctl --user status ssh-agent.service
ssh-add -l                       # doit lister toutes tes clés
```

Notes :

- `ssh-key-remember` **vérifie la passphrase avant de la stocker**. Une passphrase fausse en trousseau échouerait en silence à chaque session, ce qui est pire qu'une passphrase absente.
- Ni ce script ni les helpers ne passent la passphrase en argument de commande : elle transite par un askpass jetable, jamais par `argv`, qui est lisible par tous dans `ps`.
- `IdentitiesOnly yes` n'est **pas** activé globalement. Il limiterait `ssh` aux seules clés déclarées par hôte dans `~/.ssh/config`, et couperait l'accès à tout serveur dont la clé est simplement chargée dans l'agent.
- Sur une machine **sans session graphique** (serveur, SSH pur), le trousseau reste verrouillé : les clés ne se chargent pas seules, `ssh-add` reste nécessaire une fois par session.

### Licences JetBrains

PhpStorm et PyCharm Professional sont des produits **commerciaux**. Le script installe les binaires officiels depuis `data.services.jetbrains.com` ; l'activation se fait au premier lancement avec un compte JetBrains, une licence entreprise ou un serveur de licence.

## Licence

MIT
