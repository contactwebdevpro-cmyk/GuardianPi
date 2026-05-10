#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║          PiTV OS - Script d'Installation v2.0               ║
# ║  Compatible: Raspberry Pi 3B/4/5 · Linux x86_64 · ARM      ║
# ╚══════════════════════════════════════════════════════════════╝

set -e

PITV_DIR="/opt/pitv"
PORT=8080
REPO_URL="https://github.com/contactwebdevpro-cmyk/PITV"
PITV_SERVICE="pitv-server"
KIOSK_SERVICE="pitv-kiosk"

# ─── Couleurs ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()   { echo -e "  ${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "  ${GREEN}[  OK  ]${NC} $*"; }
warn()  { echo -e "  ${YELLOW}[ WARN ]${NC} $*"; }
error() { echo -e "  ${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n  ${BOLD}${BLUE}▶ $*${NC}"; }
hr()    { echo -e "  ${DIM}────────────────────────────────────────${NC}"; }

# ─── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Lancez ce script en root : sudo bash install.sh"
fi

# ─── Bannière ─────────────────────────────────────────────────────────────────
clear
echo -e "${CYAN}"
echo "  ██████╗ ██╗    ████████╗██╗   ██╗       ██████╗ ███████╗"
echo "  ██╔══██╗██║       ██╔══╝╚██╗ ██╔╝      ██╔═══██╗██╔════╝"
echo "  ██████╔╝██║       ██║    ╚████╔╝       ██║   ██║███████╗"
echo "  ██╔═══╝ ██║       ██║    ██╔═██╗       ██║   ██║╚════██║"
echo "  ██║     ██║       ██║   ██╔╝ ╚██╗      ╚██████╔╝███████║"
echo "  ╚═╝     ╚═╝       ╚═╝   ╚═╝   ╚═╝       ╚═════╝ ╚══════╝"
echo -e "${NC}"
echo -e "  ${DIM}Installation automatique depuis GitHub${NC}"
echo ""

# ─── Détection utilisateur kiosque ────────────────────────────────────────────
if id "pi" &>/dev/null; then
  KIOSK_USER="pi"
elif id "admin" &>/dev/null; then
  KIOSK_USER="admin"
elif id "ubuntu" &>/dev/null; then
  KIOSK_USER="ubuntu"
else
  KIOSK_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
  [[ -z "$KIOSK_USER" ]] && KIOSK_USER="pi"
fi

# ─── Détection Raspberry Pi ───────────────────────────────────────────────────
if grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
  IS_PI=true
  PI_MODEL=$(grep "Model" /proc/cpuinfo | tail -1 | cut -d: -f2 | xargs)
  ok "Raspberry Pi détecté : ${PI_MODEL}"
else
  IS_PI=false
  ok "Matériel : $(uname -m)"
fi

# ─── Détection desktop ────────────────────────────────────────────────────────
if dpkg -l lightdm 2>/dev/null | grep -q '^ii' || \
   dpkg -l lxde   2>/dev/null | grep -q '^ii' || \
   dpkg -l gdm3   2>/dev/null | grep -q '^ii'; then
  HAS_DESKTOP=true
else
  HAS_DESKTOP=false
fi

hr
echo -e "  Utilisateur kiosque : ${CYAN}${KIOSK_USER}${NC}"
echo -e "  Répertoire          : ${CYAN}${PITV_DIR}${NC}"
echo -e "  Port                : ${CYAN}${PORT}${NC}"
echo -e "  Source              : ${CYAN}${REPO_URL}${NC}"
hr
echo -ne "\n  Continuer ? [O/n] "
read -r ans
[[ "$ans" =~ ^[nN] ]] && exit 0

# ═══════════════════════════════════════════════════════════════════════════════
# 1. MISE À JOUR & DÉPENDANCES
# ═══════════════════════════════════════════════════════════════════════════════
step "Mise à jour du système"
apt-get update -y 2>&1 | tail -2
ok "Sources mises à jour"

