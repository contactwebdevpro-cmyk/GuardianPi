#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  GuardianPi — Script d'installation (Mode Point d'Accès WiFi)
#  Le Raspberry Pi crée son propre réseau WiFi "GuardianPi"
#  Les appareils s'y connectent → filtrage automatique, sans config !
#  Usage: sudo bash install.sh
# ══════════════════════════════════════════════════════════════════

# FIX #1 : "set -euo pipefail" supprimé — il faisait quitter le script
# à la moindre erreur non fatale (ex: commande introuvable, ping raté)
# On gère les erreurs manuellement ci-dessous.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
PURPLE='\033[0;35m'

INSTALL_DIR="/opt/guardianpi"
DATA_DIR="/etc/guardianpi/data"
LOG_FILE="/var/log/guardianpi-install.log"
REPO_URL="https://github.com/contactwebdevpro-cmyk/GuardianPi.git"

# ─── Interfaces réseau ───────────────────────────────────────────
WAN_IF="eth0"           # Câble Ethernet → box internet
AP_IF="wlan0"           # WiFi → les appareils se connectent ici
AP_IP="192.168.4.1"     # IP du Pi sur son propre réseau WiFi
DHCP_START="192.168.4.100"
DHCP_END="192.168.4.200"

# ─── Config WiFi (modifiable après install via le dashboard) ──────
AP_SSID="GuardianPi"
AP_PASSPHRASE="guardianpi123"
AP_CHANNEL="6"
AP_COUNTRY="FR"

clear
echo -e "${PURPLE}"
cat << 'BANNER'
  ____                     _ _             ____  _
 / ___|_   _  __ _ _ __ __| (_) __ _ _ __ |  _ \(_)
