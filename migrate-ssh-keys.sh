#!/usr/bin/env bash
#
# migrate-ssh-keys.sh — transfert de ~/.ssh d'une machine à l'autre, chiffré.
#
#   Sur l'ancienne machine (macOS ou Linux) :
#       ./migrate-ssh-keys.sh --export -o ~/ssh-backup
#
#   Transport MANUEL de l'archive : clé USB, ou
#       scp ~/ssh-backup.tar.gz.age user@nouvelle-machine:~/
#
#   Sur la nouvelle machine (Ubuntu) :
#       ./migrate-ssh-keys.sh --import ~/ssh-backup.tar.gz.age
#
# L'archive est TOUJOURS chiffrée par une passphrase que toi seul connais.
# Elle ne doit jamais transiter par un dépôt git, un chat, un drive, un mail.
#
set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
SSH_DIR="${HOME}/.ssh"
FORCE=0

# Espace de travail temporaire. Global et nettoyé par un trap unique : un trap
# posé dans une fonction survit à son `local`, et référencerait une variable
# détruite au moment de l'EXIT.
TMP_WORK=""
cleanup() { [[ -n "$TMP_WORK" && -d "$TMP_WORK" ]] && rm -rf "$TMP_WORK"; return 0; }
trap cleanup EXIT

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'
else
    C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  ! %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
