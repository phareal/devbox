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
| `wm` | Bureau i3 en Catppuccin Mocha : i3-wm, alacritty, rofi, polybar, picom, feh |
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
- **Paquets manquants.** `apt-get` traite sa ligne de commande comme un tout : un seul nom inconnu, et rien n'est installé. Le module `wm` reprend donc paquet par paquet en cas d'échec groupé, nomme les fautifs, et **pose ses configurations malgré tout** — sans quoi un paquet absent d'`universe` laisserait le bureau sans aucun fichier de config.
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
| `~/.config/i3/config` | Gaps, raccourcis vim (`hjkl`), 6 espaces, rofi sur `$mod+d`, captures, services GNOME |
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

Restent utilisables : `launcher.sh` et `powermenu.sh` (rofi), eux-mêmes corrigés pour Ubuntu :

- `powermenu.sh` écrivait `dir="~/..."` — **le tilde entre guillemets n'est pas développé par bash**, donc rofi ne trouvait aucun de ses thèmes. Bug amont, corrigé en `$HOME`.
- entrée **Lock** rebranchée sur `loginctl lock-session` : elle appelait `i3lock` ou `betterlockscreen`, absents ici.
- **Suspend** : appels `mpc` et `amixer` retirés (pas de MPD, et Ubuntu tourne sur PipeWire).
- **Logout** : dépendait de `$DESKTOP_SESSION` valant exactement `i3` ; remplacé par un `i3-msg exit` inconditionnel.
- `launcher.sh` : `-modi drun` retiré, déprécié depuis rofi 1.7.6 au profit de `-modes` — `-show drun` suffit et fonctionne sur toutes les versions, dont la 2.0 qu'embarque Ubuntu 26.04.

`papirus-icon-theme` est installé, les `.rasi` du thème déclarant `icon-theme: "Papirus"`.

Le `launch.sh` du thème est corrigé au passage : `polybar -q` masquait toute erreur et n'écrivait aucun log, rendant un démarrage raté impossible à diagnostiquer — il écrit désormais dans `/tmp/polybar-$USER.log` ; et `killall` (paquet `psmisc`, absent d'une installation minimale) est remplacé par `pkill` (`procps`, toujours présent). Le lancement est câblé dans l'`exec_always` d'i3 ; une config i3 déjà posée par une version précédente du module est migrée automatiquement vers ce chemin, et un thème déjà installé se voit retirer le `color-switch` au passage.

`$mod` est la touche **Super**. Raccourcis principaux :

| Touches | Effet |
|---|---|
| `$mod+Return` | Terminal |
| `$mod+d` | Lanceur rofi |
| `$mod+Tab` | Bascule entre fenêtres |
| `$mod+Shift+q` | Fermer la fenêtre |
| `$mod+r` | Mode redimensionnement |
| `$mod+l` | Verrouiller l'écran |
| `$mod+Shift+e` | Quitter la session |

### Catppuccin Mocha de bout en bout

Terminal, barre, lanceur et fond d'écran partagent la même palette.

**Alacritty** devient le terminal par défaut du système (`update-alternatives --set x-terminal-emulator`), donc celui qu'ouvrent aussi les applications tierces et les fichiers `.desktop`. Sa palette est **écrite en dur** plutôt que téléchargée : elle est figée, et une coupure réseau laisserait sinon le terminal sans thème.

`~/.config/alacritty/alacritty.toml` utilise `[general] import` — depuis Alacritty 0.14 la clé a quitté la racine, et resolute embarque la **0.16.1**.

**Fond d'écran** : `coding1.jpg`, livré dans le dépôt et installé vers `~/.local/share/wallpapers/wallpaper`. La pose est faite par `~/.local/bin/devsetup-wallpaper`, lancé par i3 — `feh --bg-fill` si l'image existe, sinon un aplat `#1e1e2e` via `xsetroot`, sans quoi une image absente laisse le fond X en gris moucheté d'origine.

Trois sources, dans l'ordre : l'image du dépôt à côté du script, la même récupérée en ligne si le script tourne hors dépôt (`curl | bash`), puis l'aplat.

Pour changer d'image :

```bash
cp mon-image.jpg ~/.local/share/wallpapers/wallpaper
~/.local/bin/devsetup-wallpaper
```

Une image posée à la main n'est **jamais écrasée** : un marqueur `.devsetup-default` distingue ce que le script a installé de ce que tu as choisi. Sans marqueur, le fichier est considéré comme tien et laissé tel quel.

**Polybar** : le `colors.ini` du thème passe en Mocha, les huit *shades* de colorblocks recevant le dégradé bleu → lavande plutôt que l'orange d'origine. **rofi** et **picom** étaient déjà sur cette palette.

### Services GNOME sous i3

GNOME installé sur la machine ne suffit pas : un paquet ne fait rien tant qu'il n'est pas lancé, et `gnome-shell` ne peut pas l'être sous i3 — il *est* le gestionnaire de fenêtres, place déjà prise. Plutôt qu'une session hybride `gnome-session` + i3, fragile depuis que GNOME 46 pilote ses composants par unités systemd, le module lance à l'unité ce qui est utile :

```
/usr/libexec/gsd-xsettings      thèmes GTK, polices, curseurs
/usr/libexec/gsd-media-keys     touches volume et média
/usr/libexec/gsd-power          gestion de l'énergie
/usr/libexec/gsd-sound
/usr/libexec/gsd-keyboard       disposition clavier
/usr/libexec/gsd-housekeeping   nettoyage corbeille et temporaires
```

Chacun est indépendant : commenter sa ligne dans `~/.config/i3/config` suffit à le retirer. `gsd-media-keys` reprenant volume et sourdine, les `bindsym XF86AudioRaiseVolume`/`LowerVolume`/`Mute` sont retirés de la config — les garder ferait doublon. Le contrôle du lecteur (`playerctl`) reste côté i3.

Ubuntu resolute embarque **GNOME 50** (`gnome-settings-daemon-50`).

### Verrouillage d'écran

```
Super+l        →  loginctl lock-session
```

Un seul geste, valable dans les deux sessions. Sous GNOME, logind délègue à gnome-shell. Sous i3, **`xss-lock`** écoute le signal `Lock` de logind et lance le verrou.

Le verrou est **`gnome-screensaver`** — le verrou GNOME historique, encore packagé dans resolute et autonome sous X11. C'est le seul moyen d'avoir l'écran GNOME dans une session i3 : l'écran de verrouillage du GNOME actuel *est* gnome-shell, qui n'y tourne pas. `i3lock` reste écarté ; `xsecurelock` sert de repli si gnome-screensaver est indisponible.

Le tout passe par `~/.local/bin/devsetup-lock`, qui existe pour une raison précise : **`xss-lock` exige une commande bloquante**, considérant l'écran déverrouillé dès qu'elle rend la main — or `gnome-screensaver-command --lock` rend la main aussitôt. Le wrapper attend donc sur `--query` jusqu'au déverrouillage, faute de quoi `--transfer-sleep-lock` ne garantit plus le verrouillage *avant* la mise en veille.

L'entrée **Lock** du powermenu passe par la même commande.

> `gnome-screensaver` n'est plus maintenu en amont. C'est le compromis assumé pour obtenir l'écran GNOME sous i3 ; `xsecurelock`, déjà installé, est nettement plus solide si la sécurité prime sur l'apparence — il suffit de pointer `devsetup-lock` dessus.

Note : `$mod+l` entrant en conflit avec le focus vers la droite, celui-ci passe sur `$mod+semicolon` (et `$mod+Shift+semicolon` pour déplacer).

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
