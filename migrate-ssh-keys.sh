#!/usr/bin/env bash
#
# migrate-ssh-keys.sh — transfert de ~/.ssh d'une machine à l'autre, chiffré.
#
#   Sur l'ancienne machine (macOS ou Linux) :
#       ./migrate-ssh-keys.sh --export -o ~/ssh-backup
#
#   Transport MANUEL de l'archive : clé USB, ou
#       scp ~/ssh-backup.tar.gz.gpg user@nouvelle-machine:~/
#
#   Sur la nouvelle machine (Ubuntu) :
#       ./migrate-ssh-keys.sh --import ~/ssh-backup.tar.gz.gpg
#
# L'archive est TOUJOURS chiffrée par une passphrase que toi seul connais.
# Elle ne doit jamais transiter par un dépôt git, un chat, un drive, un mail.
#
set -Eeuo pipefail
umask 077          # tout ce que ce script crée est privé dès la création

SCRIPT_NAME=$(basename "$0")
SSH_DIR="${HOME}/.ssh"
FORCE=0
PASS_FILE=""
PASSPHRASE=""

# Espace de travail temporaire. Global et nettoyé par un trap unique : un trap
# posé dans une fonction survit à son `local`, et référencerait une variable
# détruite au moment de l'EXIT.
TMP_WORK=""
cleanup() {
    PASSPHRASE=""
    [[ -n "$TMP_WORK" && -d "$TMP_WORK" ]] && rm -rf "$TMP_WORK"
    return 0
}
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
  --passphrase-file F     lit la passphrase dans le fichier F (1re ligne)
                          à utiliser quand aucun terminal n'est disponible
  -h, --help              cette aide

Passphrase : demandée sur le terminal. Sans terminal, utilise
--passphrase-file, ou la variable d'environnement SSH_MIGRATE_PASSPHRASE.

Chiffrement : gpg si disponible, sinon openssl (AES-256, PBKDF2 600k).
L'extension indique l'outil : .gpg / .enc  (.age est accepté à l'import).
EOF
}

# ---------------------------------------------------------------------------
# Passphrase
# ---------------------------------------------------------------------------
# Lue par le script, jamais par pinentry : gpg exige un tty pour son agent, ce
# qui casse dès qu'on tourne dans un shell non interactif. On la transmet
# ensuite aux outils par descripteur de fichier — jamais en argument de ligne
# de commande, qui serait visible dans la table des processus.
read_passphrase() {
    local confirm="$1" p1="" p2=""

    if [[ -n "$PASS_FILE" ]]; then
        [[ -r "$PASS_FILE" ]] || { err "fichier de passphrase illisible : ${PASS_FILE}"; exit 1; }
        IFS= read -r p1 < "$PASS_FILE" || true
        [[ -n "$p1" ]] || { err "fichier de passphrase vide : ${PASS_FILE}"; exit 1; }
        PASSPHRASE="$p1"
        warn "passphrase lue depuis ${PASS_FILE} — détruis ce fichier ensuite."
        return 0
    fi

    if [[ -n "${SSH_MIGRATE_PASSPHRASE:-}" ]]; then
        PASSPHRASE="$SSH_MIGRATE_PASSPHRASE"
        warn "passphrase lue dans SSH_MIGRATE_PASSPHRASE (visible dans l'historique du shell)."
        return 0
    fi

    if [[ ! -r /dev/tty ]]; then
        err "aucun terminal disponible pour saisir la passphrase."
        err "Lance ce script dans un vrai terminal, ou utilise :"
        err "  --passphrase-file /chemin/vers/fichier"
        err "  SSH_MIGRATE_PASSPHRASE='...' ${SCRIPT_NAME} ..."
        exit 1
    fi

    printf 'Passphrase : ' >/dev/tty
    IFS= read -rs p1 </dev/tty; printf '\n' >/dev/tty
    [[ -n "$p1" ]] || { err "passphrase vide."; exit 1; }

    if (( confirm )); then
        printf 'Confirme   : ' >/dev/tty
        IFS= read -rs p2 </dev/tty; printf '\n' >/dev/tty
        [[ "$p1" == "$p2" ]] || { err "les deux saisies diffèrent."; exit 1; }
        if [[ ${#p1} -lt 12 ]]; then
            warn "passphrase de ${#p1} caractères — c'est la SEULE protection de tes"
            warn "clés privées pendant le transport. Vise au moins 12 caractères."
        fi
    fi
    PASSPHRASE="$p1"
}

# Chiffre $1 vers $2. La passphrase passe par le fd 3, pas par argv.
encrypt_file() {
    local in="$1" out="$2"
    if have gpg; then
        printf '%s' "$PASSPHRASE" | \
        gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 0 \
            --symmetric --cipher-algo AES256 --s2k-digest-algo SHA512 \
            --s2k-count 65011712 --output "$out" "$in"
    elif have openssl; then
        exec 3<<<"$PASSPHRASE"
        openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
            -pass fd:3 -in "$in" -out "$out"
        exec 3<&-
    else
        err "ni gpg ni openssl — refus d'écrire une archive de clés privées en clair."
        exit 1
    fi
}

# Déchiffre $1 vers $2, selon l'extension.
decrypt_file() {
    local in="$1" out="$2"
    case "$in" in
        *.gpg)
            have gpg || { err "gpg requis pour cette archive."; exit 1; }
            printf '%s' "$PASSPHRASE" | \
            gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 0 \
                --output "$out" --decrypt "$in" ;;
        *.enc)
            have openssl || { err "openssl requis pour cette archive."; exit 1; }
            exec 3<<<"$PASSPHRASE"
            openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
                -pass fd:3 -in "$in" -out "$out"
            exec 3<&- ;;
        *.age)
            have age || { err "age requis pour cette archive."; exit 1; }
            age --decrypt -o "$out" "$in" ;;
        *)
            err "extension non reconnue : attendu .gpg, .enc ou .age"
            exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
