#!/bin/bash
# GuardianPi — Diagnostic complet (Mode Hotspot WiFi)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }

echo -e "\n${WHITE}═══ GuardianPi Hotspot — Diagnostic ═══${NC}\n"

# ── Services ──
echo -e "${WHITE}Services :${NC}"
for svc in hostapd dnsmasq guardianpi; do
    systemctl is-active "$svc" &>/dev/null \
        && ok "$svc actif" \
        || fail "$svc INACTIF (sudo systemctl start $svc)"
done

# ── Interfaces ──
echo -e "\n${WHITE}Interfaces réseau :${NC}"
ip addr show eth0  2>/dev/null | grep -q "inet " && ok "eth0 (WAN) — IP attribuée" || fail "eth0 — pas d'IP (vérifiez le câble Ethernet)"
ip addr show wlan0 2>/dev/null | grep -q "192.168.4.1" && ok "wlan0 (AP) — 192.168.4.1 ✓" || fail "wlan0 — IP 192.168.4.1 manquante"

# ── Hostapd ──
echo -e "\n${WHITE}Hotspot WiFi :${NC}"
SSID=$(grep -E "^ssid=" /etc/hostapd/hostapd.conf 2>/dev/null | cut -d= -f2)
CHAN=$(grep -E "^channel=" /etc/hostapd/hostapd.conf 2>/dev/null | cut -d= -f2)
[[ -n "$SSID" ]] && ok "SSID : $SSID (canal $CHAN)" || warn "Fichier hostapd.conf manquant"

CLIENTS=$(iw dev wlan0 station dump 2>/dev/null | grep -c "Station" || echo 0)
info "Clients WiFi connectés : $CLIENTS"

# ── DHCP ──
echo -e "\n${WHITE}DHCP — Appareils connectés :${NC}"
LEASES="/var/lib/misc/dnsmasq.leases"
if [[ -f "$LEASES" ]] && [[ -s "$LEASES" ]]; then
    while read -r ts mac ip name _; do
        info "$name — $ip ($mac)"
    done < "$LEASES"
else
    warn "Aucun appareil connecté (leases vide)"
fi

# ── DNS ──
echo -e "\n${WHITE}DNS / Filtrage :${NC}"
ss -ulnp | grep -q ":53 " && ok "Port 53 UDP en écoute (DNS actif)" || fail "Port 53 non actif"
BLOCKED=$(wc -l < /etc/guardianpi/blocked_domains.conf 2>/dev/null || echo 0)
info "Domaines bloqués : $BLOCKED lignes"

# ── NAT / Forwarding ──
echo -e "\n${WHITE}Routage NAT :${NC}"
FWD=$(cat /proc/sys/net/ipv4/ip_forward)
[[ "$FWD" == "1" ]] && ok "IP forwarding activé" || fail "IP forwarding désactivé (sudo sysctl -w net.ipv4.ip_forward=1)"
iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE" && ok "NAT Masquerade actif" || fail "NAT Masquerade manquant"

# ── Dashboard ──
echo -e "\n${WHITE}Dashboard GuardianPi :${NC}"
curl -s -o /dev/null -w "%{http_code}" http://192.168.4.1:8080/ 2>/dev/null | grep -q "200\|302\|304" \
    && ok "Dashboard accessible http://192.168.4.1:8080" \
    || warn "Dashboard non accessible (service en démarrage ?)"

# ── Résumé ──
echo -e "\n${WHITE}Résumé :${NC}"
echo -e "   SSID      : ${CYAN}${SSID:-GuardianPi}${NC}"
echo -e "   Gateway   : ${CYAN}192.168.4.1${NC}"
echo -e "   Dashboard : ${CYAN}http://192.168.4.1:8080${NC}"
echo ""
echo -e "${CYAN}Logs :  journalctl -u hostapd -f${NC}"
echo -e "${CYAN}        journalctl -u guardianpi -f${NC}"
echo ""
