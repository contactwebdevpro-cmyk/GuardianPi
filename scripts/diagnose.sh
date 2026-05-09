#!/bin/bash
# GuardianPi — Diagnostic système

echo "═══════════════════════════════════════"
echo "  GuardianPi — Diagnostic"
echo "═══════════════════════════════════════"
echo ""

# Services
echo "📋 SERVICES :"
systemctl is-active guardianpi && echo "  ✓ guardianpi: actif" || echo "  ✗ guardianpi: inactif"
systemctl is-active dnsmasq && echo "  ✓ dnsmasq: actif" || echo "  ✗ dnsmasq: inactif"
echo ""

# Réseau
echo "🌐 RÉSEAU :"
echo "  IP locale: $(hostname -I | awk '{print $1}')"
echo "  Gateway: $(ip route | grep default | awk '{print $3}')"
echo ""

# Port 8080
echo "🔌 PORTS :"
ss -tlnp | grep 8080 && echo "  ✓ Port 8080 ouvert" || echo "  ✗ Port 8080 fermé"
ss -tlnp | grep ':53' && echo "  ✓ Port 53 (DNS) ouvert" || echo "  ✗ Port 53 fermé"
echo ""

# Dashboard
echo "🖥 DASHBOARD :"
LOCAL_IP=$(hostname -I | awk '{print $1}')
curl -s "http://localhost:8080/api/global/status" > /dev/null && echo "  ✓ API répond" || echo "  ✗ API ne répond pas"
echo "  URL: http://$LOCAL_IP:8080"
echo ""

# Ressources Pi
echo "💻 RESSOURCES :"
TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
echo "  Température CPU: $((TEMP/1000))°C"
echo "  RAM libre: $(free -m | awk '/^Mem/{print $4}')MB"
echo "  Disque libre: $(df -h / | awk 'NR==2{print $4}')"
echo ""

# Appareils
echo "📡 APPAREILS (ARP) :"
arp -n 2>/dev/null | grep -v "incomplete" | tail -n +2 | head -10 || ip neigh show 2>/dev/null | head -10
echo ""

echo "═══════════════════════════════════════"
echo "  Logs: journalctl -u guardianpi -n 30"
echo "═══════════════════════════════════════"
