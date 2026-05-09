#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  GuardianPi — Script d'installation (Mode Point d'Accès WiFi)
#  Usage: sudo bash install.sh
# ══════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
PURPLE='\033[0;35m'

INSTALL_DIR="/opt/guardianpi"
DATA_DIR="/etc/guardianpi/data"
LOG_FILE="/var/log/guardianpi-install.log"
REPO_URL="https://github.com/contactwebdevpro-cmyk/GuardianPi.git"

WAN_IF="eth0"
AP_IF="wlan0"
AP_IP="192.168.4.1"
DHCP_START="192.168.4.100"
DHCP_END="192.168.4.200"
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
echo -e "${CYAN}  Version 2.0.1${NC}"
echo ""

step()  { echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
info()  { echo -e "  ${CYAN}→${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()   { echo -e "  ${RED}✗${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Ce script doit être lancé avec sudo"
        exit 1
    fi
    ok "Droits root OK"
}

check_pi() {
    if grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        DEVMODE=false; ok "Raspberry Pi détecté"
    else
        DEVMODE=true; warn "Mode développement (pas de Pi)"
    fi
}

check_internet() {
    echo -n "  Connexion internet... "
    if ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        err "Pas de connexion internet. Vérifiez le câble Ethernet sur ${WAN_IF}."
        exit 1
    fi
}

check_wifi() {
    echo -n "  Interface WiFi ${AP_IF}... "
    if ip link show "$AP_IF" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        err "wlan0 introuvable."
        exit 1
    fi
}

install_packages() {
    step "📦 Installation des paquets"
    apt-get update -qq >> "$LOG_FILE" 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        python3 python3-pip python3-venv \
        hostapd dnsmasq \
        iptables iptables-persistent \
        dhcpcd5 nmap git curl net-tools iproute2 procps rfkill \
        >> "$LOG_FILE" 2>&1
    systemctl unmask hostapd >> "$LOG_FILE" 2>&1 || true
    ok "Paquets installés"
}

unblock_wifi() {
    step "📶 Déblocage WiFi (rfkill)"
    rfkill unblock wifi >> "$LOG_FILE" 2>&1 || true
    rfkill unblock all  >> "$LOG_FILE" 2>&1 || true
    ok "WiFi débloqué"
}

stop_conflicting_services() {
    step "🛑 Arrêt des services en conflit"

    # wpa_supplicant — conflit direct avec hostapd sur wlan0
    if systemctl is-active wpa_supplicant &>/dev/null; then
        info "Arrêt de wpa_supplicant..."
        systemctl stop wpa_supplicant >> "$LOG_FILE" 2>&1 || true
        systemctl disable wpa_supplicant >> "$LOG_FILE" 2>&1 || true
    fi
    pkill -f "wpa_supplicant.*wlan0" 2>/dev/null || true
    sleep 1

    # NetworkManager — ignorer wlan0
    if systemctl is-active NetworkManager &>/dev/null; then
        info "NetworkManager détecté — exclusion de ${AP_IF}..."
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/guardianpi.conf << EOF
[keyfile]
unmanaged-devices=interface-name:${AP_IF}
EOF
        systemctl reload NetworkManager >> "$LOG_FILE" 2>&1 || true
        sleep 1
    fi

    # systemd-networkd — marquer wlan0 non géré
    if systemctl is-active systemd-networkd &>/dev/null; then
        info "systemd-networkd — exclusion de ${AP_IF}..."
        mkdir -p /etc/systemd/network
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

apply_static_ip() {
    ip addr flush dev "$AP_IF" 2>/dev/null || true
    ip addr add "${AP_IP}/24" dev "$AP_IF" 2>/dev/null || true
    ip link set "$AP_IF" up 2>/dev/null || true
}

configure_static_ip() {
    step "🌐 IP statique sur ${AP_IF} (${AP_IP})"

    if [[ -f /etc/dhcpcd.conf ]]; then
        # Supprimer les anciens blocs GuardianPi
        sed -i '/# GuardianPi/,/nohook wpa_supplicant/d' /etc/dhcpcd.conf 2>/dev/null || true
        # Supprimer toute ligne denyinterfaces existante pour AP_IF
        sed -i "/^denyinterfaces.*${AP_IF}/d" /etc/dhcpcd.conf 2>/dev/null || true
    fi

    # CORRECTION CLÉ : interdire à dhcpcd de toucher wlan0.
    # Sans cette ligne, dhcpcd démarre après guardianpi-ip.service et écrase
    # l'IP statique en tentant un bail DHCP infini sur wlan0 → boucle
    # "récupération de l'IP" côté clients. L'IP sera gérée exclusivement
    # par guardianpi-ip.service.
    if [[ -f /etc/dhcpcd.conf ]]; then
        sed -i "1s/^/denyinterfaces ${AP_IF}\n/" /etc/dhcpcd.conf
    else
        echo "denyinterfaces ${AP_IF}" > /etc/dhcpcd.conf
    fi

    apply_static_ip
    ok "IP statique ${AP_IP} appliquée sur ${AP_IF} (dhcpcd exclu de ${AP_IF})"
}

configure_hostapd() {
    step "📶 Point d'accès WiFi (hostapd)"
    mkdir -p /etc/hostapd
    cat > /etc/hostapd/hostapd.conf << EOF
interface=${AP_IF}
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
country_code=${AP_COUNTRY}
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=${AP_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
macaddr_acl=0
ignore_broadcast_ssid=0
EOF

    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd
    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable hostapd >> "$LOG_FILE" 2>&1
    ok "Hotspot '${AP_SSID}' configuré"
}

configure_dnsmasq() {
    step "🔍 DHCP + DNS (dnsmasq)"
    [[ -f /etc/dnsmasq.conf ]] && cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup

    cat > /etc/dnsmasq.conf << EOF
interface=${AP_IF}
bind-interfaces
listen-address=${AP_IP}
no-resolv
server=1.1.1.1
server=8.8.8.8
server=9.9.9.9
cache-size=1000
local-ttl=0
neg-ttl=0
no-negcache
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h
dhcp-option=option:router,${AP_IP}
dhcp-option=option:dns-server,${AP_IP}
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
conf-file=/etc/guardianpi/blocked_domains.conf
EOF

    mkdir -p /etc/guardianpi /var/lib/misc
    touch /etc/guardianpi/blocked_domains.conf

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
    step "🔀 Routage NAT"
    sysctl -w net.ipv4.ip_forward=1 >> "$LOG_FILE" 2>&1
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-guardianpi.conf
    sysctl -p /etc/sysctl.d/99-guardianpi.conf >> "$LOG_FILE" 2>&1

    if [[ "$DEVMODE" == "false" ]]; then
        iptables -t nat -F
        iptables -F FORWARD
        iptables -t nat -A POSTROUTING -o "${WAN_IF}" -j MASQUERADE
        iptables -A FORWARD -i "${AP_IF}" -o "${WAN_IF}" -j ACCEPT
        iptables -A FORWARD -i "${WAN_IF}" -o "${AP_IF}" -m state --state ESTABLISHED,RELATED -j ACCEPT
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        ok "NAT actif"
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

    # Répertoire du script (le projet est un niveau au-dessus de scripts/)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LOCAL_SRC="$(dirname "$SCRIPT_DIR")"

    if [[ -d "$INSTALL_DIR/.git" ]]; then
        # Mise à jour d'une installation existante
        cd "$INSTALL_DIR" && git pull origin main >> "$LOG_FILE" 2>&1
        ok "Mise à jour git effectuée"
    elif [[ -f "$LOCAL_SRC/backend/main.py" ]]; then
        # Copie depuis les fichiers locaux (cas normal : script lancé depuis le projet)
        info "Copie des fichiers locaux depuis $LOCAL_SRC..."
        cp -r "$LOCAL_SRC/backend"  "$INSTALL_DIR/"
        cp -r "$LOCAL_SRC/frontend" "$INSTALL_DIR/"
        [[ -d "$LOCAL_SRC/scripts" ]] && cp -r "$LOCAL_SRC/scripts" "$INSTALL_DIR/"
        ok "Fichiers copiés depuis le projet local"
    elif [[ -d /tmp/guardianpi-src ]]; then
        cp -r /tmp/guardianpi-src/* "$INSTALL_DIR/"
        ok "Fichiers copiés depuis /tmp/guardianpi-src"
    else
        # Dernier recours : git clone
        info "Tentative de clonage depuis GitHub..."
        git clone "$REPO_URL" "$INSTALL_DIR" >> "$LOG_FILE" 2>&1 || {
            warn "Clonage échoué — structure minimale créée (dashboard indisponible)"
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
  "version": "2.0.1",
  "install_date": "$(date -Iseconds)"
}
EOF
    echo "[]" > "$DATA_DIR/rules.json"
    echo "[]" > "$DATA_DIR/schedules.json"
    echo "{}" > "$DATA_DIR/devices.json"
    echo "{}" > "$DATA_DIR/tokens.json"
    chown -R root:root /etc/guardianpi
    chmod -R 700 /etc/guardianpi
    ok "Configuration créée"
}

create_services() {
    step "🔧 Services systemd"

    cat > /etc/systemd/system/guardianpi.service << EOF
[Unit]
Description=GuardianPi — Routeur Parental
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

    # SERVICE CLÉ : garantit que wlan0 a son IP AVANT dnsmasq et hostapd.
    # CORRECTION : After=network.target dhcpcd.service (et non network-pre.target).
    # dhcpcd est maintenant configuré avec "denyinterfaces wlan0" donc il ne
    # touche pas wlan0 ; ce service s'exécute après dhcpcd pour appliquer
    # l'IP statique en dernier, sans risque d'écrasement.
    cat > /etc/systemd/system/guardianpi-ip.service << EOF
[Unit]
Description=GuardianPi — IP statique wlan0
Before=dnsmasq.service hostapd.service guardianpi.service
After=network.target dhcpcd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    rfkill unblock wifi 2>/dev/null || true; \
    ip addr flush dev ${AP_IF} 2>/dev/null || true; \
    ip addr add ${AP_IP}/24 dev ${AP_IF}; \
    ip link set ${AP_IF} up'

[Install]
WantedBy=multi-user.target
EOF

    # Override dnsmasq : attend que l'IP 192.168.4.1 soit sur wlan0 avant de démarrer
    mkdir -p /etc/systemd/system/dnsmasq.service.d
    cat > /etc/systemd/system/dnsmasq.service.d/guardianpi-wait.conf << EOF
[Unit]
After=guardianpi-ip.service network-pre.target
Wants=guardianpi-ip.service

[Service]
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 20); do ip addr show ${AP_IF} | grep -q ${AP_IP} && exit 0; sleep 1; done; ip addr add ${AP_IP}/24 dev ${AP_IF}; ip link set ${AP_IF} up'
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable guardianpi-restore guardianpi guardianpi-ip >> "$LOG_FILE" 2>&1
    ok "Services configurés (guardianpi-ip démarre avant dnsmasq)"
}

start_all() {
    step "🚀 Démarrage des services"

    # 1. Appliquer l'IP maintenant
    info "Application de l'IP ${AP_IP} sur ${AP_IF}..."
    apply_static_ip
    sleep 1

    # 2. dhcpcd
    if systemctl is-enabled dhcpcd &>/dev/null 2>&1; then
        systemctl restart dhcpcd >> "$LOG_FILE" 2>&1 && ok "dhcpcd redémarré" || warn "dhcpcd erreur"
        sleep 2
    fi

    # 3. Re-vérifier l'IP (dhcpcd peut l'effacer)
    if ! ip addr show "$AP_IF" | grep -q "${AP_IP}"; then
        info "Ré-application de l'IP (effacée par dhcpcd)..."
        apply_static_ip
        sleep 1
    fi

    if ip addr show "$AP_IF" | grep -q "${AP_IP}"; then
        ok "IP ${AP_IP} confirmée sur ${AP_IF}"
    else
        warn "IP ${AP_IP} absente — les services risquent d'échouer"
    fi

    # 4. hostapd
    systemctl restart hostapd >> "$LOG_FILE" 2>&1
    sleep 2
    if systemctl is-active hostapd &>/dev/null; then
        ok "hostapd actif — Hotspot '${AP_SSID}' diffusé ✓"
    else
        warn "hostapd inactif :"
        journalctl -u hostapd -n 10 --no-pager 2>/dev/null | tail -10
    fi

    # 5. dnsmasq — après confirmation IP
    systemctl restart dnsmasq >> "$LOG_FILE" 2>&1
    sleep 1
    if systemctl is-active dnsmasq &>/dev/null; then
        ok "dnsmasq actif (DHCP + DNS) ✓"
    else
        warn "dnsmasq inactif :"
        journalctl -u dnsmasq -n 10 --no-pager 2>/dev/null | tail -10
    fi

    # 6. Backend
    systemctl start guardianpi >> "$LOG_FILE" 2>&1
    sleep 2
    systemctl is-active guardianpi &>/dev/null && ok "GuardianPi backend actif" || warn "Backend inactif"
}

print_success() {
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ✅  GuardianPi installé avec succès !                 ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}📶 Réseau WiFi :${NC}"
    echo -e "   SSID         : ${CYAN}${AP_SSID}${NC}"
    echo -e "   Mot de passe : ${CYAN}${AP_PASSPHRASE}${NC}"
    echo ""
    echo -e "${WHITE}📍 Dashboard :${NC}"
    echo -e "   ${CYAN}http://${AP_IP}:8080${NC}      (WiFi GuardianPi)"
    echo -e "   ${CYAN}http://${LOCAL_IP}:8080${NC}  (réseau Ethernet)"
    echo ""
    echo -e "${WHITE}🔐 Identifiants : ${CYAN}admin${NC} / ${CYAN}guardianpi${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Changez les mots de passe dans Réglages !${NC}"
    echo ""
    echo -e "${WHITE}🔎 Diagnostic :${NC}"
    echo -e "   ${CYAN}sudo bash diagnose.sh${NC}"
    echo -e "   ${CYAN}journalctl -u hostapd -f${NC}    — logs WiFi"
    echo -e "   ${CYAN}journalctl -u dnsmasq -f${NC}    — logs DHCP/DNS"
    echo -e "   ${CYAN}journalctl -u guardianpi -f${NC} — logs backend"
    echo ""
}

main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=========================================="
    echo "Début installation GuardianPi: $(date)"
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