do_export() {
    local prefix="$1"

    [[ -d "$SSH_DIR" ]] || { err "${SSH_DIR} introuvable."; exit 1; }

    TMP_WORK=$(mktemp -d)
    chmod 700 "$TMP_WORK"
    local stage="${TMP_WORK}/.ssh"
    mkdir -p "$stage"

    # On copie explicitement les fichiers RÉGULIERS de premier niveau. ~/.ssh
    # contient souvent un dossier agent/ avec des sockets, que tar refuse
    # d'archiver ("cannot archive sockets") — et qui n'a aucun intérêt ici.
    log "fichiers de ${SSH_DIR} retenus :"
    local n=0 f
    while IFS= read -r f; do
        cp -p "$f" "$stage/"
        dim "$(basename "$f")"
        n=$((n + 1))
    done < <(find "$SSH_DIR" -maxdepth 1 -type f ! -name '.DS_Store' | sort)
    [[ $n -gt 0 ]] || { err "aucun fichier régulier à archiver."; exit 1; }

    # Signale ce qui est volontairement laissé de côté.
    local extra
    extra=$(find "$SSH_DIR" -maxdepth 1 -mindepth 1 ! -type f ! -name '.DS_Store' 2>/dev/null | sort || true)
    if [[ -n "$extra" ]]; then
        printf '\n'
        warn "ignoré (dossiers, sockets, liens) :"
        while IFS= read -r f; do warn "  $(basename "$f")"; done <<<"$extra"
    fi
    printf '\n'

    local tarball="${TMP_WORK}/ssh.tar.gz"
    tar -czf "$tarball" -C "$TMP_WORK" .ssh

    read_passphrase 1

    local out
    if have gpg; then out="${prefix}.tar.gz.gpg"; else out="${prefix}.tar.gz.enc"; fi
    log "chiffrement…"
    encrypt_file "$tarball" "$out"
    chmod 600 "$out"

    # Une archive qu'on ne sait pas rouvrir ne vaut rien : on vérifie tout de
    # suite qu'elle se déchiffre et que le tar est intact.
    local check="${TMP_WORK}/verify.tar.gz"
    decrypt_file "$out" "$check"
    tar -tzf "$check" >/dev/null
    ok "archive vérifiée (déchiffrement + intégrité de l'archive)"
    ok "archive chiffrée : ${out}  ($(wc -c <"$out" | tr -d ' ') octets, ${n} fichiers)"

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
        *.age) : ;;                     # age gère sa propre saisie
        *)     read_passphrase 0 ;;
    esac

    log "déchiffrement…"
    decrypt_file "$archive" "$tarball"

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
            --export)            mode="export" ;;
            --import)            mode="import"; archive="${2:-}"; shift ;;
            -o)                  prefix="${2:-}"; shift ;;
            -o=*)                prefix="${1#*=}" ;;
            --force)             FORCE=1 ;;
            --passphrase-file)   PASS_FILE="${2:-}"; shift ;;
            --passphrase-file=*) PASS_FILE="${1#*=}" ;;
            -h|--help)           usage; exit 0 ;;
            *)                   err "option inconnue : $1"; usage; exit 1 ;;
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
