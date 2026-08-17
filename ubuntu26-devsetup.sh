#!/usr/bin/env bash
#
# ubuntu26-devsetup.sh — poste de dev complet sur Ubuntu 26.04 LTS
#
#   ./ubuntu26-devsetup.sh --list                  # voir les modules
#   ./ubuntu26-devsetup.sh                         # tout installer (hors cuda)
#   ./ubuntu26-devsetup.sh --all                   # tout, cuda compris
#   ./ubuntu26-devsetup.sh --only docker,k8s,lazy  # sélection
#   ./ubuntu26-devsetup.sh --skip cuda,langs       # exclusion
#   ./ubuntu26-devsetup.sh --dry-run --all         # simulation
#
# Idempotent : relançable sans casse. Ne s'exécute pas en root (utilise sudo).
#
set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
DRY_RUN=0
ASSUME_YES=0
CURRENT_MODULE="init"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'
else
    C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
fi

log()   { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s  ! %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
err()   { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
skip()  { printf '%s  · %s (déjà présent)%s\n' "$C_DIM" "$*" "$C_RESET"; }

trap 'err "Échec dans le module \"$CURRENT_MODULE\" (ligne $LINENO)."; exit 1' ERR

run() {
    if (( DRY_RUN )); then
        printf '%s  [dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Détection système
# ---------------------------------------------------------------------------
require_ubuntu() {
    [[ -r /etc/os-release ]] || { err "/etc/os-release introuvable."; exit 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || warn "Distribution '${ID:-?}' — script prévu pour Ubuntu, on continue quand même."
    OS_VERSION="${VERSION_ID:-inconnue}"
    CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
    # Codename LTS de repli quand un dépôt tiers ne publie pas encore 26.04.
    FALLBACK_CODENAME="noble"
}

detect_arch() {
    DPKG_ARCH=$(dpkg --print-architecture)          # amd64 | arm64
    case "$DPKG_ARCH" in
        amd64) UNAME_ARCH="x86_64"; GH_ARCH="x86_64"; ALT_ARCH="amd64" ;;
        arm64) UNAME_ARCH="aarch64"; GH_ARCH="arm64"; ALT_ARCH="arm64" ;;
        *) err "Architecture non supportée : $DPKG_ARCH"; exit 1 ;;
    esac
}

require_not_root() {
    if [[ $EUID -eq 0 ]]; then
        err "Ne pas lancer en root. Lance en utilisateur normal, le script appellera sudo."
        exit 1
    fi
    command -v sudo >/dev/null || { err "sudo requis."; exit 1; }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
BIN_DIR="/usr/local/bin"
KEYRINGS="/etc/apt/keyrings"
APT_UPDATED=0

apt_update() {
    (( APT_UPDATED )) && return 0
    run sudo apt-get update -qq
    APT_UPDATED=1
}

apt_refresh() { APT_UPDATED=0; apt_update; }

apt_install() {
    local pkgs=("$@") missing=()
    for p in "${pkgs[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed$" || missing+=("$p")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        skip "paquets : ${pkgs[*]}"
        return 0
    fi
    apt_update
    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    ok "paquets installés : ${missing[*]}"
}

# Installe un paquet s'il existe dans les dépôts, sinon prévient (utile pour les
# noms qui bougent d'une release Ubuntu à l'autre, ex. libfuse2 -> libfuse2t64).
apt_install_optional() {
    local found=()
    for p in "$@"; do
        if apt-cache show "$p" >/dev/null 2>&1; then found+=("$p"); fi
    done
    if [[ ${#found[@]} -gt 0 ]]; then
        apt_install "${found[@]}"
    else
        warn "aucun de ces paquets n'existe dans les dépôts : $*"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

url_exists() { curl -fsSIL --max-time 15 -o /dev/null "$1" 2>/dev/null; }

# Dernier tag d'un dépôt GitHub. Honore GITHUB_TOKEN si présent (quota API).
gh_latest_tag() {
    local repo="$1" hdr=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL --max-time 20 "${hdr[@]}" "https://api.github.com/repos/${repo}/releases/latest" \
        | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -n1
}

add_apt_repo() {
    # add_apt_repo <nom> <url-clé-gpg> <ligne-deb-sans-signed-by>
    local name="$1" key_url="$2" repo_line="$3"
    local key="${KEYRINGS}/${name}.gpg"
    local list="/etc/apt/sources.list.d/${name}.list"

    run sudo install -m 0755 -d "$KEYRINGS"
    if [[ ! -s "$key" ]]; then
        run bash -c "curl -fsSL '$key_url' | sudo gpg --dearmor --yes -o '$key'"
        run sudo chmod a+r "$key"
    fi
    local line="deb [arch=${DPKG_ARCH} signed-by=${key}] ${repo_line}"
    if [[ ! -f "$list" ]] || ! grep -qxF "$line" "$list" 2>/dev/null; then
        run bash -c "echo '$line' | sudo tee '$list' >/dev/null"
        APT_UPDATED=0
    fi
}

# Télécharge une archive .tar.gz et pose un binaire dans /usr/local/bin.
install_tarball_bin() {
    # install_tarball_bin <url> <nom-binaire-dans-archive> <nom-cible>
    local url="$1" inner="$2" target="${3:-$2}"
    local tmp; tmp=$(mktemp -d)
    run bash -c "curl -fsSL '$url' -o '$tmp/pkg.tar.gz'"
    run tar -xzf "$tmp/pkg.tar.gz" -C "$tmp"
    local found
    if (( DRY_RUN )); then
        ok "[dry-run] $target depuis $url"
        rm -rf "$tmp"; return 0
    fi
    found=$(find "$tmp" -type f -name "$inner" -perm -u+x 2>/dev/null | head -n1)
    [[ -n "$found" ]] || found=$(find "$tmp" -type f -name "$inner" | head -n1)
    [[ -n "$found" ]] || { rm -rf "$tmp"; err "binaire '$inner' absent de l'archive $url"; return 1; }
    sudo install -m 0755 "$found" "${BIN_DIR}/${target}"
    rm -rf "$tmp"
    ok "$target installé dans ${BIN_DIR}"
}

add_user_to_group() {
    local grp="$1"
    if id -nG "$USER" | tr ' ' '\n' | grep -qx "$grp"; then
        skip "utilisateur déjà dans le groupe $grp"
    else
        run sudo usermod -aG "$grp" "$USER"
        NEED_RELOGIN=1
        ok "utilisateur ajouté au groupe $grp (déconnexion/reconnexion requise)"
    fi
}

# ===========================================================================
# MODULES
# ===========================================================================

# --- base ------------------------------------------------------------------
mod_base_desc="Paquets de base : build-essential, git, curl, outils réseau/archive"
mod_base() {
    apt_install \
        build-essential pkg-config cmake make gcc g++ \
        git git-lfs curl wget ca-certificates gnupg lsb-release \
        apt-transport-https software-properties-common \
        unzip zip xz-utils tar jq \
        openssh-client rsync net-tools dnsutils iputils-ping traceroute \
        htop tree vim nano less man-db \
        python3 python3-venv python3-pip pipx \
        sqlite3 gettext-base
    run git lfs install --skip-repo || true
}

# --- shell -----------------------------------------------------------------
mod_shell_desc="Shell moderne : zsh, starship, fzf, ripgrep, fd, bat, eza, zoxide, tmux"
mod_shell() {
    apt_install zsh tmux fzf ripgrep fd-find bat
    apt_install_optional eza zoxide

    # Ubuntu nomme ces binaires fdfind / batcat : alias standards.
    if have fdfind && [[ ! -e "${BIN_DIR}/fd" ]]; then
        run sudo ln -sf "$(command -v fdfind)" "${BIN_DIR}/fd"
    fi
    if have batcat && [[ ! -e "${BIN_DIR}/bat" ]]; then
        run sudo ln -sf "$(command -v batcat)" "${BIN_DIR}/bat"
    fi

    if have starship; then
        skip "starship"
    else
        run bash -c "curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir '$BIN_DIR'"
        ok "starship installé"
    fi

    # Ajout non destructif au rc courant.
    local rc="${HOME}/.bashrc"
    [[ -n "${ZSH_VERSION:-}" || "${SHELL:-}" == */zsh ]] && rc="${HOME}/.zshrc"
    if [[ -f "$rc" ]] && ! grep -q 'starship init' "$rc"; then
        local init_cmd='eval "$(starship init bash)"'
        [[ "$rc" == *".zshrc" ]] && init_cmd='eval "$(starship init zsh)"'
        run bash -c "printf '\n# ajouté par ${SCRIPT_NAME}\n%s\n' '$init_cmd' >> '$rc'"
        ok "starship branché dans $rc"
    fi
}

# --- docker ----------------------------------------------------------------
mod_docker_desc="Docker Engine + CLI + Buildx + Compose v2 (dépôt officiel Docker)"
mod_docker() {
    # Retire les paquets Docker de la distro qui entrent en conflit.
    local conflicting=(docker.io docker-doc docker-compose podman-docker containerd runc)
    for p in "${conflicting[@]}"; do
        if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed$"; then
            warn "suppression du paquet conflictuel : $p"
            run sudo apt-get remove -y "$p"
        fi
    done

    local dcodename="$CODENAME"
    if ! url_exists "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/Release"; then
        warn "dépôt Docker absent pour '${CODENAME}', repli sur '${FALLBACK_CODENAME}'"
        dcodename="$FALLBACK_CODENAME"
    fi

    add_apt_repo "docker" \
        "https://download.docker.com/linux/ubuntu/gpg" \
        "https://download.docker.com/linux/ubuntu ${dcodename} stable"

    apt_install docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin

    run sudo systemctl enable --now docker
    add_user_to_group docker
}

# --- lazy ------------------------------------------------------------------
mod_lazy_desc="lazygit, lazydocker, dive, ctop (TUI Git/Docker)"
mod_lazy() {
    # lazygit
    if have lazygit; then
        skip "lazygit ($(lazygit --version 2>/dev/null | head -c 60))"
    else
        local tag ver
        tag=$(gh_latest_tag jesseduffield/lazygit); ver="${tag#v}"
        install_tarball_bin \
            "https://github.com/jesseduffield/lazygit/releases/download/${tag}/lazygit_${ver}_Linux_${GH_ARCH}.tar.gz" \
            "lazygit"
    fi

    # lazydocker
    if have lazydocker; then
        skip "lazydocker"
    else
        local tag ver
        tag=$(gh_latest_tag jesseduffield/lazydocker); ver="${tag#v}"
        install_tarball_bin \
            "https://github.com/jesseduffield/lazydocker/releases/download/${tag}/lazydocker_${ver}_Linux_${GH_ARCH}.tar.gz" \
            "lazydocker"
    fi

    # dive — inspection des couches d'image
    if have dive; then
        skip "dive"
    else
        local tag ver tmp
        tag=$(gh_latest_tag wagoodman/dive); ver="${tag#v}"
        tmp=$(mktemp -d)
        run bash -c "curl -fsSL 'https://github.com/wagoodman/dive/releases/download/${tag}/dive_${ver}_linux_${ALT_ARCH}.deb' -o '$tmp/dive.deb'"
        run sudo apt-get install -y "$tmp/dive.deb"
        rm -rf "$tmp"
        ok "dive installé"
    fi

    # ctop
    if have ctop; then
        skip "ctop"
    else
        local tag ver
        tag=$(gh_latest_tag bcicen/ctop); ver="${tag#v}"
        run bash -c "sudo curl -fsSL 'https://github.com/bcicen/ctop/releases/download/${tag}/ctop-${ver}-linux-${ALT_ARCH}' -o '${BIN_DIR}/ctop' && sudo chmod 0755 '${BIN_DIR}/ctop'"
        ok "ctop installé"
    fi
}

# --- k8s -------------------------------------------------------------------
mod_k8s_desc="Kubernetes : kubectl, helm, k9s, kubectx/kubens, kind, minikube, kustomize"
mod_k8s() {
    # kubectl via pkgs.k8s.io — le dépôt est versionné par mineure.
    local stable minor
    stable=$(curl -fsSL --max-time 20 https://dl.k8s.io/release/stable.txt || echo "")
    if [[ "$stable" =~ ^v([0-9]+\.[0-9]+) ]]; then
        minor="v${BASH_REMATCH[1]}"
    else
        minor="v1.34"
        warn "version stable de Kubernetes non résolue, repli sur ${minor}"
    fi
    add_apt_repo "kubernetes" \
        "https://pkgs.k8s.io/core:/stable:/${minor}/deb/Release.key" \
        "https://pkgs.k8s.io/core:/stable:/${minor}/deb/ /"
    # Ce dépôt n'utilise pas la syntaxe [arch=] classique ; on réécrit la ligne.
    run bash -c "echo 'deb [signed-by=${KEYRINGS}/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/${minor}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null"
    APT_UPDATED=0
    apt_install kubectl

    # helm
    if have helm; then
        skip "helm"
    else
        add_apt_repo "helm" \
            "https://baltocdn.com/helm/signing.asc" \
            "https://baltocdn.com/helm/stable/debian/ all main"
        apt_install helm
    fi

    # k9s
    if have k9s; then
        skip "k9s"
    else
        local tag
        tag=$(gh_latest_tag derailed/k9s)
        install_tarball_bin \
            "https://github.com/derailed/k9s/releases/download/${tag}/k9s_Linux_${ALT_ARCH}.tar.gz" \
            "k9s"
    fi

    # kubectx / kubens
    for tool in kubectx kubens; do
        if have "$tool"; then
            skip "$tool"
        else
            local tag
            tag=$(gh_latest_tag ahmetb/kubectx)
            install_tarball_bin \
                "https://github.com/ahmetb/kubectx/releases/download/${tag}/${tool}_${tag}_linux_${GH_ARCH}.tar.gz" \
                "$tool"
        fi
    done

    # kind
    if have kind; then
        skip "kind"
    else
        local tag
        tag=$(gh_latest_tag kubernetes-sigs/kind)
        run bash -c "sudo curl -fsSL 'https://kind.sigs.k8s.io/dl/${tag}/kind-linux-${ALT_ARCH}' -o '${BIN_DIR}/kind' && sudo chmod 0755 '${BIN_DIR}/kind'"
        ok "kind installé"
    fi

    # minikube
    if have minikube; then
        skip "minikube"
    else
        local tmp; tmp=$(mktemp -d)
        run bash -c "curl -fsSL 'https://storage.googleapis.com/minikube/releases/latest/minikube_latest_${ALT_ARCH}.deb' -o '$tmp/minikube.deb'"
        run sudo apt-get install -y "$tmp/minikube.deb"
        rm -rf "$tmp"
        ok "minikube installé"
    fi

    # kustomize
    if have kustomize; then
        skip "kustomize"
    else
        local tag ver
        tag=$(gh_latest_tag kubernetes-sigs/kustomize)   # ex. kustomize/v5.4.3
        ver="${tag##*/}"
        install_tarball_bin \
            "https://github.com/kubernetes-sigs/kustomize/releases/download/${tag}/kustomize_${ver}_linux_${ALT_ARCH}.tar.gz" \
            "kustomize"
    fi

    # Complétions shell
    if [[ ! -f /etc/bash_completion.d/kubectl ]] && have kubectl; then
        run bash -c "kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl >/dev/null"
    fi
}

# --- jetbrains -------------------------------------------------------------
mod_jetbrains_desc="JetBrains Toolbox + PhpStorm + PyCharm Professional (licence payante à activer)"
mod_jetbrains() {
    # AppImage/Toolbox exigent FUSE 2 ; le nom du paquet a changé sur les
    # releases récentes (libfuse2 -> libfuse2t64).
    apt_install_optional libfuse2t64 libfuse2
    apt_install fuse3 libxi6 libxrender1 libxtst6 libfontconfig1 libgtk-3-0t64 || \
        apt_install fuse3 libxi6 libxrender1 libxtst6 libfontconfig1

    local opt="/opt/jetbrains"
    run sudo mkdir -p "$opt"

    # --- Toolbox App (gère les mises à jour et l'activation de licence) -----
    if [[ -x "${BIN_DIR}/jetbrains-toolbox" ]]; then
        skip "JetBrains Toolbox"
    else
        local tmp; tmp=$(mktemp -d)
        log "téléchargement de JetBrains Toolbox…"
        run bash -c "curl -fsSL 'https://data.services.jetbrains.com/products/download?platform=linux&code=TBA' -o '$tmp/toolbox.tar.gz'"
        if ! (( DRY_RUN )); then
            tar -xzf "$tmp/toolbox.tar.gz" -C "$tmp"
            local dir; dir=$(find "$tmp" -maxdepth 1 -type d -name 'jetbrains-toolbox-*' | head -n1)
            sudo rm -rf "${opt}/toolbox"
            sudo mv "$dir" "${opt}/toolbox"
            sudo ln -sf "${opt}/toolbox/jetbrains-toolbox" "${BIN_DIR}/jetbrains-toolbox"
            ok "JetBrains Toolbox installé (lance 'jetbrains-toolbox' pour te connecter)"
        fi
        rm -rf "$tmp"
    fi

    # --- IDE en installation directe ---------------------------------------
    # PS  = PhpStorm (produit commercial, licence requise)
    # PCP = PyCharm Professional (licence requise)
    _install_jetbrains_ide "PS"  "phpstorm" "PhpStorm"            "phpstorm.png"
    _install_jetbrains_ide "PCP" "pycharm"  "PyCharm Professional" "pycharm.png"

    cat <<'EOT'

  ── Licences JetBrains ──────────────────────────────────────────────────────
  PhpStorm et PyCharm Professional sont des produits commerciaux. Le script
  installe les binaires officiels ; l'activation se fait au premier lancement,
  avec ton compte JetBrains (abonnement, licence entreprise ou serveur de
  licence). N'utilise pas de contournement d'activation : c'est illégal et ça
  casse les mises à jour.
  ────────────────────────────────────────────────────────────────────────────
EOT
}

_install_jetbrains_ide() {
    local code="$1" slug="$2" label="$3" icon="$4"
    local opt="/opt/jetbrains" target="/opt/jetbrains/${slug}"

    if [[ -x "${target}/bin/${slug}.sh" ]]; then
        skip "$label"
        return 0
    fi

    local url="https://data.services.jetbrains.com/products/download?platform=linux&code=${code}"
    [[ "$DPKG_ARCH" == "arm64" ]] && url="${url}&type=linuxARM64"

    log "téléchargement de ${label}…"
    local tmp; tmp=$(mktemp -d)
    run bash -c "curl -fsSL '$url' -o '$tmp/ide.tar.gz'"
    if (( DRY_RUN )); then rm -rf "$tmp"; ok "[dry-run] $label"; return 0; fi

    tar -xzf "$tmp/ide.tar.gz" -C "$tmp"
    local dir; dir=$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -n1)
    [[ -n "$dir" ]] || { rm -rf "$tmp"; err "archive ${label} illisible"; return 1; }

    sudo rm -rf "$target"
    sudo mkdir -p "$opt"
    sudo mv "$dir" "$target"
    sudo ln -sf "${target}/bin/${slug}.sh" "${BIN_DIR}/${slug}"
    rm -rf "$tmp"

    sudo tee "/usr/share/applications/jetbrains-${slug}.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=${label}
Icon=${target}/bin/${icon}
Exec="${target}/bin/${slug}.sh" %f
Comment=${label}
Categories=Development;IDE;
Terminal=false
StartupWMClass=jetbrains-${slug}
EOF
    ok "${label} installé dans ${target} (commande : ${slug})"
}

# --- ssh -------------------------------------------------------------------
mod_ssh_desc="Clés SSH : génération ed25519, ssh-agent, ~/.ssh/config, publication sur GitHub"
mod_ssh() {
    apt_install openssh-client

    local d="${HOME}/.ssh"
    local key="${d}/id_ed25519"

    run install -d -m 700 "$d"

    # --- Clé principale -----------------------------------------------------
    # Aucune clé existante n'est écrasée : si le fichier est là, on n'y touche pas.
    if [[ -f "$key" ]]; then
        skip "clé ${key}"
    elif (( DRY_RUN )); then
        ok "[dry-run] génération de ${key}"
    else
        local comment="${USER}@$(hostname -s 2>/dev/null || hostname)"
        if (( ASSUME_YES )); then
            ssh-keygen -t ed25519 -a 100 -C "$comment" -f "$key" -N ""
            warn "clé générée SANS passphrase (mode --yes)."
            warn "ajoute-en une dès que possible :  ssh-keygen -p -f $key"
        else
            log "génération d'une clé ed25519 — choisis une passphrase (recommandé)."
            ssh-keygen -t ed25519 -a 100 -C "$comment" -f "$key"
        fi
        ok "clé créée : ${key}"
    fi

    # --- Permissions --------------------------------------------------------
    # OpenSSH refuse d'utiliser une clé privée lisible par d'autres.
    if ! (( DRY_RUN )); then
        chmod 700 "$d"
        find "$d" -maxdepth 1 -type f ! -name '*.pub' ! -name 'known_hosts*' \
             ! -name 'config' -exec chmod 600 {} + 2>/dev/null || true
        find "$d" -maxdepth 1 -type f -name '*.pub' -exec chmod 644 {} + 2>/dev/null || true
        [[ -f "${d}/config" ]] && chmod 600 "${d}/config"
        ok "permissions de ~/.ssh normalisées (700 / 600 / 644)"
    fi

    # --- ~/.ssh/config ------------------------------------------------------
    # Bloc délimité et écrit une seule fois : un config existant est préservé.
    local cfg="${d}/config"
    if [[ -f "$cfg" ]] && grep -q 'devsetup:managed' "$cfg"; then
        skip "bloc ~/.ssh/config"
    elif (( DRY_RUN )); then
        ok "[dry-run] bloc ajouté à ${cfg}"
    else
        [[ -f "$cfg" ]] && cp -n "$cfg" "${cfg}.bak" 2>/dev/null || true
        cat >>"$cfg" <<EOF

# >>> devsetup:managed >>>
Host *
    AddKeysToAgent yes
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    HashKnownHosts yes

Host github.com
    HostName github.com
    User git
    IdentityFile ${key}
# <<< devsetup:managed <<<
EOF
        chmod 600 "$cfg"
        ok "bloc de configuration ajouté à ${cfg}"
        [[ -f "${cfg}.bak" ]] && warn "ancien config sauvegardé : ${cfg}.bak"
    fi

    # --- ssh-agent au login -------------------------------------------------
    local rc="${HOME}/.bashrc"
    [[ "${SHELL:-}" == */zsh ]] && rc="${HOME}/.zshrc"
    if [[ -f "$rc" ]] && grep -q 'devsetup:ssh-agent' "$rc"; then
        skip "démarrage de ssh-agent dans $rc"
    elif [[ -f "$rc" ]]; then
        run bash -c "cat >>'$rc' <<'EOS'

# devsetup:ssh-agent — démarre un agent unique et y charge la clé par défaut
if [ -z \"\${SSH_AUTH_SOCK:-}\" ]; then
    eval \"\$(ssh-agent -s)\" >/dev/null
fi
ssh-add -l >/dev/null 2>&1 || ssh-add ~/.ssh/id_ed25519 2>/dev/null
EOS"
        ok "ssh-agent branché dans $rc"
    fi

    # --- Publication de la clé PUBLIQUE sur GitHub --------------------------
    # Seul le .pub quitte la machine. La clé privée ne bouge jamais.
    if [[ ! -f "${key}.pub" ]]; then
        warn "pas de ${key}.pub — publication GitHub ignorée."
        return 0
    fi
    if ! have gh; then
        warn "GitHub CLI absent (module 'apps') — ajoute la clé à la main :"
        warn "  https://github.com/settings/ssh/new"
        return 0
    fi
    if ! gh auth status >/dev/null 2>&1; then
        warn "gh non authentifié. Lance 'gh auth login', puis :"
        warn "  gh ssh-key add ${key}.pub --title \"\$(hostname -s)\""
        return 0
    fi

    local fp
    fp=$(ssh-keygen -lf "${key}.pub" 2>/dev/null | awk '{print $2}')
    if gh ssh-key list 2>/dev/null | grep -qF "$fp"; then
        skip "clé publique déjà présente sur GitHub"
    else
        run gh ssh-key add "${key}.pub" --title "$(hostname -s 2>/dev/null || hostname)"
        ok "clé publique ajoutée au compte GitHub"
    fi
}

# --- apps ------------------------------------------------------------------
mod_apps_desc="VS Code (dépôt Microsoft) + Postman + GitHub CLI"
mod_apps() {
    # --- GitHub CLI ---------------------------------------------------------
    if have gh; then
        skip "gh ($(gh --version 2>/dev/null | head -n1))"
    else
        add_apt_repo "githubcli" \
            "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
            "https://cli.github.com/packages stable main"
        # Cette clé est déjà binaire : le dearmor de add_apt_repo la rejetterait.
        run bash -c "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee ${KEYRINGS}/githubcli.gpg >/dev/null"
        run sudo chmod a+r "${KEYRINGS}/githubcli.gpg"
        APT_UPDATED=0
        apt_install gh
    fi

    # --- Visual Studio Code -------------------------------------------------
    if have code; then
        skip "VS Code ($(code --version 2>/dev/null | head -n1))"
    else
        add_apt_repo "microsoft" \
            "https://packages.microsoft.com/keys/microsoft.asc" \
            "https://packages.microsoft.com/repos/code stable main"
        apt_install code
    fi

    # --- Postman ------------------------------------------------------------
    # Application Electron : dépendances GUI explicites (le tarball n'en tire
    # aucune tout seul).
    apt_install_optional libgtk-3-0t64 libgtk-3-0
    apt_install_optional libasound2t64 libasound2
    apt_install libnss3 libxss1 libxtst6 libsecret-1-0 xdg-utils

    local target="/opt/postman"
    if [[ -x "${target}/Postman" ]]; then
        skip "Postman"
    else
        local url="https://dl.pstmn.io/download/latest/linux_64"
        [[ "$DPKG_ARCH" == "arm64" ]] && url="https://dl.pstmn.io/download/latest/linux_arm64"

        log "téléchargement de Postman…"
        local tmp; tmp=$(mktemp -d)
        run bash -c "curl -fsSL '$url' -o '$tmp/postman.tar.gz'"

        if (( DRY_RUN )); then
            ok "[dry-run] Postman"
        else
            tar -xzf "$tmp/postman.tar.gz" -C "$tmp"
            local dir; dir=$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -n1)
            [[ -n "$dir" ]] || { rm -rf "$tmp"; err "archive Postman illisible"; return 1; }

            sudo rm -rf "$target"
            sudo mv "$dir" "$target"
            sudo ln -sf "${target}/Postman" "${BIN_DIR}/postman"

            sudo tee /usr/share/applications/postman.desktop >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=Postman
Icon=${target}/app/resources/app/assets/icon.png
Exec="${target}/Postman" %U
Comment=Plateforme de test d'API
Categories=Development;Network;
Terminal=false
StartupWMClass=Postman
EOF
            ok "Postman installé dans ${target} (commande : postman)"
        fi
        rm -rf "$tmp"
    fi
}

# --- langs -----------------------------------------------------------------
mod_langs_desc="Runtimes : Node (fnm+LTS), Python (uv+pipx), Go, Rust, PHP+Composer"
mod_langs() {
    # Node via fnm (gestion multi-versions, pas de sudo pour npm -g)
    if [[ -x "${HOME}/.local/share/fnm/fnm" ]] || have fnm; then
        skip "fnm"
    else
        run bash -c "curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir '${HOME}/.local/share/fnm' --skip-shell"
        ok "fnm installé"
    fi
    if [[ -x "${HOME}/.local/share/fnm/fnm" ]] && ! (( DRY_RUN )); then
        export PATH="${HOME}/.local/share/fnm:$PATH"
        eval "$(fnm env --shell bash)" || true
        fnm install --lts || true
        fnm default "$(fnm ls --json 2>/dev/null | grep -oP '"version":"\Kv[0-9.]+' | tail -n1)" 2>/dev/null || true
    fi

    # Python : uv (gestionnaire projets/venv rapide)
    if have uv; then
        skip "uv"
    else
        run bash -c "curl -fsSL https://astral.sh/uv/install.sh | sh"
        ok "uv installé (~/.local/bin)"
    fi
    run pipx ensurepath || true

    # Go
    if have go; then
        skip "go ($(go version 2>/dev/null | awk '{print $3}'))"
    else
        local gover
        gover=$(curl -fsSL --max-time 20 https://go.dev/VERSION?m=text | head -n1)
        [[ -n "$gover" ]] || gover="go1.24.0"
        local tmp; tmp=$(mktemp -d)
        run bash -c "curl -fsSL 'https://go.dev/dl/${gover}.linux-${ALT_ARCH}.tar.gz' -o '$tmp/go.tar.gz'"
        run sudo rm -rf /usr/local/go
        run sudo tar -C /usr/local -xzf "$tmp/go.tar.gz"
        rm -rf "$tmp"
        run bash -c "echo 'export PATH=\$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh >/dev/null"
        ok "${gover} installé dans /usr/local/go"
    fi

    # Rust
    if have rustc || [[ -x "${HOME}/.cargo/bin/rustc" ]]; then
        skip "rust"
    else
        run bash -c "curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path"
        ok "rust installé (~/.cargo/bin)"
    fi

    # PHP + Composer
    apt_install php-cli php-xml php-mbstring php-curl php-zip php-intl php-bcmath php-sqlite3
    if have composer; then
        skip "composer"
    else
        local tmp; tmp=$(mktemp -d)
        run bash -c "curl -fsSL https://getcomposer.org/installer -o '$tmp/composer-setup.php'"
        run bash -c "php '$tmp/composer-setup.php' --install-dir='$tmp' --filename=composer"
        run sudo install -m 0755 "$tmp/composer" "${BIN_DIR}/composer"
        rm -rf "$tmp"
        ok "composer installé"
    fi
}

# --- cuda ------------------------------------------------------------------
mod_cuda_desc="NVIDIA : pilote open, CUDA Toolkit, nvidia-container-toolkit (GPU dans Docker)"
mod_cuda() {
    if ! lspci 2>/dev/null | grep -qi 'nvidia'; then
        warn "aucun GPU NVIDIA détecté par lspci — module cuda ignoré."
        return 0
    fi

    # Dépôt CUDA : tente le codename de la release, puis les LTS précédentes.
    local repo="" candidate
    for candidate in "ubuntu$(echo "$OS_VERSION" | tr -d '.')" ubuntu2604 ubuntu2404; do
        if url_exists "https://developer.download.nvidia.com/compute/cuda/repos/${candidate}/${UNAME_ARCH}/cuda-keyring_1.1-1_all.deb"; then
            repo="$candidate"; break
        fi
    done
    [[ -n "$repo" ]] || { err "dépôt CUDA introuvable pour Ubuntu ${OS_VERSION}/${UNAME_ARCH}."; return 1; }
    [[ "$repo" == "ubuntu$(echo "$OS_VERSION" | tr -d '.')" ]] || \
        warn "dépôt CUDA pour Ubuntu ${OS_VERSION} indisponible, repli sur '${repo}'"

    local tmp; tmp=$(mktemp -d)
    run bash -c "curl -fsSL 'https://developer.download.nvidia.com/compute/cuda/repos/${repo}/${UNAME_ARCH}/cuda-keyring_1.1-1_all.deb' -o '$tmp/cuda-keyring.deb'"
    run sudo dpkg -i "$tmp/cuda-keyring.deb"
    rm -rf "$tmp"
    apt_refresh

    # Pilote "open" : requis pour Turing (RTX 20xx) et plus récent.
    apt_install_optional nvidia-open cuda-drivers
    # Toolkit sans le métapaquet 'cuda' pour ne pas re-tirer un pilote concurrent.
    apt_install cuda-toolkit

    run bash -c "printf 'export PATH=/usr/local/cuda/bin:\$PATH\nexport LD_LIBRARY_PATH=/usr/local/cuda/lib64:\${LD_LIBRARY_PATH:-}\n' | sudo tee /etc/profile.d/cuda.sh >/dev/null"

    # Runtime GPU pour Docker.
    add_apt_repo "nvidia-container-toolkit" \
        "https://nvidia.github.io/libnvidia-container/gpgkey" \
        "https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH) /"
    run bash -c "echo 'deb [signed-by=${KEYRINGS}/nvidia-container-toolkit.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/${DPKG_ARCH} /' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null"
    APT_UPDATED=0
    apt_install nvidia-container-toolkit

    if have docker; then
        run sudo nvidia-ctk runtime configure --runtime=docker
        run sudo systemctl restart docker
        ok "runtime GPU branché sur Docker — test : docker run --rm --gpus all ubuntu nvidia-smi"
    fi

    NEED_REBOOT=1
    warn "pilote NVIDIA installé : redémarrage requis avant que nvidia-smi fonctionne."
}

# --- tweaks ----------------------------------------------------------------
mod_tweaks_desc="Réglages système : limites inotify/file-max pour IDE, git sensible"
mod_tweaks() {
    # Les IDE JetBrains saturent les limites par défaut sur gros dépôts.
    local conf="/etc/sysctl.d/99-devsetup.conf"
    run bash -c "cat <<'EOF' | sudo tee '$conf' >/dev/null
# Ajouté par ubuntu26-devsetup.sh — limites pour IDE / watchers de fichiers
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
fs.file-max = 2097152
vm.max_map_count = 262144
EOF"
    run sudo sysctl --system >/dev/null
    ok "limites inotify/file-max relevées"

    run bash -c "cat <<'EOF' | sudo tee /etc/security/limits.d/99-devsetup.conf >/dev/null
*  soft  nofile  65536
*  hard  nofile  524288
EOF"

    git config --global --get init.defaultBranch >/dev/null 2>&1 || run git config --global init.defaultBranch main
    git config --global --get pull.rebase       >/dev/null 2>&1 || run git config --global pull.rebase true
    git config --global --get core.editor       >/dev/null 2>&1 || run git config --global core.editor vim
    ok "défauts git posés (non destructif)"
}

# ===========================================================================
# Orchestration
# ===========================================================================
# L'ordre compte : 'apps' installe gh, dont 'ssh' se sert pour publier la clé.
ALL_MODULES=(base shell docker lazy k8s jetbrains apps ssh langs cuda tweaks)
DEFAULT_MODULES=(base shell docker lazy k8s jetbrains apps ssh langs tweaks)   # cuda hors défaut

usage() {
    cat <<EOF
${SCRIPT_NAME} — installation d'un poste de dev sur Ubuntu 26.04 LTS

Usage :
  ${SCRIPT_NAME} [options]

Options :
  --all               installe tous les modules (cuda compris)
  --only a,b,c        installe uniquement ces modules
  --skip a,b,c        installe les modules par défaut sauf ceux-ci
  --list              liste les modules et sort
  --dry-run           affiche les actions sans rien exécuter
  -y, --yes           ne pose aucune question
  -h, --help          cette aide

Par défaut : ${DEFAULT_MODULES[*]}
EOF
}

list_modules() {
    printf '%sModules disponibles :%s\n' "$C_BLUE" "$C_RESET"
    local m desc
    for m in "${ALL_MODULES[@]}"; do
        desc="mod_${m}_desc"
        printf '  %-11s %s\n' "$m" "${!desc}"
    done
    printf '\nDéfaut : %s\n' "${DEFAULT_MODULES[*]}"
}

main() {
    local selected=() only="" skipl=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)      selected=("${ALL_MODULES[@]}") ;;
            --only)     only="${2:-}"; shift ;;
            --only=*)   only="${1#*=}" ;;
            --skip)     skipl="${2:-}"; shift ;;
            --skip=*)   skipl="${1#*=}" ;;
            --list)     list_modules; exit 0 ;;
            --dry-run)  DRY_RUN=1 ;;
            -y|--yes)   ASSUME_YES=1 ;;
            -h|--help)  usage; exit 0 ;;
            *)          err "option inconnue : $1"; usage; exit 1 ;;
        esac
        shift
    done

    require_not_root
    require_ubuntu
    detect_arch

    if [[ -n "$only" ]]; then
        IFS=',' read -r -a selected <<< "$only"
    elif [[ ${#selected[@]} -eq 0 ]]; then
        selected=("${DEFAULT_MODULES[@]}")
    fi

    if [[ -n "$skipl" ]]; then
        local keep=() s m drop
        IFS=',' read -r -a s <<< "$skipl"
        for m in "${selected[@]}"; do
            drop=0
            for x in "${s[@]}"; do [[ "$m" == "$x" ]] && drop=1; done
            (( drop )) || keep+=("$m")
        done
        selected=("${keep[@]}")
    fi

    # Validation des noms de modules avant toute action.
    local m valid
    for m in "${selected[@]}"; do
        valid=0
        for a in "${ALL_MODULES[@]}"; do [[ "$m" == "$a" ]] && valid=1; done
        (( valid )) || { err "module inconnu : $m"; list_modules; exit 1; }
    done

    printf '\n%sUbuntu %s (%s) — %s%s\n' "$C_BLUE" "$OS_VERSION" "$CODENAME" "$DPKG_ARCH" "$C_RESET"
    printf 'Modules : %s\n' "${selected[*]}"
    (( DRY_RUN )) && printf '%sMode simulation — aucune modification.%s\n' "$C_YELLOW" "$C_RESET"
    printf '\n'

    if ! (( ASSUME_YES )) && ! (( DRY_RUN )); then
        read -r -p "Continuer ? [o/N] " reply
        [[ "$reply" =~ ^[oOyY]$ ]] || { echo "Annulé."; exit 0; }
    fi

    # Garde le sudo chaud pendant toute l'exécution.
    if ! (( DRY_RUN )); then
        sudo -v
        while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
        SUDO_KEEPALIVE_PID=$!
        trap 'kill "${SUDO_KEEPALIVE_PID:-}" 2>/dev/null || true' EXIT
    fi

    NEED_RELOGIN=0
    NEED_REBOOT=0
    local failed=()

    for m in "${selected[@]}"; do
        CURRENT_MODULE="$m"
        local desc="mod_${m}_desc"
        log "[$m] ${!desc}"
        if ! ( set +e; "mod_${m}" ); then
            err "module '$m' en échec — on continue avec les suivants."
            failed+=("$m")
        fi
        printf '\n'
    done

    CURRENT_MODULE="résumé"
    run sudo apt-get autoremove -y >/dev/null 2>&1 || true

    printf '%s──────────────────────────────────────────────%s\n' "$C_BLUE" "$C_RESET"
    if [[ ${#failed[@]} -gt 0 ]]; then
        err "modules en échec : ${failed[*]}"
    else
        ok "tous les modules sont passés."
    fi
    (( NEED_RELOGIN )) && warn "déconnecte/reconnecte-toi (ou 'newgrp docker') pour le groupe docker."
    (( NEED_REBOOT ))  && warn "redémarre la machine pour charger le pilote NVIDIA."
    printf '\nVérifications rapides :\n'
    printf '  docker run --rm hello-world\n'
    printf '  lazygit --version && lazydocker --version\n'
    printf '  kubectl version --client && helm version --short && k9s version -s\n'
    printf '  phpstorm & pycharm      # activation licence au 1er lancement\n'
    printf '  code --version && postman\n'
    printf '  nvidia-smi && nvcc --version\n\n'
}

main "$@"
