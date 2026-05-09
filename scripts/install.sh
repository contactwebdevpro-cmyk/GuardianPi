#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  GuardianPi — Script d'installation automatique
#  Routeur parental intelligent pour Raspberry Pi 3B
#  Installation avec barre de progression temps réel
#  Usage:
#     curl -sSL https://raw.githubusercontent.com/votre-repo/guardianpi/main/install.sh | sudo bash
# ══════════════════════════════════════════════════════════════════

set -euo pipefail

# ─────────────────────────────────────────────────────────────────
#  COULEURS
# ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────────
#  VARIABLES
# ─────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/guardianpi"
DATA_DIR="/etc/guardianpi/data"
LOG_FILE="/var/log/guardianpi-install.log"
PYTHON_MIN="3.9"
PI_USER="${SUDO_USER:-pi}"
REPO_URL="https://github.com/contactwebdevpro-cmyk/GuardianPi.git"

TOTAL_STEPS=11
CURRENT_STEP=0
START_TIME=$(date +%s)

# ─────────────────────────────────────────────────────────────────
#  UI
# ─────────────────────────────────────────────────────────────────

clear

echo -e "${PURPLE}"
cat << 'EOF'
  ____                     _ _             ____  _
 / ___|_   _  __ _ _ __ __| (_) __ _ _ __ |  _ \(_)