step "Installation des dépendances"
apt-get install -y curl wget git ca-certificates unzip 2>&1 | tail -3
ok "Dépendances installées"

# ═══════════════════════════════════════════════════════════════════════════════
# 2. NODE.JS
# ═══════════════════════════════════════════════════════════════════════════════
step "Installation de Node.js 20"
if node --version 2>/dev/null | grep -q "^v20"; then
  ok "Node.js 20 déjà présent ($(node --version))"
else
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>&1 | tail -3
  apt-get install -y nodejs 2>&1 | tail -3
  ok "Node.js $(node --version) installé"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 3. CHROMIUM
# ═══════════════════════════════════════════════════════════════════════════════
step "Installation de Chromium"
if command -v chromium &>/dev/null; then
  CHROMIUM_BIN=$(command -v chromium)
  ok "Chromium déjà présent : ${CHROMIUM_BIN}"
elif command -v chromium-browser &>/dev/null; then
  CHROMIUM_BIN=$(command -v chromium-browser)
  ok "Chromium déjà présent : ${CHROMIUM_BIN}"
elif apt-cache show chromium &>/dev/null 2>&1; then
  apt-get install -y chromium 2>&1 | tail -3
  CHROMIUM_BIN=$(command -v chromium)
  ok "Chromium installé"
elif apt-cache show chromium-browser &>/dev/null 2>&1; then
  apt-get install -y chromium-browser 2>&1 | tail -3
  CHROMIUM_BIN=$(command -v chromium-browser)
  ok "Chromium installé"
else
  warn "Chromium introuvable dans apt"
  CHROMIUM_BIN="/usr/bin/chromium"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 4. ENVIRONNEMENT GRAPHIQUE (si pas de desktop)
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$HAS_DESKTOP" == "false" ]]; then
  step "Installation de X11 + Openbox (mode Lite)"
  apt-get install -y \
    xserver-xorg x11-xserver-utils xinit \
    openbox unclutter xdotool \
    fonts-dejavu fonts-noto \
    2>&1 | tail -5
  ok "X11 + Openbox installés"

  # Autologin console
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
Type=simple
EOF

  # Auto-start X au login
  USER_HOME=$(getent passwd "${KIOSK_USER}" | cut -d: -f6)
  if ! grep -q "PiTV" "${USER_HOME}/.bash_profile" 2>/dev/null; then
    cat >> "${USER_HOME}/.bash_profile" << 'XSTART'
# PiTV OS - Auto-start X
if [[ -z $DISPLAY ]] && [[ $(tty) = /dev/tty1 ]]; then
  exec startx -- :0 -nocursor
fi
XSTART
  fi
  ok "Autologin + auto-start X configurés"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 5. TÉLÉCHARGEMENT DEPUIS GITHUB
# ═══════════════════════════════════════════════════════════════════════════════
step "Téléchargement de PiTV OS depuis GitHub"

mkdir -p "${PITV_DIR}/public" "${PITV_DIR}/logs"

if [[ -d "${PITV_DIR}/.git" ]]; then
  cd "${PITV_DIR}"
  git pull origin main 2>&1 | tail -3
  ok "Dépôt mis à jour"
else
  rm -rf "${PITV_DIR}"
  git clone "${REPO_URL}.git" "${PITV_DIR}" 2>&1 | tail -5
  ok "Dépôt cloné dans ${PITV_DIR}"
fi

# Si index.html est à la racine du repo, le copier dans public/
if [[ -f "${PITV_DIR}/index.html" ]] && [[ ! -f "${PITV_DIR}/public/index.html" ]]; then
  cp "${PITV_DIR}/index.html" "${PITV_DIR}/public/index.html"
  ok "index.html copié dans public/"
fi

# Crée server.js minimal si absent du repo
if [[ ! -f "${PITV_DIR}/server.js" ]]; then
  warn "server.js absent du repo — création d'un serveur minimal"
  cat > "${PITV_DIR}/server.js" << 'SERVERJS'
const http = require('http');
const fs   = require('fs');
const path = require('path');
const PORT = process.env.PORT || 8080;

