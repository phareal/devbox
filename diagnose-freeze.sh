#!/usr/bin/env bash
#
# diagnose-freeze.sh — isoler la cause d'un gel de session i3.
#
#   ./diagnose-freeze.sh                 # collecte un rapport dans /tmp
#   ./diagnose-freeze.sh --safe          # config i3 minimale : rien n'est lancé
#   ./diagnose-freeze.sh --enable picom  # réactive un composant, un par un
#   ./diagnose-freeze.sh --restore       # remet la config d'origine
#
# Méthode : passer en mode sûr, vérifier que le gel disparaît, puis réactiver
# un composant à la fois jusqu'à ce qu'il revienne. Le dernier réactivé est le
# coupable. C'est plus long qu'une intuition, mais ça conclut.
#
set -Eeuo pipefail

CFG="${HOME}/.config/i3/config"
BAK="${CFG}.before-safe"
REPORT="/tmp/i3-freeze-report.txt"

# Composants lancés par la config i3, réactivables un par un.
COMPONENTS=(picom polybar gnome-screensaver xss-lock gsd wallpaper dunst)

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'
else
    C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  ! %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
err()  { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }

# Motif des lignes exec correspondant à un composant. Sans préfixe "exec",
# celui-ci étant déjà posé par la regex qui consomme ces motifs.
pattern_for() {
    case "$1" in
        picom)             printf 'picom' ;;
        polybar)           printf 'polybar/colorblocks/launch.sh' ;;
        gnome-screensaver) printf 'gnome-screensaver' ;;
        xss-lock)          printf 'xss-lock' ;;
        gsd)               printf '/usr/libexec/gsd-' ;;
        wallpaper)         printf 'devsetup-wallpaper' ;;
        dunst)             printf 'dunst' ;;
        *)                 return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Rapport
# ---------------------------------------------------------------------------
do_report() {
    : >"$REPORT"
    exec 3>&1 1>>"$REPORT"

    echo "===== Système ====="
    { uname -a; . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"; } 2>&1
    echo "virtualisation : $(systemd-detect-virt 2>/dev/null || echo inconnue)"

    echo; echo "===== Carte graphique et pilote ====="
    lspci -nnk 2>/dev/null | grep -A3 -iE 'vga|3d|display' || echo "lspci indisponible"
    echo "-- glxinfo --"
    glxinfo -B 2>/dev/null | grep -iE 'vendor|renderer|version' || echo "glxinfo absent (paquet mesa-utils)"

    echo; echo "===== Session ====="
    echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-?}  DESKTOP_SESSION=${DESKTOP_SESSION:-?}"
    loginctl show-session "$(loginctl 2>/dev/null | awk -v u="$USER" '$3==u{print $1; exit}')" \
        -p Type -p Active -p Remote 2>/dev/null || true

    echo; echo "===== Erreurs du boot PRÉCÉDENT (celui qui a gelé) ====="
    journalctl -b -1 -p err --no-pager 2>/dev/null | tail -60 || echo "journal du boot précédent indisponible"

    echo; echo "===== Fin du boot précédent (30 dernières lignes) ====="
    journalctl -b -1 --no-pager 2>/dev/null | tail -30 || true

    echo; echo "===== OOM / kernel ====="
    journalctl -b -1 -k --no-pager 2>/dev/null | grep -iE 'oom|killed process|gpu hang|drm|fault|panic' | tail -30 \
        || echo "rien de notable"

    echo; echo "===== Xorg ====="
    for f in "${HOME}/.local/share/xorg/Xorg.0.log.old" "${HOME}/.local/share/xorg/Xorg.0.log" \
             /var/log/Xorg.0.log.old /var/log/Xorg.0.log; do
        [[ -r "$f" ]] || continue
        echo "-- $f --"
        grep -iE '\(EE\)|\(WW\).*(glx|dri|nvidia)' "$f" | tail -20
        break
    done

    echo; echo "===== picom ====="
    grep -E '^backend|^vsync|^corner-radius' "${HOME}/.config/picom.conf" 2>/dev/null || echo "pas de picom.conf"

    echo; echo "===== polybar ====="
    tail -20 "/tmp/polybar-${USER}.log" 2>/dev/null || echo "pas de log polybar"

    echo; echo "===== Composants lancés par i3 ====="
    grep -nE '^\s*exec' "$CFG" 2>/dev/null || echo "pas de config i3"

    exec 1>&3 3>&-
    ok "rapport écrit : ${REPORT}"
    log "envoie ce fichier, ou colle :  cat ${REPORT}"
}

# ---------------------------------------------------------------------------
# Mode sûr
# ---------------------------------------------------------------------------
do_safe() {
    [[ -f "$CFG" ]] || { err "config i3 introuvable : ${CFG}"; exit 1; }

    if [[ ! -f "$BAK" ]]; then
        cp "$CFG" "$BAK"
        ok "config d'origine sauvegardée : ${BAK}"
    else
        warn "sauvegarde déjà présente, conservée : ${BAK}"
    fi

    # Commente toute ligne exec lançant un des composants surveillés.
    local c pat n=0
    for c in "${COMPONENTS[@]}"; do
        pat=$(pattern_for "$c")
        while IFS= read -r line; do
            [[ -n "$line" ]] && n=$((n + 1))
        done < <(grep -nE "^\s*exec.*$(printf '%s' "$pat" | sed 's/[][\.*^$/]/\\&/g')" "$CFG" || true)
        sed -i "\|^[[:space:]]*exec.*${pat//|/\\|}|s|^|# devsetup-safe |" "$CFG" 2>/dev/null || true
    done

    ok "${n} ligne(s) de démarrage désactivée(s)"
    log "recharge i3 (Super+Shift+r) ou rouvre la session, puis observe."
    log "si le gel disparaît :  ./diagnose-freeze.sh --enable <composant>"
    printf '   composants : %s\n' "${COMPONENTS[*]}"
}

do_enable() {
    local c="$1" pat
    pat=$(pattern_for "$c") || { err "composant inconnu : ${c}"; printf '   %s\n' "${COMPONENTS[*]}"; exit 1; }
    [[ -f "$CFG" ]] || { err "config i3 introuvable"; exit 1; }

    sed -i "\|^# devsetup-safe .*${pat//|/\\|}|s|^# devsetup-safe ||" "$CFG"
    ok "${c} réactivé"
    log "recharge i3 (Super+Shift+r). Si le gel revient, ${c} est le coupable."
}

do_restore() {
    [[ -f "$BAK" ]] || { err "aucune sauvegarde : ${BAK}"; exit 1; }
    cp "$BAK" "$CFG"
    ok "config i3 restaurée depuis ${BAK}"
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    ""|--report) do_report ;;
    --safe)      do_safe ;;
    --enable)    do_enable "${2:-}" ;;
    --restore)   do_restore ;;
    -h|--help)
        sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)
        err "option inconnue : $1"
        sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
        exit 1 ;;
esac