| |  _| | | |/ _` | '__/ _` | |/ _` | '_ \| |_) | |
| |_| | |_| | (_| | | | (_| | | (_| | | | |  __/| |
 \____|\__,_|\__,_|_|  \__,_|_|\__,_|_| |_|_|   |_|

EOF

echo -e "${WHITE}        GuardianPi — Routeur parental intelligent${NC}"
echo -e "${CYAN}        Installation automatisée temps réel${NC}"
echo ""
echo -e "${YELLOW}⚠️  Ne fermez pas cette fenêtre pendant l'installation${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
    echo -e "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $(echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOG_FILE"
}

# ─────────────────────────────────────────────────────────────────
#  BARRE DE PROGRESSION
# ─────────────────────────────────────────────────────────────────

draw_progress() {
    local percent=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    local filled=$((percent / 2))
    local empty=$((50 - filled))

    printf "\n${BLUE}["
    printf "%0.s█" $(seq 1 $filled)
    printf "%0.s░" $(seq 1 $empty)
    printf "]${NC} ${WHITE}%d%%${NC}" "$percent"

    printf " ${GRAY}(%d/%d étapes)${NC}\n" "$CURRENT_STEP" "$TOTAL_STEPS"
}

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))

    clear

    echo -e "${PURPLE}"
    cat << 'EOF'
  ____                     _ _             ____  _
 / ___|_   _  __ _ _ __ __| (_) __ _ _ __ |  _ \(_)
| |  _| | | |/ _` | '__/ _` | |/ _` | '_ \| |_) | |
| |_| | |_| | (_| | | | (_| | | (_| | | | |  __/| |
 \____|\__,_|\__,_|_|  \__,_|_|\__,_|_| |_|_|   |_|

EOF
    echo -e "${NC}"

    draw_progress

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}▶ $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

spinner() {
    local pid=$1
    local delay=0.08
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

    while ps a | awk '{print $1}' | grep -q "$pid"; do
        local temp=${spinstr#?}
        printf " ${CYAN}[%c]${NC} " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done

    printf "    \b\b\b\b"
}

run_cmd() {
    local msg="$1"
    shift

    printf "${CYAN}→${NC} %s... " "$msg"

    (
        "$@"
    ) >> "$LOG_FILE" 2>&1 &

    local pid=$!

    spinner $pid
    wait $pid

    local status=$?

    if [[ $status -eq 0 ]]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        echo ""
        echo -e "${RED}Erreur pendant: $msg${NC}"
        echo -e "${YELLOW}Voir logs:${NC} $LOG_FILE"
        exit 1
    fi
}

ok() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

info() {
    echo -e "${CYAN}→${NC} $1"
}

# ─────────────────────────────────────────────────────────────────
#  VÉRIFICATIONS
# ─────────────────────────────────────────────────────────────────

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Lancez ce script avec sudo${NC}"
        echo ""
        echo "sudo bash install.sh"
        exit 1
    fi

    ok "Permissions root validées"
}

check_pi() {
    if grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        DEVMODE=false
        ok "Raspberry Pi détecté"
    else
        DEVMODE=true
        warn "Raspberry Pi non détecté — mode développement"
    fi
}

check_internet() {
    printf "${CYAN}→${NC} Vérification connexion internet... "

    if ping -c 1 8.8.8.8 &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        exit 1
    fi
}

check_os() {
    if [[ -f /etc/debian_version ]]; then
        ok "OS Debian/Raspberry Pi OS détecté"
    else
        warn "OS non Debian détecté"
    fi
}

# ─────────────────────────────────────────────────────────────────
#  INSTALLATION PAQUETS
# ─────────────────────────────────────────────────────────────────

install_system_packages() {

    step "📦 Installation des paquets système"

    run_cmd "Mise à jour apt" apt-get update -y

    PACKAGES=(
        python3
        python3-pip
        python3-venv
        python3-dev
        dnsmasq
        iptables
        iptables-persistent
        git
        curl
        wget
        nmap
        net-tools
        iproute2
        procps
        build-essential
    )

    info "Paquets:"
    printf "   "

    for p in "${PACKAGES[@]}"; do
        printf "${WHITE}%s${NC} " "$p"
    done

    echo ""
    echo ""

    run_cmd "Installation des paquets" apt-get install -y "${PACKAGES[@]}"

    PYTHON_VERSION=$(python3 --version 2>/dev/null || true)

    ok "Python installé: $PYTHON_VERSION"
    ok "Paquets système installés"
}

# ─────────────────────────────────────────────────────────────────
#  DÉTECTION RÉSEAU
# ─────────────────────────────────────────────────────────────────

detect_network_interfaces() {

    step "🌐 Détection des interfaces réseau"

    WAN_IF=$(ip route | grep default | awk '{print $5}' | head -1)
    WAN_IF="${WAN_IF:-eth0}"

    LAN_IF=$(ip link show \
        | grep -v lo \
        | grep -v "$WAN_IF" \
        | awk -F': ' '{print $2}' \
        | head -1 \
        | tr -d '@.*')

    LAN_IF="${LAN_IF:-wlan0}"

    LOCAL_IP=$(hostname -I | awk '{print $1}')

    echo -e "${WHITE}Interface WAN:${NC} $WAN_IF"
    echo -e "${WHITE}Interface LAN:${NC} $LAN_IF"
    echo -e "${WHITE}IP Locale:${NC}      $LOCAL_IP"

    export WAN_IF LAN_IF LOCAL_IP

    ok "Interfaces réseau détectées"

    sleep 2
}

# ─────────────────────────────────────────────────────────────────
#  INSTALLATION GUARDIANPI
# ─────────────────────────────────────────────────────────────────

install_guardianpi() {

    step "📥 Installation de GuardianPi"

    run_cmd "Création dossiers" mkdir -p \
        "$INSTALL_DIR" \
        "$DATA_DIR" \
        /etc/guardianpi \
        /etc/iptables

    if [[ -d "$INSTALL_DIR/.git" ]]; then
        info "Mise à jour dépôt existant"

        run_cmd "Git pull" bash -c "
            cd '$INSTALL_DIR'
            git pull origin main
        "
    else
        info "Téléchargement GuardianPi"

        if [[ -d /tmp/guardianpi-src ]]; then
            run_cmd "Copie fichiers locaux" bash -c "
                cp -r /tmp/guardianpi-src/* '$INSTALL_DIR/'
            "
        else
            run_cmd "Clonage GitHub" git clone "$REPO_URL" "$INSTALL_DIR"
        fi
    fi

    ok "GuardianPi installé"
}

# ─────────────────────────────────────────────────────────────────
#  PYTHON
# ─────────────────────────────────────────────────────────────────

setup_python_env() {

    step "🐍 Configuration Python"

    VENV_DIR="$INSTALL_DIR/venv"

    run_cmd "Création venv" python3 -m venv "$VENV_DIR"

    run_cmd "Mise à jour pip" \
        "$VENV_DIR/bin/pip" install --upgrade pip wheel setuptools

    run_cmd "Installation dépendances Python" \
        "$VENV_DIR/bin/pip" install \
        fastapi \
        uvicorn \
        pydantic \
        python-multipart

    ok "Environnement Python prêt"
}

# ─────────────────────────────────────────────────────────────────
#  DNSMASQ
# ─────────────────────────────────────────────────────────────────

configure_dnsmasq() {

    step "🔍 Configuration DNS"

    [[ -f /etc/dnsmasq.conf ]] && \
        cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup

    cat > /etc/dnsmasq.conf << EOF
# GuardianPi — dnsmasq configuration

port=53
domain-needed
bogus-priv
no-resolv

server=1.1.1.1
server=8.8.8.8
server=9.9.9.9

cache-size=1000
neg-ttl=60

conf-file=/etc/guardianpi/blocked_domains.conf

interface=$LAN_IF
bind-interfaces

dhcp-range=192.168.100.100,192.168.100.200,12h
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,192.168.100.1

dhcp-leasefile=/var/lib/misc/dnsmasq.leases
EOF

    touch /etc/guardianpi/blocked_domains.conf

    if systemctl is-active systemd-resolved &>/dev/null; then

        info "Désactivation systemd-resolved"

        run_cmd "Stop systemd-resolved" \
            systemctl stop systemd-resolved

        run_cmd "Disable systemd-resolved" \
            systemctl disable systemd-resolved

        rm -f /etc/resolv.conf

        echo "nameserver 1.1.1.1" > /etc/resolv.conf
        echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    fi

    run_cmd "Activation dnsmasq" systemctl enable dnsmasq
    run_cmd "Redémarrage dnsmasq" systemctl restart dnsmasq

    ok "DNS configuré"
}

# ─────────────────────────────────────────────────────────────────
#  GATEWAY
# ─────────────────────────────────────────────────────────────────

configure_network_gateway() {

    step "🔀 Configuration passerelle"

    run_cmd "Activation IP forwarding" \
        sysctl -w net.ipv4.ip_forward=1

    echo "net.ipv4.ip_forward=1" > \
        /etc/sysctl.d/99-guardianpi.conf

    if [[ "$DEVMODE" == "false" ]]; then

        run_cmd "Configuration NAT" bash -c "
            iptables -t nat -F POSTROUTING
            iptables -t nat -A POSTROUTING -o '$WAN_IF' -j MASQUERADE
            iptables -F FORWARD
            iptables -P FORWARD ACCEPT
            iptables-save > /etc/iptables/rules.v4
        "

        ok "Mode routeur activé"

    else
        warn "Mode développement — NAT ignoré"
    fi
}

# ─────────────────────────────────────────────────────────────────
#  CONFIG
# ─────────────────────────────────────────────────────────────────

create_config() {

    step "⚙️ Création configuration"

    cat > "$DATA_DIR/config.json" << EOF
{
  "username": "admin",
  "password_hash": "$(echo -n 'guardianpi' | sha256sum | cut -d' ' -f1)",
  "setup_done": true,
  "interface_wan": "$WAN_IF",
  "interface_lan": "$LAN_IF",
  "global_pause": false,
  "version": "1.0.0",
  "install_date": "$(date -Iseconds)"
}
EOF

    echo "[]" > "$DATA_DIR/rules.json"
    echo "[]" > "$DATA_DIR/schedules.json"
    echo "{}" > "$DATA_DIR/devices.json"
    echo "{}" > "$DATA_DIR/tokens.json"

    chown -R root:root /etc/guardianpi
    chmod -R 700 /etc/guardianpi

    ok "Configuration générée"
}

# ─────────────────────────────────────────────────────────────────
#  SYSTEMD
# ─────────────────────────────────────────────────────────────────

create_systemd_service() {

    step "🔧 Création service GuardianPi"

    cat > /etc/systemd/system/guardianpi.service << EOF
[Unit]
Description=GuardianPi — Routeur Parental Intelligent
After=network.target dnsmasq.service
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/backend
ExecStart=$INSTALL_DIR/venv/bin/python main.py
Restart=always
RestartSec=5

Environment=PYTHONUNBUFFERED=1
Environment=GUARDIANPI_ENV=production

MemoryLimit=256M
CPUQuota=80%

[Install]
WantedBy=multi-user.target
EOF

    run_cmd "Reload systemd" systemctl daemon-reload
    run_cmd "Enable GuardianPi" systemctl enable guardianpi
    run_cmd "Start GuardianPi" systemctl start guardianpi

    sleep 2

    if systemctl is-active guardianpi &>/dev/null; then
        ok "Service GuardianPi actif"
    else
        warn "Service non démarré"
    fi
}

# ─────────────────────────────────────────────────────────────────
#  RESTORE IPTABLES
# ─────────────────────────────────────────────────────────────────

create_restore_service() {

    step "🔄 Service restauration"

    cat > /etc/systemd/system/guardianpi-restore.service << EOF
[Unit]
Description=GuardianPi Restore IPTables
Before=guardianpi.service
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    run_cmd "Enable restore service" \
        systemctl enable guardianpi-restore

    ok "Restauration auto activée"
}

# ─────────────────────────────────────────────────────────────────
#  FIREWALL
# ─────────────────────────────────────────────────────────────────

setup_firewall() {

    step "🔒 Configuration firewall"

    if [[ "$DEVMODE" == "false" ]]; then

        run_cmd "Configuration firewall" bash -c "
            iptables -A INPUT -p tcp --dport 22 -j ACCEPT || true
            iptables -A INPUT -p tcp --dport 8080 -j ACCEPT || true
            iptables -A INPUT -p udp --dport 53 -j ACCEPT || true
            iptables -A INPUT -p tcp --dport 53 -j ACCEPT || true
            iptables -A INPUT -p udp --dport 67 -j ACCEPT || true
            iptables -A INPUT -i lo -j ACCEPT || true
            iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT || true
            iptables-save > /etc/iptables/rules.v4
        "
    fi

    ok "Firewall configuré"
}

# ─────────────────────────────────────────────────────────────────
#  FIN
# ─────────────────────────────────────────────────────────────────

print_success() {

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    CURRENT_STEP=$TOTAL_STEPS

    clear

    draw_progress

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✅ GuardianPi installé avec succès              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"

    echo ""
    echo -e "${WHITE}🌐 Dashboard:${NC}"
    echo -e "   ${CYAN}http://$LOCAL_IP:8080${NC}"

    echo ""
    echo -e "${WHITE}🔐 Connexion:${NC}"
    echo -e "   Utilisateur : ${CYAN}admin${NC}"
    echo -e "   Mot de passe : ${CYAN}guardianpi${NC}"

    echo ""
    echo -e "${WHITE}⏱ Temps total:${NC} ${CYAN}${DURATION}s${NC}"

    echo ""
    echo -e "${WHITE}📂 Logs:${NC}"
    echo -e "   ${CYAN}$LOG_FILE${NC}"

    echo ""
    echo -e "${WHITE}🔧 Commandes utiles:${NC}"
    echo -e "   ${CYAN}systemctl status guardianpi${NC}"
    echo -e "   ${CYAN}journalctl -u guardianpi -f${NC}"
    echo -e "   ${CYAN}systemctl restart guardianpi${NC}"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────

main() {

    exec > >(tee -a "$LOG_FILE") 2>&1

    echo -e "${CYAN}Installation démarrée: $(date)${NC}"
    echo ""

    check_root
    check_pi
    check_internet
    check_os

    sleep 1

    install_system_packages
    detect_network_interfaces
    install_guardianpi
    setup_python_env
    configure_dnsmasq
    configure_network_gateway
    create_config
    create_systemd_service
    create_restore_service
    setup_firewall

    print_success
}

main "$@"