const MIME = {
  '.html': 'text/html',
  '.js':   'application/javascript',
  '.css':  'text/css',
  '.json': 'application/json',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.svg':  'image/svg+xml',
  '.ico':  'image/x-icon',
};

http.createServer((req, res) => {
  if (req.url === '/api/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok', uptime: process.uptime() }));
  }

  let filePath = path.join(__dirname, 'public', req.url === '/' ? 'index.html' : req.url);
  if (!fs.existsSync(filePath)) filePath = path.join(__dirname, 'public', 'index.html');

  const mime = MIME[path.extname(filePath)] || 'application/octet-stream';
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); return res.end('Not found'); }
    res.writeHead(200, { 'Content-Type': mime });
    res.end(data);
  });
}).listen(PORT, '0.0.0.0', () => {
  console.log(`PiTV OS en ligne sur http://0.0.0.0:${PORT}`);
});
SERVERJS
fi

# Crée package.json minimal si absent
if [[ ! -f "${PITV_DIR}/package.json" ]]; then
  cat > "${PITV_DIR}/package.json" << 'PKG'
{
  "name": "pitv-os",
  "version": "2.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {}
}
PKG
fi

ok "Fichiers PiTV OS prêts"

# ═══════════════════════════════════════════════════════════════════════════════
# 6. DÉPENDANCES NPM
# ═══════════════════════════════════════════════════════════════════════════════
step "Installation des dépendances npm"
cd "${PITV_DIR}"
npm install --production 2>&1 | tail -3
ok "npm install terminé"

chown -R "${KIOSK_USER}:${KIOSK_USER}" "${PITV_DIR}" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# 7. GPU RASPBERRY PI
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$IS_PI" == "true" ]]; then
  step "Configuration GPU Raspberry Pi"
  CONFIG=""
  [[ -f /boot/firmware/config.txt ]] && CONFIG="/boot/firmware/config.txt"
  [[ -f /boot/config.txt ]]          && CONFIG="/boot/config.txt"

  if [[ -n "$CONFIG" ]]; then
    grep -q "gpu_mem=128"         "$CONFIG" || echo "gpu_mem=128"          >> "$CONFIG"
    grep -q "hdmi_force_hotplug"  "$CONFIG" || echo "hdmi_force_hotplug=1" >> "$CONFIG"
    grep -q "hdmi_drive=2"        "$CONFIG" || echo "hdmi_drive=2"         >> "$CONFIG"
    ok "GPU configuré (${CONFIG})"
  else
    warn "config.txt introuvable — GPU non configuré"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 8. SCRIPT KIOSQUE
# ═══════════════════════════════════════════════════════════════════════════════
step "Création du script kiosque"
cat > "${PITV_DIR}/start-kiosk.sh" << KIOSK
#!/bin/bash
export DISPLAY=:0
export XAUTHORITY=/home/${KIOSK_USER}/.Xauthority

# Attendre le serveur (max 30s)
for i in \$(seq 1 30); do
  curl -s http://127.0.0.1:${PORT}/api/status >/dev/null 2>&1 && break
  sleep 1
done

xset -dpms s off 2>/dev/null || true
xset s noblank  2>/dev/null || true
unclutter -idle 2 -root &

${CHROMIUM_BIN} \\
  --kiosk \\
  --no-sandbox \\
  --disable-infobars \\
  --disable-session-crashed-bubble \\
  --disable-notifications \\
  --noerrdialogs \\
  --no-first-run \\
  --disable-translate \\
  --disable-extensions \\
  --disable-sync \\
  --use-gl=egl \\
  --enable-gpu-rasterization \\
  --enable-zero-copy \\
  --ignore-gpu-blacklist \\
  --start-fullscreen \\
  --app=http://127.0.0.1:${PORT}/ \\
  2>/dev/null
KIOSK
chmod +x "${PITV_DIR}/start-kiosk.sh"
ok "Script kiosque créé"

# Openbox autostart si mode Lite
if [[ "$HAS_DESKTOP" == "false" ]]; then
  mkdir -p /etc/xdg/openbox
  cat > /etc/xdg/openbox/autostart << OBAUTO