| |  _| | | |/ _` | '__/ _` | |/ _` | '_ \| |_) | |
| |_| | |_| | (_| | | | (_| | | (_| | | | |  __/| |
 \____|__,_|\__,_|_|  \__,_|_|\__,_|_| |_|_|   |_|

BANNER
echo -e "${WHITE}  Routeur parental — Mode Point d'Accès WiFi${NC}"
echo -e "${CYAN}  Version 2.0.0${NC}"
echo ""
echo -e "${GREEN}  📶 Le Pi crée son propre WiFi 'GuardianPi'${NC}"
echo -e "${GREEN}  📱 Les appareils s'y connectent → filtrage transparent !${NC}"
echo ""

step()  { echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
info()  { echo -e "  ${CYAN}→${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()   { echo -e "  ${RED}✗${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Ce script doit être lancé avec sudo"
        echo -e "${RED}  Relancez : sudo bash install.sh${NC}"
        exit 1
    fi
    ok "Droits root OK"
}

check_pi() {
    if grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        DEVMODE=false
        ok "Raspberry Pi détecté"
    else
        DEVMODE=true
        warn "Mode développement (pas de Pi — certaines étapes seront ignorées)"
    fi
}

check_internet() {
    echo -n "  Connexion internet... "
    if ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        err "Pas de connexion internet. Vérifiez le câble Ethernet sur eth0."
        err "Si vous êtes en mode dev/test, ignorez cette erreur et relancez en commentant la ligne 'exit 1' ci-dessous."
        exit 1
    fi
}

check_wifi() {
    echo -n "  Interface WiFi ${AP_IF}... "
    if ip link show "$AP_IF" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        err "wlan0 introuvable. Branchez un adaptateur WiFi ou activez le WiFi intégré."
        exit 1
    fi
}

install_packages() {
    step "📦 Installation des paquets"
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt-get install -y \
        python3 python3-pip python3-venv \
        hostapd dnsmasq \
        iptables iptables-persistent \
        dhcpcd5 nmap git curl net-tools iproute2 procps rfkill \
        >> "$LOG_FILE" 2>&1
    # FIX #2 : unmask ET désactivation de wpa_supplicant sur wlan0
    systemctl unmask hostapd >> "$LOG_FILE" 2>&1 || true
    ok "Paquets installés (hostapd + dnsmasq + rfkill)"
}

unblock_wifi() {
    # FIX #3 : déblocage rfkill — cause principale du hotspot qui ne démarre pas
    step "📶 Déblocage WiFi (rfkill)"
    rfkill unblock wifi >> "$LOG_FILE" 2>&1 || true
    ok "WiFi débloqué via rfkill"
}

stop_conflicting_services() {
    # FIX #4 : wpa_supplicant et NetworkManager entrent en conflit avec hostapd
    step "🛑 Arrêt des services en conflit"

    # Arrêter wpa_supplicant sur wlan0 (conflit direct avec hostapd)
    if systemctl is-active wpa_supplicant &>/dev/null; then
        info "Arrêt de wpa_supplicant..."
        systemctl stop wpa_supplicant >> "$LOG_FILE" 2>&1 || true
        systemctl disable wpa_supplicant >> "$LOG_FILE" 2>&1 || true
    fi

    # Empêcher NetworkManager de gérer wlan0 s'il est présent
    if systemctl is-active NetworkManager &>/dev/null; then
        info "NetworkManager détecté — configuration pour ignorer wlan0..."
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/guardianpi.conf << EOF
[keyfile]
unmanaged-devices=interface-name:${AP_IF}
EOF
        systemctl reload NetworkManager >> "$LOG_FILE" 2>&1 || true
    fi

    # Arrêter systemd-networkd si actif (conflit possible)
    if systemctl is-active systemd-networkd &>/dev/null; then
        info "Arrêt de systemd-networkd sur ${AP_IF}..."
        cat > /etc/systemd/network/10-guardianpi-wlan.network << EOF
[Match]
Name=${AP_IF}

[Link]
Unmanaged=yes
EOF
        systemctl restart systemd-networkd >> "$LOG_FILE" 2>&1 || true
    fi

    ok "Conflits réseau résolus"
}

configure_static_ip() {
    step "🌐 IP statique sur ${AP_IF} (${AP_IP})"

    # FIX #5 : nettoyage propre de toute conf wlan0 existante dans dhcpcd.conf
    if [[ -f /etc/dhcpcd.conf ]]; then
        # Supprimer le bloc GuardianPi précédent s'il existe
        sed -i '/# GuardianPi/,/nohook wpa_supplicant/d' /etc/dhcpcd.conf 2>/dev/null || true
    fi

    cat >> /etc/dhcpcd.conf << EOF

# GuardianPi — interface AP WiFi
interface ${AP_IF}
    static ip_address=${AP_IP}/24
    nohook wpa_supplicant
EOF

    # Appliquer immédiatement sans attendre le redémarrage de dhcpcd
    ip addr flush dev "$AP_IF" 2>/dev/null || true
    ip addr add "${AP_IP}/24" dev "$AP_IF" 2>/dev/null || true
    ip link set "$AP_IF" up 2>/dev/null || true

    ok "IP statique ${AP_IP} appliquée sur ${AP_IF}"
}

configure_hostapd() {
    step "📶 Point d'accès WiFi (hostapd)"
    mkdir -p /etc/hostapd
    cat > /etc/hostapd/hostapd.conf << EOF
# GuardianPi Hotspot
interface=${AP_IF}
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
country_code=${AP_COUNTRY}
ieee80211n=1
wmm_enabled=1

# Sécurité WPA2
auth_algs=1
wpa=2
wpa_passphrase=${AP_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
macaddr_acl=0
ignore_broadcast_ssid=0
EOF

    # FIX #6 : pointer explicitement vers le fichier de config dans /etc/default/hostapd
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

    # FIX #7 : aussi patcher le service systemd hostapd (nécessaire sur Debian/Bookworm)
    if [[ -f /lib/systemd/system/hostapd.service ]]; then
        sed -i 's|#DAEMON_CONF=.*|DAEMON_CONF=/etc/hostapd/hostapd.conf|' \
            /lib/systemd/system/hostapd.service 2>/dev/null || true
    fi

    systemctl enable hostapd >> "$LOG_FILE" 2>&1
    ok "Hotspot '${AP_SSID}' configuré (canal ${AP_CHANNEL}, WPA2)"
}

configure_dnsmasq() {
    step "🔍 DHCP + DNS (dnsmasq)"
    [[ -f /etc/dnsmasq.conf ]] && cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup

    cat > /etc/dnsmasq.conf << EOF
# GuardianPi — DHCP + DNS pour le réseau WiFi interne
interface=${AP_IF}
bind-interfaces
listen-address=${AP_IP}
no-resolv

# DNS upstream (Cloudflare + Google)
server=1.1.1.1
server=8.8.8.8
server=9.9.9.9
cache-size=1000
neg-ttl=60

# DHCP : attribue une IP à chaque appareil qui se connecte au WiFi
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h

# Envoie automatiquement au téléphone/tablette :
#   Gateway → Pi (le trafic passe par lui)
#   DNS     → Pi (filtrage transparent)
dhcp-option=option:router,${AP_IP}
dhcp-option=option:dns-server,${AP_IP}

dhcp-leasefile=/var/lib/misc/dnsmasq.leases

# Blocage DNS GuardianPi
conf-file=/etc/guardianpi/blocked_domains.conf
EOF

    mkdir -p /etc/guardianpi
    touch /etc/guardianpi/blocked_domains.conf

    # Désactiver systemd-resolved (conflit port 53)
    if systemctl is-active systemd-resolved &>/dev/null; then
        info "Désactivation systemd-resolved (conflit port 53)..."
        systemctl stop systemd-resolved >> "$LOG_FILE" 2>&1
        systemctl disable systemd-resolved >> "$LOG_FILE" 2>&1
        rm -f /etc/resolv.conf
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    fi

    systemctl enable dnsmasq >> "$LOG_FILE" 2>&1
    ok "dnsmasq configuré — DHCP ${DHCP_START}–${DHCP_END}"
}

configure_nat() {
    step "🔀 Routage NAT : WiFi (${AP_IF}) → Internet (${WAN_IF})"
    sysctl -w net.ipv4.ip_forward=1 >> "$LOG_FILE" 2>&1
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-guardianpi.conf
    sysctl -p /etc/sysctl.d/99-guardianpi.conf >> "$LOG_FILE" 2>&1

    if [[ "$DEVMODE" == "false" ]]; then
        iptables -t nat -F
        iptables -F FORWARD
        # Masquerade : les appareils WiFi sortent avec l'IP eth0 du Pi
        iptables -t nat -A POSTROUTING -o "${WAN_IF}" -j MASQUERADE
        # Forwarding WiFi → Internet
        iptables -A FORWARD -i "${AP_IF}" -o "${WAN_IF}" -j ACCEPT
        # Réponses autorisées
        iptables -A FORWARD -i "${WAN_IF}" -o "${AP_IF}" -m state --state ESTABLISHED,RELATED -j ACCEPT
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        ok "NAT actif — les appareils WiFi ont accès à internet via eth0"
    else
        warn "Mode dev — NAT ignoré"
    fi
}

configure_firewall() {
    step "🔒 Firewall"
    if [[ "$DEVMODE" == "false" ]]; then
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -i "${AP_IF}" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -i "${AP_IF}" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -i "${AP_IF}" -p udp --dport 67 -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    ok "Firewall configuré"
}

install_app() {
    step "📥 Installation de GuardianPi"
    mkdir -p "$INSTALL_DIR" "$DATA_DIR" /etc/guardianpi /etc/iptables
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        cd "$INSTALL_DIR" && git pull origin main >> "$LOG_FILE" 2>&1
    elif [[ -d /tmp/guardianpi-src ]]; then
        cp -r /tmp/guardianpi-src/* "$INSTALL_DIR/"
    else
        git clone "$REPO_URL" "$INSTALL_DIR" >> "$LOG_FILE" 2>&1 || {
            warn "Clonage échoué — structure minimale créée"
            mkdir -p "$INSTALL_DIR"/{backend,frontend/public,scripts}
        }
    fi
    ok "Fichiers dans $INSTALL_DIR"
}

setup_python() {
    step "🐍 Environnement Python"
    VENV="$INSTALL_DIR/venv"
    python3 -m venv "$VENV" >> "$LOG_FILE" 2>&1
    "$VENV/bin/pip" install --upgrade pip >> "$LOG_FILE" 2>&1
    "$VENV/bin/pip" install fastapi uvicorn pydantic python-multipart >> "$LOG_FILE" 2>&1
    ok "Virtualenv configuré"
}

create_config() {
    step "⚙️  Configuration initiale"
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    cat > "$DATA_DIR/config.json" << EOF
{
  "username": "admin",
  "password_hash": "$(echo -n 'guardianpi' | sha256sum | cut -d' ' -f1)",
  "setup_done": true,
  "mode": "hotspot",
  "interface_wan": "${WAN_IF}",
  "interface_ap": "${AP_IF}",
  "ap_ip": "${AP_IP}",
  "ap_ssid": "${AP_SSID}",
  "ap_passphrase": "${AP_PASSPHRASE}",
  "ap_channel": ${AP_CHANNEL},
  "ap_country": "${AP_COUNTRY}",
  "dhcp_start": "${DHCP_START}",
  "dhcp_end": "${DHCP_END}",
  "global_pause": false,
  "version": "2.0.0",
  "install_date": "$(date -Iseconds)"
}
EOF
    echo "[]" > "$DATA_DIR/rules.json"
    echo "[]" > "$DATA_DIR/schedules.json"
    echo "{}" > "$DATA_DIR/devices.json"
    echo "{}" > "$DATA_DIR/tokens.json"
    chown -R root:root /etc/guardianpi
    chmod -R 700 /etc/guardianpi
    ok "Configuration créée (mode hotspot)"
}

create_services() {
    step "🔧 Services systemd"
    cat > /etc/systemd/system/guardianpi.service << EOF
[Unit]
Description=GuardianPi — Routeur Parental (Mode Hotspot)
After=network.target hostapd.service dnsmasq.service
Wants=hostapd.service dnsmasq.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}/backend
ExecStart=${INSTALL_DIR}/venv/bin/python main.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=guardianpi
Environment=PYTHONUNBUFFERED=1
Environment=GUARDIANPI_ENV=production
MemoryLimit=256M
CPUQuota=80%

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/guardianpi-restore.service << EOF
[Unit]
Description=GuardianPi — Restauration iptables
Before=guardianpi.service hostapd.service
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable guardianpi-restore guardianpi >> "$LOG_FILE" 2>&1
    ok "Services configurés"
}

start_all() {
    step "🚀 Démarrage des services"

    # FIX #8 : ordre correct + vérification avec messages d'erreur clairs

    # 1. Redémarrer dhcpcd pour appliquer l'IP statique
    if systemctl is-enabled dhcpcd &>/dev/null 2>&1; then
        systemctl restart dhcpcd >> "$LOG_FILE" 2>&1 && ok "dhcpcd redémarré" || warn "dhcpcd : erreur (voir $LOG_FILE)"
        sleep 3
    fi

    # 2. S'assurer que l'IP est bien sur l'interface (double filet de sécurité)
    if ! ip addr show "$AP_IF" | grep -q "${AP_IP}"; then
        info "Application manuelle de l'IP ${AP_IP} sur ${AP_IF}..."
        ip addr add "${AP_IP}/24" dev "$AP_IF" 2>/dev/null || true
        ip link set "$AP_IF" up
    fi

    # 3. Lancer hostapd
    systemctl restart hostapd >> "$LOG_FILE" 2>&1
    sleep 2
    if systemctl is-active hostapd &>/dev/null; then
        ok "hostapd actif — Hotspot '${AP_SSID}' diffusé ✓"
    else
        warn "hostapd inactif — Diagnostic :"
        journalctl -u hostapd -n 20 --no-pager | tail -20
        echo ""
        warn "Conseil : vérifiez que le WiFi n'est pas bloqué (rfkill list)"
    fi

    # 4. Lancer dnsmasq
    systemctl restart dnsmasq >> "$LOG_FILE" 2>&1
    sleep 1
    systemctl is-active dnsmasq &>/dev/null && ok "dnsmasq actif (DHCP + DNS)" || warn "dnsmasq inactif (voir $LOG_FILE)"

    # 5. Lancer le backend GuardianPi
    systemctl start guardianpi >> "$LOG_FILE" 2>&1
    sleep 2
    systemctl is-active guardianpi &>/dev/null && ok "GuardianPi backend actif" || warn "Backend inactif (voir $LOG_FILE)"
}

print_success() {
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ✅  GuardianPi Hotspot installé avec succès !         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}📶 Réseau WiFi créé :${NC}"
    echo -e "   SSID          : ${CYAN}${AP_SSID}${NC}"
    echo -e "   Mot de passe  : ${CYAN}${AP_PASSPHRASE}${NC}"
    echo ""
    echo -e "${WHITE}📱 Pour connecter un téléphone :${NC}"
    echo -e "   1. Réglages → WiFi → choisir ${CYAN}${AP_SSID}${NC}"
    echo -e "   2. Mot de passe : ${CYAN}${AP_PASSPHRASE}${NC}"
    echo -e "   3. Connecté ! Le filtrage est automatique. ✓"
    echo ""
    echo -e "${WHITE}📍 Dashboard :${NC}"
    echo -e "   ${CYAN}http://${AP_IP}:8080${NC}  (depuis un appareil sur le WiFi GuardianPi)"
    echo -e "   ${CYAN}http://${LOCAL_IP}:8080${NC}  (depuis le réseau de la box)"
    echo ""
    echo -e "${WHITE}🔐 Identifiants : ${CYAN}admin${NC} / ${CYAN}guardianpi${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Changez le mot de passe WiFi ET le mot de passe admin dans Réglages !${NC}"
    echo ""
    echo -e "${WHITE}🔎 En cas de problème :${NC}"
    echo -e "   ${CYAN}sudo bash diagnose.sh${NC}          — diagnostic complet"
    echo -e "   ${CYAN}journalctl -u hostapd -f${NC}       — logs du point d'accès WiFi"
    echo -e "   ${CYAN}journalctl -u guardianpi -f${NC}    — logs du backend"
    echo -e "   ${CYAN}rfkill list${NC}                    — vérifier si le WiFi est bloqué"
    echo -e "   ${CYAN}cat $LOG_FILE${NC}   — log complet de l'installation"
    echo ""
}

main() {
    # Initialiser le fichier de log
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=========================================="
    echo "Début installation GuardianPi Hotspot: $(date)"
    echo "=========================================="

    check_root
    check_pi
    check_internet
    check_wifi
    install_packages
    unblock_wifi
    stop_conflicting_services
    configure_static_ip
    configure_hostapd
    configure_dnsmasq
    configure_nat
    configure_firewall
    install_app
    setup_python
    create_config
    create_services
    start_all
    print_success
}

main "$@"
