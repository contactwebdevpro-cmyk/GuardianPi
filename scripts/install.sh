#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  GuardianPi — Script d'installation automatique
#  Routeur parental intelligent pour Raspberry Pi 3B
#  Usage: curl -sSL https://raw.githubusercontent.com/votre-repo/guardianpi/main/install.sh | bash
# ══════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Couleurs ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ── Variables ──
INSTALL_DIR="/opt/guardianpi"
DATA_DIR="/etc/guardianpi/data"
LOG_FILE="/var/log/guardianpi-install.log"
PYTHON_MIN="3.9"
PI_USER="${SUDO_USER:-pi}"
REPO_URL="https://github.com/contactwebdevpro-cmyk/GuardianPi.git"

# ── Banner ──
clear
echo -e "${PURPLE}"
cat << 'EOF'
  ____                     _ _             ____  _
 / ___|_   _  __ _ _ __ __| (_) __ _ _ __ |  _ \(_)
| |  _| | | |/ _` | '__/ _` | |/ _` | '_ \| |_) | |
| |_| | |_| | (_| | | | (_| | | (_| | | | |  __/| |
 \____|\__,_|\__,_|_|  \__,_|_|\__,_|_| |_|_|   |_|

EOF
echo -e "${WHITE}  Routeur parental intelligent pour Raspberry Pi${NC}"
echo -e "${CYAN}  Version 1.0.0${NC}"
echo ""
echo -e "${YELLOW}  ⚠️  Ce script nécessite les droits root (sudo)${NC}"
echo ""

# ── Vérifications ──
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Lancez ce script avec sudo :${NC}"
        echo "   sudo bash install.sh"
        exit 1
    fi
}

check_pi() {
    if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        echo -e "${YELLOW}⚠️  Raspberry Pi non détecté — installation en mode développement${NC}"
        DEVMODE=true
    else
        DEVMODE=false
        echo -e "${GREEN}✓ Raspberry Pi détecté${NC}"
    fi
}

check_internet() {
    echo -n "  Vérification connexion internet... "
    if ping -c 1 8.8.8.8 &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗ Pas de connexion internet${NC}"
        exit 1
    fi
}

check_os() {
    if [[ -f /etc/debian_version ]]; then
        echo -e "${GREEN}✓ OS Debian/Raspberry Pi OS détecté${NC}"
    else
        echo -e "${YELLOW}⚠️  OS non Debian — certaines fonctionnalités peuvent ne pas fonctionner${NC}"
    fi
}

# ── Progress ──
step() {
    echo ""
    echo -e "${BLUE}━━━ $1 ━━━${NC}"
}

ok() { echo -e "  ${GREEN}✓${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
err() { echo -e "  ${RED}✗${NC} $1"; }

# ── Installation ──
install_system_packages() {
    step "📦 Installation des paquets système"
    
    info "Mise à jour des paquets..."
    apt-get update -qq >> "$LOG_FILE" 2>&1
    
    PACKAGES=(
        python3
        python3-pip
        python3-venv
        dnsmasq
        iptables
        iptables-persistent
        nmap
        git
        curl
        net-tools
        iproute2
        procps
    )
    
    info "Installation: ${PACKAGES[*]}"
    apt-get install -y "${PACKAGES[@]}" >> "$LOG_FILE" 2>&1
    ok "Paquets système installés"
}

detect_network_interfaces() {
    step "🌐 Détection des interfaces réseau"
    
    # Interface WAN (vers la box)
    WAN_IF=$(ip route | grep default | awk '{print $5}' | head -1)
    WAN_IF="${WAN_IF:-eth0}"
    
    # Interface LAN (WiFi ou second ethernet)
    LAN_IF=$(ip link show | grep -v lo | grep -v "$WAN_IF" | awk -F': ' '{print $2}' | head -1 | tr -d '@.*')
    LAN_IF="${LAN_IF:-wlan0}"
    
    info "Interface WAN (vers box): $WAN_IF"
    info "Interface LAN (vers appareils): $LAN_IF"
    
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    info "IP locale actuelle: $LOCAL_IP"
    
    export WAN_IF LAN_IF LOCAL_IP
    ok "Interfaces détectées"
}

install_guardianpi() {
    step "📥 Installation de GuardianPi"
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR"
    mkdir -p /etc/guardianpi
    mkdir -p /etc/iptables
    
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        info "Mise à jour du dépôt..."
        cd "$INSTALL_DIR" && git pull origin main >> "$LOG_FILE" 2>&1
    else
        info "Clonage du dépôt..."
        # Pour le dev local, on copie les fichiers
        if [[ -d /tmp/guardianpi-src ]]; then
            cp -r /tmp/guardianpi-src/* "$INSTALL_DIR/"
        else
            # Production: cloner depuis GitHub
            git clone "$REPO_URL" "$INSTALL_DIR" >> "$LOG_FILE" 2>&1 || {
                warn "Impossible de cloner — création structure minimale"
                mkdir -p "$INSTALL_DIR"/{backend,frontend/public,scripts}
            }
        fi
    fi
    ok "Fichiers installés dans $INSTALL_DIR"
}

setup_python_env() {
    step "🐍 Configuration environnement Python"
    
    VENV_DIR="$INSTALL_DIR/venv"
    
    info "Création environnement virtuel..."
    python3 -m venv "$VENV_DIR" >> "$LOG_FILE" 2>&1
    
    info "Installation des dépendances Python..."
    "$VENV_DIR/bin/pip" install --upgrade pip >> "$LOG_FILE" 2>&1
    "$VENV_DIR/bin/pip" install fastapi uvicorn pydantic python-multipart >> "$LOG_FILE" 2>&1
    
    ok "Environnement Python configuré"
}

configure_dnsmasq() {
    step "🔍 Configuration DNS (dnsmasq)"
    
    # Backup config existante
    [[ -f /etc/dnsmasq.conf ]] && cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup
    
    cat > /etc/dnsmasq.conf << EOF
# GuardianPi — dnsmasq configuration
port=53
domain-needed
bogus-priv
no-resolv

# DNS upstream (Cloudflare + Google)
server=1.1.1.1
server=8.8.8.8
server=9.9.9.9

# Cache
cache-size=1000
neg-ttl=60

# Logs (optionnel)
# log-queries
# log-facility=/var/log/dnsmasq.log

# Fichier de blocage GuardianPi
conf-file=/etc/guardianpi/blocked_domains.conf

# Réseau local
interface=$LAN_IF
bind-interfaces

# DHCP
dhcp-range=192.168.100.100,192.168.100.200,12h
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,192.168.100.1

# Leases
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
EOF

    # Fichier blocage vide
    touch /etc/guardianpi/blocked_domains.conf
    
    # Désactiver systemd-resolved si présent (conflits port 53)
    if systemctl is-active systemd-resolved &>/dev/null; then
        info "Désactivation systemd-resolved (conflit port 53)..."
        systemctl stop systemd-resolved >> "$LOG_FILE" 2>&1
        systemctl disable systemd-resolved >> "$LOG_FILE" 2>&1
        rm -f /etc/resolv.conf
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
        echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    fi
    
    systemctl enable dnsmasq >> "$LOG_FILE" 2>&1
    systemctl restart dnsmasq >> "$LOG_FILE" 2>&1 || warn "dnsmasq: vérifiez la config"
    
    ok "dnsmasq configuré"
}

configure_network_gateway() {
    step "🔀 Configuration passerelle réseau"
    
    # Activer le forwarding IP
    sysctl -w net.ipv4.ip_forward=1 >> "$LOG_FILE" 2>&1
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-guardianpi.conf
    
    if [[ "$DEVMODE" == "false" ]]; then
        # NAT masquerade
        iptables -t nat -F POSTROUTING
        iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
        
        # Forwarding par défaut
        iptables -F FORWARD
        iptables -P FORWARD ACCEPT
        
        # Sauvegarder règles
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        
        ok "Gateway NAT configuré ($LAN_IF → $WAN_IF)"
    else
        warn "Mode dev: configuration gateway ignorée"
    fi
}

create_config() {
    step "⚙️ Création configuration initiale"
    
    # Config principale
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
    
    # Fichiers vides initiaux
    echo "[]" > "$DATA_DIR/rules.json"
    echo "[]" > "$DATA_DIR/schedules.json"
    echo "{}" > "$DATA_DIR/devices.json"
    echo "{}" > "$DATA_DIR/tokens.json"
    
    chown -R root:root /etc/guardianpi
    chmod -R 700 /etc/guardianpi
    
    ok "Configuration créée"
}

create_systemd_service() {
    step "🔧 Configuration service systemd"
    
    cat > /etc/systemd/system/guardianpi.service << EOF
[Unit]
Description=GuardianPi — Routeur Parental Intelligent
Documentation=https://github.com/votre-repo/guardianpi
After=network.target dnsmasq.service
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/backend
ExecStart=$INSTALL_DIR/venv/bin/python main.py
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=guardianpi

# Environnement
Environment=PYTHONUNBUFFERED=1
Environment=GUARDIANPI_ENV=production

# Limites ressources (Raspberry Pi)
MemoryLimit=256M
CPUQuota=80%

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable guardianpi >> "$LOG_FILE" 2>&1
    systemctl start guardianpi >> "$LOG_FILE" 2>&1 || {
        warn "Service non démarré — vérifiez: journalctl -u guardianpi"
    }
    
    sleep 2
    
    if systemctl is-active guardianpi &>/dev/null; then
        ok "Service GuardianPi démarré"
    else
        warn "Service non actif — logs: journalctl -u guardianpi -n 20"
    fi
}

create_restore_service() {
    step "🔄 Service de restauration au démarrage"
    
    cat > /etc/systemd/system/guardianpi-restore.service << EOF
[Unit]
Description=GuardianPi — Restauration iptables
Before=guardianpi.service
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable guardianpi-restore >> "$LOG_FILE" 2>&1 || true
    
    ok "Service de restauration configuré"
}

setup_firewall() {
    step "🔒 Configuration firewall"
    
    # Règles de base
    if [[ "$DEVMODE" == "false" ]]; then
        # Autoriser SSH local
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
        
        # Autoriser dashboard (port 8080)
        iptables -A INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true
        
        # DNS local
        iptables -A INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        
        # DHCP
        iptables -A INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null || true
        
        # Loopback
        iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
        
        # Connexions établies
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    
    ok "Firewall configuré"
}

print_success() {
    clear
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         ✅  GuardianPi installé avec succès !             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}📍 Accédez au dashboard :${NC}"
    echo ""
    echo -e "   ${CYAN}http://$LOCAL_IP:8080${NC}"
    echo ""
    echo -e "${WHITE}🔐 Identifiants par défaut :${NC}"
    echo -e "   Utilisateur : ${CYAN}admin${NC}"
    echo -e "   Mot de passe : ${CYAN}guardianpi${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Changez le mot de passe dès la première connexion !${NC}"
    echo ""
    echo -e "${WHITE}🔧 Commandes utiles :${NC}"
    echo -e "   Status     : ${CYAN}systemctl status guardianpi${NC}"
    echo -e "   Logs       : ${CYAN}journalctl -u guardianpi -f${NC}"
    echo -e "   Redémarrer : ${CYAN}systemctl restart guardianpi${NC}"
    echo ""
    echo -e "${WHITE}📚 Documentation : ${CYAN}$REPO_URL/blob/main/README.md${NC}"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ── MAIN ──
main() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    
    echo -e "${CYAN}Début installation: $(date)${NC}"
    
    check_root
    check_pi
    check_internet
    check_os
    
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