xset -dpms s off &
xset s noblank &
unclutter -idle 2 -root &
/opt/pitv/start-kiosk.sh &
OBAUTO
  ok "Openbox autostart configuré"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 9. SERVICES SYSTEMD
# ═══════════════════════════════════════════════════════════════════════════════
step "Création des services systemd"

cat > "/etc/systemd/system/${PITV_SERVICE}.service" << SERVICE
[Unit]
Description=PiTV OS - Serveur Node.js
After=network.target

[Service]
Type=simple
User=${KIOSK_USER}
WorkingDirectory=${PITV_DIR}
ExecStart=$(command -v node) ${PITV_DIR}/server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=${PORT}
StandardOutput=append:${PITV_DIR}/logs/server.log
StandardError=append:${PITV_DIR}/logs/server.error.log

[Install]
WantedBy=multi-user.target
SERVICE

cat > "/etc/systemd/system/${KIOSK_SERVICE}.service" << KSERVICE
[Unit]
Description=PiTV OS - Kiosque Chromium
After=${PITV_SERVICE}.service
Requires=${PITV_SERVICE}.service

[Service]
Type=simple
User=${KIOSK_USER}
Environment=HOME=/home/${KIOSK_USER}
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u ${KIOSK_USER} 2>/dev/null || echo 1000)
ExecStartPre=/bin/sleep 5
ExecStart=${PITV_DIR}/start-kiosk.sh
Restart=always
RestartSec=10
StandardOutput=append:${PITV_DIR}/logs/kiosk.log
StandardError=append:${PITV_DIR}/logs/kiosk.error.log

[Install]
WantedBy=graphical.target
KSERVICE

systemctl daemon-reload
systemctl enable "${PITV_SERVICE}" "${KIOSK_SERVICE}"
systemctl start  "${PITV_SERVICE}" && ok "Serveur démarré" || warn "Le serveur démarrera au prochain reboot"
ok "Services systemd activés"

# ═══════════════════════════════════════════════════════════════════════════════
# 10. COMMANDE pitv
# ═══════════════════════════════════════════════════════════════════════════════
step "Création de la commande 'pitv'"
cat > /usr/local/bin/pitv << 'MGMT'
#!/bin/bash
case "$1" in
  start)   systemctl start   pitv-server pitv-kiosk ;;
  stop)    systemctl stop    pitv-server pitv-kiosk ;;
  restart) systemctl restart pitv-server pitv-kiosk ;;
  status)  systemctl status  pitv-server pitv-kiosk ;;
  logs)    journalctl -u pitv-server -f ;;
  update)
    cd /opt/pitv
    git pull origin main
    npm install --production
    systemctl restart pitv-server
    echo "PiTV OS mis à jour !"
    ;;
  ip)      echo "http://$(hostname -I | awk '{print $1}'):8080" ;;
  *)       echo "Usage: pitv {start|stop|restart|status|logs|update|ip}" ;;
esac
MGMT
chmod +x /usr/local/bin/pitv
ok "Commande 'pitv' disponible"

# ═══════════════════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════════════════
IP=$(hostname -I | awk '{print $1}')
echo ""
hr
echo -e "\n  ${GREEN}${BOLD}✓ PiTV OS installé avec succès !${NC}\n"
hr
echo -e "  Accès local  : ${CYAN}http://127.0.0.1:${PORT}${NC}"
echo -e "  Accès réseau : ${CYAN}http://${IP}:${PORT}${NC}"
echo ""
echo -e "  ${DIM}pitv start / stop / restart / logs / update / ip${NC}"
hr

echo -ne "\n  Redémarrer maintenant ? [O/n] "
read -r ans
if [[ "$ans" =~ ^[nN] ]]; then
  echo -e "  ${CYAN}Tapez 'sudo reboot' quand vous êtes prêt.${NC}"
else
  echo -e "  ${GREEN}Redémarrage dans 3 secondes...${NC}"
  sleep 3
  reboot
fi