err()  { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
dim()  { printf '%s  · %s%s\n' "$C_DIM" "$*" "$C_RESET"; }

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<EOF
${SCRIPT_NAME} — migration chiffrée de ~/.ssh

  --export [-o PREFIXE]   crée une archive chiffrée de ~/.ssh
                          (défaut : ~/ssh-backup-<hôte>-<date>)
  --import ARCHIVE        restaure une archive dans ~/.ssh
  --force                 à l'import, écrase les fichiers existants
  -h, --help              cette aide

Chiffrement : age si disponible, sinon gpg, sinon openssl (AES-256 + PBKDF2).
L'extension de l'archive indique l'outil : .age / .gpg / .enc
EOF
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
do_export() {
    local prefix="$1"

    [[ -d "$SSH_DIR" ]] || { err "${SSH_DIR} introuvable."; exit 1; }

    log "contenu de ${SSH_DIR} qui sera archivé :"
    local n=0
    while IFS= read -r f; do
        dim "$(basename "$f")"
        n=$((n + 1))
    done < <(find "$SSH_DIR" -maxdepth 1 -type f ! -name '.DS_Store' | sort)
    [[ $n -gt 0 ]] || { err "aucun fichier à archiver."; exit 1; }
    printf '\n'

    TMP_WORK=$(mktemp -d)
    chmod 700 "$TMP_WORK"
    local tarball="${TMP_WORK}/ssh.tar.gz"

    # --exclude .DS_Store : bruit macOS. On préserve les permissions.
    tar -czf "$tarball" -C "$HOME" --exclude '.DS_Store' .ssh

    local out
    if have age; then
        out="${prefix}.tar.gz.age"
        log "chiffrement avec age (passphrase demandée deux fois)…"
        age --passphrase -o "$out" "$tarball"
    elif have gpg; then
        out="${prefix}.tar.gz.gpg"
        log "chiffrement avec gpg (passphrase demandée)…"
        gpg --symmetric --cipher-algo AES256 --s2k-digest-algo SHA512 \
            --output "$out" "$tarball"
    elif have openssl; then
        out="${prefix}.tar.gz.enc"
        log "chiffrement avec openssl AES-256 (passphrase demandée)…"
        openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
            -in "$tarball" -out "$out"
    else
        err "aucun outil de chiffrement trouvé (age, gpg ou openssl requis)."
        err "Refus d'écrire une archive de clés privées en clair."
        exit 1
    fi

    chmod 600 "$out"
    ok "archive chiffrée : ${out}"

    printf '\n'
    cat <<EOT
  ── Transport ───────────────────────────────────────────────────────────────
  Cette archive contient tes clés PRIVÉES. Sa sécurité ne tient qu'à la
  passphrase que tu viens de saisir.

  À faire :   clé USB, ou  scp "${out}" user@machine:~/
  À ne pas faire : dépôt git, Drive/Dropbox, mail, Slack, chat.

  Une fois l'import terminé sur la nouvelle machine, détruis l'archive :
      shred -u "${out}"     # Linux
      rm -P "${out}"        # macOS
  ────────────────────────────────────────────────────────────────────────────
EOT
}

# ---------------------------------------------------------------------------
# Import
# ---------------------------------------------------------------------------
do_import() {
    local archive="$1"
    [[ -f "$archive" ]] || { err "archive introuvable : ${archive}"; exit 1; }

    TMP_WORK=$(mktemp -d)
    chmod 700 "$TMP_WORK"
    local tarball="${TMP_WORK}/ssh.tar.gz"

    case "$archive" in
        *.age)
            have age || { err "age requis pour déchiffrer cette archive."; exit 1; }
            log "déchiffrement (age)…"
            age --decrypt -o "$tarball" "$archive" ;;
        *.gpg)
            have gpg || { err "gpg requis pour déchiffrer cette archive."; exit 1; }
            log "déchiffrement (gpg)…"
            gpg --output "$tarball" --decrypt "$archive" ;;
        *.enc)
            have openssl || { err "openssl requis pour déchiffrer cette archive."; exit 1; }
            log "déchiffrement (openssl)…"
            openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
                -in "$archive" -out "$tarball" ;;
        *)
            err "extension non reconnue : attendu .age, .gpg ou .enc"
            exit 1 ;;
    esac

    tar -xzf "$tarball" -C "$TMP_WORK"
    [[ -d "${TMP_WORK}/.ssh" ]] || { err "archive invalide : pas de dossier .ssh dedans."; exit 1; }

    install -d -m 700 "$SSH_DIR"

    local copied=0 skipped=0 f name dest
    while IFS= read -r f; do
        name=$(basename "$f")
        dest="${SSH_DIR}/${name}"

        # known_hosts et authorized_keys se fusionnent, ils ne s'écrasent pas.
        if [[ "$name" == "known_hosts" || "$name" == "authorized_keys" ]] && [[ -f "$dest" ]]; then
            cat "$f" "$dest" | sort -u > "${dest}.merged"
            mv "${dest}.merged" "$dest"
            chmod 600 "$dest"
            ok "${name} fusionné (doublons supprimés)"
            copied=$((copied + 1))
            continue
        fi

        if [[ -f "$dest" ]] && ! (( FORCE )); then
            dim "${name} — déjà présent, conservé (--force pour écraser)"
            skipped=$((skipped + 1))
            continue
        fi

        cp -f "$f" "$dest"
        copied=$((copied + 1))
        ok "${name}"
    done < <(find "${TMP_WORK}/.ssh" -maxdepth 1 -type f ! -name '.DS_Store' | sort)

    # Permissions : OpenSSH refuse toute clé privée lisible par d'autres.
    chmod 700 "$SSH_DIR"
    find "$SSH_DIR" -maxdepth 1 -type f ! -name '*.pub' ! -name 'known_hosts*' \
         -exec chmod 600 {} + 2>/dev/null || true
    find "$SSH_DIR" -maxdepth 1 -type f -name '*.pub' -exec chmod 644 {} + 2>/dev/null || true

    printf '\n'
    ok "${copied} fichier(s) restauré(s), ${skipped} conservé(s)."
    log "vérification :"
    printf '    ssh-add -l\n'
    printf '    ssh -T git@github.com\n\n'
    warn "détruis l'archive maintenant :  shred -u \"${archive}\""
}

# ---------------------------------------------------------------------------
main() {
    local mode="" archive="" prefix=""

    [[ $# -gt 0 ]] || { usage; exit 1; }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --export)   mode="export" ;;
            --import)   mode="import"; archive="${2:-}"; shift ;;
            -o)         prefix="${2:-}"; shift ;;
            -o=*)       prefix="${1#*=}" ;;
            --force)    FORCE=1 ;;
            -h|--help)  usage; exit 0 ;;
            *)          err "option inconnue : $1"; usage; exit 1 ;;
        esac
        shift
    done

    case "$mode" in
        export)
            [[ -n "$prefix" ]] || \
                prefix="${HOME}/ssh-backup-$(hostname -s 2>/dev/null || hostname)-$(date +%Y%m%d)"
            do_export "$prefix" ;;
        import)
            [[ -n "$archive" ]] || { err "--import attend un chemin d'archive."; exit 1; }
            do_import "$archive" ;;
        *)
            err "précise --export ou --import."; usage; exit 1 ;;
    esac
}

main "$@"
