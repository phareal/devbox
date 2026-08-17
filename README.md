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
| `ssh` | Clé ed25519, ssh-agent, `~/.ssh/config`, publication de la clé publique sur GitHub |
| `langs` | Node (fnm + LTS), uv, Go, Rust, PHP + Composer |
| `cuda` | Pilote NVIDIA open, CUDA Toolkit, nvidia-container-toolkit |
| `tweaks` | Limites inotify / nofile pour les IDE, défauts git |

`cuda` est **hors des modules par défaut** : il faut `--all` ou `--only cuda`.

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

### Licences JetBrains

PhpStorm et PyCharm Professional sont des produits **commerciaux**. Le script installe les binaires officiels depuis `data.services.jetbrains.com` ; l'activation se fait au premier lancement avec un compte JetBrains, une licence entreprise ou un serveur de licence.

## Licence

MIT
