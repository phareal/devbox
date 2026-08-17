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
| `apps` | VS Code (dépôt Microsoft), Postman |
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

### Licences JetBrains

PhpStorm et PyCharm Professional sont des produits **commerciaux**. Le script installe les binaires officiels depuis `data.services.jetbrains.com` ; l'activation se fait au premier lancement avec un compte JetBrains, une licence entreprise ou un serveur de licence.

## Licence

MIT
