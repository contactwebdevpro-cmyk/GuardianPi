#!/usr/bin/env python3
"""
GuardianPi - Routeur parental intelligent (Mode Hotspot WiFi)
Backend FastAPI principal v2.0
"""

import os
import json
import time
import asyncio
import hashlib
import secrets
import subprocess
from datetime import datetime, timedelta
from typing import Optional, List, Dict
from pathlib import Path

from fastapi import FastAPI, HTTPException, Depends, status, BackgroundTasks
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, FileResponse
from pydantic import BaseModel
import uvicorn

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────
DATA_DIR = Path("/etc/guardianpi/data")
DATA_DIR.mkdir(parents=True, exist_ok=True)

DEVICES_FILE        = DATA_DIR / "devices.json"
RULES_FILE          = DATA_DIR / "rules.json"
SCHEDULES_FILE      = DATA_DIR / "schedules.json"
CONFIG_FILE         = DATA_DIR / "config.json"
TOKENS_FILE         = DATA_DIR / "tokens.json"
BLOCKED_DOMAINS_FILE = Path("/etc/guardianpi/blocked_domains.conf")
HOSTAPD_CONF        = Path("/etc/hostapd/hostapd.conf")
DNSMASQ_CONF        = Path("/etc/dnsmasq.conf")

# ─────────────────────────────────────────────
# CATÉGORIES DE BLOCAGE DNS
# ─────────────────────────────────────────────
CATEGORY_DOMAINS = {
    "adult": [
        "pornhub.com", "xvideos.com", "xnxx.com", "redtube.com",
        "youporn.com", "tube8.com", "xhamster.com", "brazzers.com",
        "playboy.com", "onlyfans.com", "chaturbate.com", "livejasmin.com"
    ],
    "gambling": [
        "bet365.com", "pokerstars.com", "888casino.com", "betway.com",
        "draftkings.com", "fanduel.com", "williamhill.com", "ladbrokes.com"
    ],
    "social": [
        "tiktok.com", "instagram.com", "snapchat.com", "twitter.com",
        "x.com", "facebook.com", "reddit.com", "discord.com", "twitch.tv"
    ],
    "streaming": [
        "netflix.com", "youtube.com", "disney.com", "hbomax.com",
        "primevideo.com", "hulu.com", "crunchyroll.com", "dailymotion.com"
    ],
    "gaming": [
        "steam.com", "epicgames.com", "roblox.com", "minecraft.net",
        "fortnite.com", "leagueoflegends.com", "battle.net", "ea.com",
        "ubisoft.com", "xbox.com", "playstation.com"
    ],
    "ads": [
        "doubleclick.net", "googlesyndication.com", "adnxs.com",
        "advertising.com", "taboola.com", "outbrain.com"
    ]
}

# ─────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────
def load_json(path: Path, default=None):
    try:
        if path.exists():
            return json.loads(path.read_text())
    except Exception:
        pass
    return default if default is not None else {}

def save_json(path: Path, data):
    path.write_text(json.dumps(data, indent=2, default=str))

def run_cmd(cmd: str, check=False) -> tuple:
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return result.returncode, result.stdout.strip(), result.stderr.strip()

# ─────────────────────────────────────────────
# AUTH
# ─────────────────────────────────────────────
security = HTTPBearer(auto_error=False)

def get_config():
    return load_json(CONFIG_FILE, {
        "username": "admin",
        "password_hash": hashlib.sha256(b"guardianpi").hexdigest(),
        "mode": "hotspot",
        "interface_wan": "eth0",
        "interface_ap": "wlan0",
        "ap_ip": "192.168.4.1",
        "ap_ssid": "GuardianPi",
        "ap_passphrase": "guardianpi123",
        "ap_channel": 6,
        "ap_country": "FR",
        "dhcp_start": "192.168.4.100",
        "dhcp_end": "192.168.4.200",
        "global_pause": False
    })

def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    if not credentials:
        raise HTTPException(status_code=401, detail="Non authentifié")
    tokens = load_json(TOKENS_FILE, {})
    token = credentials.credentials
    if token not in tokens:
        raise HTTPException(status_code=401, detail="Token invalide")
    token_data = tokens[token]
    if datetime.fromisoformat(token_data["expires"]) < datetime.now():
        del tokens[token]
        save_json(TOKENS_FILE, tokens)
        raise HTTPException(status_code=401, detail="Token expiré")
    return token_data

# ─────────────────────────────────────────────
# MODÈLES
# ─────────────────────────────────────────────
class LoginRequest(BaseModel):
    username: str
    password: str

class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str

class DeviceUpdate(BaseModel):
    name: Optional[str] = None
    blocked: Optional[bool] = None
    paused: Optional[bool] = None
    profile: Optional[str] = None

class RuleCreate(BaseModel):
    mac: str
    type: str
    value: str
    enabled: bool = True

class ScheduleCreate(BaseModel):
    mac: str
    name: str
    days: List[str]
    start_time: str
    end_time: str
    enabled: bool = True

class GlobalPauseRequest(BaseModel):
    paused: bool

class WifiConfigRequest(BaseModel):
    """Mise à jour de la configuration du hotspot WiFi."""
    ssid: Optional[str] = None
    passphrase: Optional[str] = None
    channel: Optional[int] = None
    country: Optional[str] = None

# ─────────────────────────────────────────────
# APP
# ─────────────────────────────────────────────
app = FastAPI(title="GuardianPi API", version="2.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"],
)

# ─────────────────────────────────────────────
# RÉSEAU — FONCTIONS SYSTÈME
# ─────────────────────────────────────────────

def get_connected_devices() -> List[Dict]:
    """
    Lit les leases DHCP pour lister les appareils connectés au WiFi GuardianPi.
    Chaque appareil qui se connecte reçoit automatiquement une IP via DHCP.
    """
    devices = {}

    leases_paths = [
        "/var/lib/misc/dnsmasq.leases",
        "/var/lib/dnsmasq/dnsmasq.leases",
        "/tmp/dnsmasq.leases"
    ]
    for lpath in leases_paths:
        if os.path.exists(lpath):
            with open(lpath) as f:
                for line in f:
                    parts = line.strip().split()
                    if len(parts) >= 4:
                        _, mac, ip, name = parts[0], parts[1], parts[2], parts[3]
                        devices[mac.lower()] = {
                            "mac": mac.lower(),
                            "ip": ip,
                            "hostname": name if name != "*" else "Inconnu",
                            "online": True,
                            "last_seen": datetime.now().isoformat()
                        }

    # Compléter avec la table ARP (appareils sans lease actif mais encore en cache)
    code, out, _ = run_cmd("arp -n 2>/dev/null || ip neigh show 2>/dev/null")
    if code == 0:
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 3:
                ip = parts[0]
                for p in parts:
                    if ":" in p and len(p) == 17:
                        mac = p.lower()
                        if mac not in devices and mac != "00:00:00:00:00:00":
                            # Vérifier si l'IP est dans le sous-réseau AP (192.168.4.x)
                            if ip.startswith("192.168.4."):
                                devices[mac] = {
                                    "mac": mac, "ip": ip,
                                    "hostname": "Appareil inconnu",
                                    "online": True,
                                    "last_seen": datetime.now().isoformat()
                                }

    # Mode développement : données simulées
    if not devices:
        devices = {
            "aa:bb:cc:dd:ee:01": {"mac": "aa:bb:cc:dd:ee:01", "ip": "192.168.4.101", "hostname": "iPhone-Emma",   "online": True,  "last_seen": datetime.now().isoformat()},
            "aa:bb:cc:dd:ee:02": {"mac": "aa:bb:cc:dd:ee:02", "ip": "192.168.4.102", "hostname": "iPad-Léo",      "online": True,  "last_seen": datetime.now().isoformat()},
            "aa:bb:cc:dd:ee:03": {"mac": "aa:bb:cc:dd:ee:03", "ip": "192.168.4.103", "hostname": "Laptop-Papa",   "online": False, "last_seen": (datetime.now() - timedelta(minutes=30)).isoformat()},
            "aa:bb:cc:dd:ee:04": {"mac": "aa:bb:cc:dd:ee:04", "ip": "192.168.4.104", "hostname": "TV-Salon",      "online": True,  "last_seen": datetime.now().isoformat()},
        }

    return list(devices.values())

def get_wifi_clients_count() -> int:
    """Nombre d'appareils actuellement connectés au hotspot WiFi."""
    code, out, _ = run_cmd("iw dev wlan0 station dump 2>/dev/null | grep -c 'Station' || echo 0")
    try:
        return int(out.strip())
    except Exception:
        return len([d for d in get_connected_devices() if d.get("online")])

def normalize_mac(mac: str) -> str:
    """Normalise une adresse MAC en minuscules avec ':'"""
    return mac.replace("-", ":").lower()

def block_device_mac(mac: str, blocked: bool):
    """Bloque/débloque un appareil via iptables (par adresse MAC).
    
    FIX: - MAC normalisé en minuscules (iptables est case-sensitive avec --mac-source)
         - Déconnecte l'appareil du WiFi via hostapd si bloqué (sinon il garde sa session)
         - Bloque aussi INPUT/OUTPUT pour couper totalement (pas seulement FORWARD)
    """
    mac_norm = normalize_mac(mac)
    mac_upper = mac_norm.upper()  # iptables mac module accepte les deux, on force upper pour cohérence

    if blocked:
        # Supprimer les règles existantes d'abord (évite les doublons)
        run_cmd(f"iptables -D FORWARD -m mac --mac-source {mac_upper} -j DROP 2>/dev/null")
        # Insérer en tête de chaîne pour priorité maximale
        run_cmd(f"iptables -I FORWARD 1 -m mac --mac-source {mac_upper} -j DROP")
        # Bloquer aussi les nouvelles connexions INPUT (ex: requêtes DNS vers le Pi)
        run_cmd(f"iptables -D INPUT -m mac --mac-source {mac_upper} -j DROP 2>/dev/null")
        run_cmd(f"iptables -I INPUT 1 -m mac --mac-source {mac_upper} -j DROP")
        # Déconnecter l'appareil du WiFi immédiatement (sinon il garde sa session TCP)
        run_cmd(f"hostapd_cli -i wlan0 deauthenticate {mac_norm} 2>/dev/null || true")
    else:
        # Supprimer toutes les règles de blocage pour cette MAC
        run_cmd(f"iptables -D FORWARD -m mac --mac-source {mac_upper} -j DROP 2>/dev/null")
        run_cmd(f"iptables -D INPUT -m mac --mac-source {mac_upper} -j DROP 2>/dev/null")

def pause_device_mac(mac: str, paused: bool):
    block_device_mac(mac, paused)

def apply_global_pause(paused: bool):
    """Coupe/rétablit internet pour tous les appareils connectés au WiFi."""
    config = get_config()
    wan = config.get("interface_wan", "eth0")
    ap  = config.get("interface_ap",  "wlan0")
    if paused:
        run_cmd(f"iptables -D FORWARD -i {ap} -o {wan} -j DROP 2>/dev/null")
        run_cmd(f"iptables -I FORWARD -i {ap} -o {wan} -j DROP")
    else:
        run_cmd(f"iptables -D FORWARD -i {ap} -o {wan} -j DROP 2>/dev/null")

def get_ap_ip() -> str:
    return get_config().get("ap_ip", "192.168.4.1")

def rebuild_dnsmasq_blocklist():
    """Reconstruit la liste de blocage DNS.

    FIX syntaxe dnsmasq :
      - address=/domain/0.0.0.0 couvre déjà domain ET tous ses sous-domaines
        (l'ancienne ligne address=/.domain/0.0.0.0 était invalide et ignorée)
      - Ajout du blocage IPv6 (::) sinon les appareils passent par AAAA
    """
    rules = load_json(RULES_FILE, [])
    blocked_domains = set()
    for rule in rules:
        if not rule.get("enabled"):
            continue
        if rule["type"] == "block_category":
            blocked_domains.update(CATEGORY_DOMAINS.get(rule["value"], []))
        elif rule["type"] == "block_domain":
            blocked_domains.add(rule["value"])

    lines = []
    for domain in sorted(blocked_domains):
        lines.append(f"address=/{domain}/0.0.0.0")  # IPv4 + tous sous-domaines
        lines.append(f"address=/{domain}/::")         # IPv6

    BLOCKED_DOMAINS_FILE.parent.mkdir(parents=True, exist_ok=True)
    BLOCKED_DOMAINS_FILE.write_text("\n".join(lines) + "\n")

    run_cmd("systemctl restart dnsmasq 2>/dev/null")
    import time as _time; _time.sleep(1)

def rebuild_hostapd_conf(ssid: str, passphrase: str, channel: int, country: str, ap_if: str = "wlan0"):
    """Réécrit le fichier hostapd.conf et redémarre le hotspot."""
    conf = f"""# GuardianPi Hotspot (mis à jour via dashboard)
interface={ap_if}
driver=nl80211
ssid={ssid}
hw_mode=g
channel={channel}
country_code={country}
ieee80211n=1
wmm_enabled=1

auth_algs=1
wpa=2
wpa_passphrase={passphrase}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
macaddr_acl=0
ignore_broadcast_ssid=0
"""
    HOSTAPD_CONF.parent.mkdir(parents=True, exist_ok=True)
    HOSTAPD_CONF.write_text(conf)
    run_cmd("systemctl restart hostapd 2>/dev/null")

def rebuild_dnsmasq_conf(ap_if: str, ap_ip: str, dhcp_start: str, dhcp_end: str):
    """Réécrit dnsmasq.conf avec les nouvelles plages DHCP."""
    conf = f"""# GuardianPi — DHCP + DNS (mis à jour)
interface={ap_if}
bind-interfaces
listen-address={ap_ip}
no-resolv
server=1.1.1.1
server=8.8.8.8
server=9.9.9.9
cache-size=1000
local-ttl=0
neg-ttl=0
no-negcache
dhcp-range={dhcp_start},{dhcp_end},255.255.255.0,12h
dhcp-option=option:router,{ap_ip}
dhcp-option=option:dns-server,{ap_ip}
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
conf-file=/etc/guardianpi/blocked_domains.conf
"""
    DNSMASQ_CONF.write_text(conf)
    run_cmd("systemctl restart dnsmasq 2>/dev/null")

def save_iptables():
    run_cmd("iptables-save > /etc/iptables/rules.v4 2>/dev/null")

# ─────────────────────────────────────────────
# SCHEDULER
# ─────────────────────────────────────────────
async def schedule_checker():
    while True:
        try:
            now = datetime.now()
            day_map = {0:"mon",1:"tue",2:"wed",3:"thu",4:"fri",5:"sat",6:"sun"}
            current_day  = day_map[now.weekday()]
            current_time = now.strftime("%H:%M")
            schedules = load_json(SCHEDULES_FILE, [])
            devices   = load_json(DEVICES_FILE, {})
            for sched in schedules:
                if not sched.get("enabled") or current_day not in sched.get("days", []):
                    continue
                mac = sched["mac"]
                in_window = sched["start_time"] <= current_time <= sched["end_time"]
                should_block = not in_window
                device = devices.get(mac, {})
                if device.get("schedule_blocked") != should_block:
                    device["schedule_blocked"] = should_block
                    devices[mac] = device
                    block_device_mac(mac, should_block)
            save_json(DEVICES_FILE, devices)
        except Exception as e:
            print(f"Scheduler error: {e}")
        await asyncio.sleep(60)

@app.on_event("startup")
async def startup_event():
    asyncio.create_task(schedule_checker())
    restore_state()


def setup_dns_intercept(ap_if: str = "wlan0"):
    """Force tout le trafic DNS des appareils à passer par dnsmasq du Pi.

    Sans ces règles, les appareils peuvent contourner le blocage en utilisant
    leur propre DNS (8.8.8.8 codé en dur, DoH, etc.).

    - Redirige tout UDP/TCP port 53 venant du WiFi vers le Pi lui-même
    - Bloque DNS-over-TLS (port 853) pour éviter le contournement
    - Bloque les IPs des principaux serveurs DoH/DoT connus
    """
    # Supprimer les règles existantes pour éviter les doublons
    run_cmd(f"iptables -t nat -D PREROUTING -i {ap_if} -p udp --dport 53 -j REDIRECT --to-port 53 2>/dev/null")
    run_cmd(f"iptables -t nat -D PREROUTING -i {ap_if} -p tcp --dport 53 -j REDIRECT --to-port 53 2>/dev/null")

    # Rediriger TOUT le DNS (port 53) vers le Pi → dnsmasq intercepte tout
    run_cmd(f"iptables -t nat -A PREROUTING -i {ap_if} -p udp --dport 53 -j REDIRECT --to-port 53")
    run_cmd(f"iptables -t nat -A PREROUTING -i {ap_if} -p tcp --dport 53 -j REDIRECT --to-port 53")

    # Bloquer DNS-over-TLS (port 853) — contournement chiffré
    run_cmd(f"iptables -D FORWARD -i {ap_if} -p tcp --dport 853 -j DROP 2>/dev/null")
    run_cmd(f"iptables -D FORWARD -i {ap_if} -p udp --dport 853 -j DROP 2>/dev/null")
    run_cmd(f"iptables -A FORWARD -i {ap_if} -p tcp --dport 853 -j DROP")
    run_cmd(f"iptables -A FORWARD -i {ap_if} -p udp --dport 853 -j DROP")

    # Bloquer les IPs des serveurs DoH/DoT les plus utilisés
    doh_ips = [
        "1.1.1.1", "1.0.0.1",       # Cloudflare
        "8.8.8.8", "8.8.4.4",       # Google
        "9.9.9.9", "149.112.112.112", # Quad9
        "208.67.222.222", "208.67.220.220",  # OpenDNS
    ]
    for ip in doh_ips:
        run_cmd(f"iptables -D FORWARD -i {ap_if} -d {ip} -p udp --dport 53 -j DROP 2>/dev/null")
        run_cmd(f"iptables -D FORWARD -i {ap_if} -d {ip} -p tcp --dport 53 -j DROP 2>/dev/null")
        run_cmd(f"iptables -A FORWARD -i {ap_if} -d {ip} -p udp --dport 53 -j DROP")
        run_cmd(f"iptables -A FORWARD -i {ap_if} -d {ip} -p tcp --dport 53 -j DROP")

def restore_state():
    """Restaure l'état au démarrage du service.
    
    FIX: - Vider les règles iptables orphelines avant de réappliquer
         - Reconstruire le blocklist DNS
         - Vérifier que dnsmasq tourne avant de rebuild
    """
    import time as _time

    # Vider les règles FORWARD/INPUT existantes pour repartir propre
    run_cmd("iptables -F FORWARD 2>/dev/null")
    run_cmd("iptables -F INPUT 2>/dev/null")

    # Remettre les règles de base (NAT forward + firewall)
    config  = get_config()
    wan = config.get("interface_wan", "eth0")
    ap  = config.get("interface_ap",  "wlan0")
    run_cmd(f"iptables -A FORWARD -i {ap} -o {wan} -j ACCEPT")
    run_cmd(f"iptables -A FORWARD -i {wan} -o {ap} -m state --state ESTABLISHED,RELATED -j ACCEPT")
    run_cmd("iptables -A INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true")
    run_cmd("iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true")
    run_cmd(f"iptables -A INPUT -i {ap} -p udp --dport 53 -j ACCEPT 2>/dev/null || true")
    run_cmd(f"iptables -A INPUT -i {ap} -p udp --dport 67 -j ACCEPT 2>/dev/null || true")
    run_cmd("iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true")
    run_cmd("iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true")

    # Intercepter tout le DNS des appareils → ils ne peuvent plus contourner le blocage
    config2 = get_config()
    setup_dns_intercept(config2.get("interface_ap", "wlan0"))

    # Réappliquer les blocages par appareil
    devices = load_json(DEVICES_FILE, {})
    for mac, device in devices.items():
        if device.get("blocked") or device.get("schedule_blocked"):
            block_device_mac(mac, True)

    # Pause globale
    if config.get("global_pause"):
        apply_global_pause(True)

    # Attendre que dnsmasq soit prêt avant de rebuild
    for _ in range(5):
        rc, _, _ = run_cmd("systemctl is-active dnsmasq 2>/dev/null")
        if rc == 0:
            break
        _time.sleep(1)

    rebuild_dnsmasq_blocklist()

# ─────────────────────────────────────────────
# ROUTES AUTH
# ─────────────────────────────────────────────
@app.post("/api/auth/login")
async def login(req: LoginRequest):
    config = get_config()
    pw_hash = hashlib.sha256(req.password.encode()).hexdigest()
    if req.username != config["username"] or pw_hash != config["password_hash"]:
        raise HTTPException(status_code=401, detail="Identifiants incorrects")
    token = secrets.token_urlsafe(32)
    tokens = load_json(TOKENS_FILE, {})
    tokens[token] = {"username": req.username, "expires": (datetime.now() + timedelta(hours=24)).isoformat()}
    save_json(TOKENS_FILE, tokens)
    return {"token": token, "expires_in": 86400}

@app.post("/api/auth/logout")
async def logout(auth=Depends(verify_token), credentials: HTTPAuthorizationCredentials=Depends(security)):
    tokens = load_json(TOKENS_FILE, {})
    tokens.pop(credentials.credentials, None)
    save_json(TOKENS_FILE, tokens)
    return {"ok": True}

@app.post("/api/auth/change-password")
async def change_password(req: ChangePasswordRequest, auth=Depends(verify_token)):
    config = get_config()
    if hashlib.sha256(req.current_password.encode()).hexdigest() != config["password_hash"]:
        raise HTTPException(status_code=400, detail="Mot de passe actuel incorrect")
    config["password_hash"] = hashlib.sha256(req.new_password.encode()).hexdigest()
    save_json(CONFIG_FILE, config)
    return {"ok": True}

# ─────────────────────────────────────────────
# ROUTES WIFI / HOTSPOT
# ─────────────────────────────────────────────
@app.get("/api/wifi")
async def get_wifi_config(auth=Depends(verify_token)):
    """Retourne la configuration du hotspot WiFi et les stats de connexion."""
    config = get_config()

    # Statut hostapd
    code, _, _ = run_cmd("systemctl is-active hostapd 2>/dev/null")
    hostapd_active = (code == 0)

    # Nombre d'appareils WiFi connectés (via iw)
    code2, iw_out, _ = run_cmd("iw dev wlan0 station dump 2>/dev/null")
    wifi_clients = iw_out.count("Station") if code2 == 0 else 0

    # Clients DHCP actifs
    dhcp_leases = []
    lpath = "/var/lib/misc/dnsmasq.leases"
    if os.path.exists(lpath):
        with open(lpath) as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 4:
                    dhcp_leases.append({
                        "mac": parts[1],
                        "ip": parts[2],
                        "hostname": parts[3] if parts[3] != "*" else "Inconnu"
                    })

    return {
        "hotspot_active": hostapd_active,
        "ssid": config.get("ap_ssid", "GuardianPi"),
        "channel": config.get("ap_channel", 6),
        "country": config.get("ap_country", "FR"),
        "ap_ip": config.get("ap_ip", "192.168.4.1"),
        "dhcp_start": config.get("dhcp_start", "192.168.4.100"),
        "dhcp_end": config.get("dhcp_end", "192.168.4.200"),
        "wifi_clients": wifi_clients,
        "dhcp_leases": dhcp_leases,
        # Ne jamais retourner le mot de passe en clair
        "passphrase_set": bool(config.get("ap_passphrase")),
    }

@app.put("/api/wifi")
async def update_wifi_config(req: WifiConfigRequest, auth=Depends(verify_token)):
    """
    Met à jour le SSID, le mot de passe ou le canal WiFi.
    Redémarre automatiquement hostapd — les appareils devront se reconnecter.
    """
    config = get_config()

    if req.ssid is not None:
        if len(req.ssid) < 1 or len(req.ssid) > 32:
            raise HTTPException(status_code=400, detail="SSID invalide (1–32 caractères)")
        config["ap_ssid"] = req.ssid

    if req.passphrase is not None:
        if len(req.passphrase) < 8 or len(req.passphrase) > 63:
            raise HTTPException(status_code=400, detail="Mot de passe WiFi invalide (8–63 caractères)")
        config["ap_passphrase"] = req.passphrase

    if req.channel is not None:
        if req.channel not in range(1, 14):
            raise HTTPException(status_code=400, detail="Canal invalide (1–13)")
        config["ap_channel"] = req.channel

    if req.country is not None:
        config["ap_country"] = req.country.upper()

    save_json(CONFIG_FILE, config)

    # Reconstruire et redémarrer hostapd
    rebuild_hostapd_conf(
        ssid       = config["ap_ssid"],
        passphrase = config["ap_passphrase"],
        channel    = config["ap_channel"],
        country    = config["ap_country"],
        ap_if      = config.get("interface_ap", "wlan0")
    )

    return {
        "ok": True,
        "ssid": config["ap_ssid"],
        "channel": config["ap_channel"],
        "message": "Hotspot redémarré. Les appareils doivent se reconnecter au WiFi."
    }

@app.post("/api/wifi/restart")
async def restart_hotspot(auth=Depends(verify_token)):
    """Redémarre le hotspot WiFi (utile après un problème de connexion)."""
    run_cmd("systemctl restart hostapd 2>/dev/null")
    run_cmd("systemctl restart dnsmasq 2>/dev/null")
    config = get_config()
    setup_dns_intercept(config.get("interface_ap", "wlan0"))
    return {"ok": True, "message": "Hotspot redémarré"}

# ─────────────────────────────────────────────
# ROUTES APPAREILS
# ─────────────────────────────────────────────
@app.get("/api/devices")
async def get_devices(auth=Depends(verify_token)):
    live_devices  = get_connected_devices()
    saved_devices = load_json(DEVICES_FILE, {})
    merged = []
    for d in live_devices:
        mac   = d["mac"]
        saved = saved_devices.get(mac, {})
        merged.append({
            **d,
            "name":              saved.get("name", d["hostname"]),
            "blocked":           saved.get("blocked", False),
            "paused":            saved.get("paused", False),
            "profile":           saved.get("profile", "adult"),
            "schedule_blocked":  saved.get("schedule_blocked", False),
            "total_online_minutes": saved.get("total_online_minutes", 0),
        })
    for mac, saved in saved_devices.items():
        if not any(d["mac"] == mac for d in merged):
            merged.append({
                "mac":    mac,
                "ip":     saved.get("ip", "—"),
                "hostname": saved.get("hostname", "Inconnu"),
                "name":   saved.get("name", saved.get("hostname", "Inconnu")),
                "online": False,
                "last_seen": saved.get("last_seen", ""),
                "blocked": saved.get("blocked", False),
                "paused":  saved.get("paused", False),
                "profile": saved.get("profile", "adult"),
                "schedule_blocked": saved.get("schedule_blocked", False),
                "total_online_minutes": saved.get("total_online_minutes", 0),
            })
    for d in merged:
        if d["online"]:
            saved_devices[d["mac"]] = {
                **saved_devices.get(d["mac"], {}),
                "ip": d["ip"], "hostname": d["hostname"],
                "last_seen": datetime.now().isoformat(),
            }
    save_json(DEVICES_FILE, saved_devices)
    return merged

@app.patch("/api/devices/{mac}")
async def update_device(mac: str, update: DeviceUpdate, auth=Depends(verify_token)):
    # FIX: normaliser systématiquement la MAC pour cohérence avec iptables
    mac = normalize_mac(mac)
    devices = load_json(DEVICES_FILE, {})
    device  = devices.get(mac, {"mac": mac})

    if update.name     is not None: device["name"] = update.name
    if update.blocked  is not None:
        device["blocked"] = update.blocked
        block_device_mac(mac, update.blocked)
        save_iptables()
        if not update.blocked:
            # Déblocage : restart dnsmasq pour vider le cache → réponses propres immédiatement
            run_cmd("systemctl restart dnsmasq 2>/dev/null")
    if update.paused   is not None:
        device["paused"] = update.paused
        pause_device_mac(mac, update.paused)
        save_iptables()
    if update.profile  is not None:
        device["profile"] = update.profile
        existing = load_json(RULES_FILE, [])
        if update.profile == "child":
            for cat in ["adult", "gaming", "social"]:
                if not any(r["mac"]==mac and r["type"]=="block_category" and r["value"]==cat for r in existing):
                    existing.append({"mac":mac,"type":"block_category","value":cat,"enabled":True,"id":secrets.token_hex(8)})
        elif update.profile == "teen":
            if not any(r["mac"]==mac and r["type"]=="block_category" and r["value"]=="adult" for r in existing):
                existing.append({"mac":mac,"type":"block_category","value":"adult","enabled":True,"id":secrets.token_hex(8)})
        save_json(RULES_FILE, existing)
        rebuild_dnsmasq_blocklist()

    devices[mac] = device
    save_json(DEVICES_FILE, devices)
    return device

@app.post("/api/dns/flush-cache")
async def flush_dns_cache(auth=Depends(verify_token)):
    """Vide le cache DNS de dnsmasq — à appeler après tout déblocage."""
    run_cmd("systemctl restart dnsmasq 2>/dev/null")
    import time as _t; _t.sleep(1)
    rc, _, _ = run_cmd("systemctl is-active dnsmasq 2>/dev/null")
    return {"ok": rc == 0, "message": "Cache DNS vidé — les appareils verront le changement immédiatement"}

@app.post("/api/devices/{mac}/kick")
async def kick_device(mac: str, auth=Depends(verify_token)):
    """Déconnecte immédiatement un appareil du WiFi (deauth)."""
    mac_norm = normalize_mac(mac)
    rc, out, err = run_cmd(f"hostapd_cli -i wlan0 deauthenticate {mac_norm} 2>/dev/null")
    return {"ok": rc == 0, "mac": mac_norm, "detail": out or err}

@app.get("/api/debug/iptables")
async def debug_iptables(auth=Depends(verify_token)):
    """Retourne les règles iptables actives (pour diagnostic)."""
    _, forward, _ = run_cmd("iptables -L FORWARD -n -v 2>/dev/null")
    _, nat, _     = run_cmd("iptables -t nat -L POSTROUTING -n -v 2>/dev/null")
    _, input_, _  = run_cmd("iptables -L INPUT -n -v 2>/dev/null")
    _, dns_conf, _ = run_cmd("cat /etc/guardianpi/blocked_domains.conf 2>/dev/null || echo '(vide)'")
    _, dnsmasq_status, _ = run_cmd("systemctl is-active dnsmasq 2>/dev/null")
    return {
        "forward_rules": forward,
        "input_rules": input_,
        "nat_rules": nat,
        "blocked_domains_conf": dns_conf[:2000],
        "dnsmasq_active": dnsmasq_status.strip() == "active",
    }

# ─────────────────────────────────────────────
# ROUTES RÈGLES
# ─────────────────────────────────────────────
@app.get("/api/rules")
async def get_rules(auth=Depends(verify_token)):
    return load_json(RULES_FILE, [])

@app.post("/api/rules")
async def create_rule(rule: RuleCreate, auth=Depends(verify_token)):
    rules = load_json(RULES_FILE, [])
    new_rule = {**rule.dict(), "id": secrets.token_hex(8), "created_at": datetime.now().isoformat()}
    rules.append(new_rule)
    save_json(RULES_FILE, rules)
    rebuild_dnsmasq_blocklist()
    return new_rule

@app.delete("/api/rules/{rule_id}")
async def delete_rule(rule_id: str, auth=Depends(verify_token)):
    rules = [r for r in load_json(RULES_FILE, []) if r.get("id") != rule_id]
    save_json(RULES_FILE, rules)
    rebuild_dnsmasq_blocklist()
    return {"ok": True}

@app.patch("/api/rules/{rule_id}")
async def toggle_rule(rule_id: str, enabled: bool, auth=Depends(verify_token)):
    rules = load_json(RULES_FILE, [])
    for r in rules:
        if r.get("id") == rule_id: r["enabled"] = enabled
    save_json(RULES_FILE, rules)
    rebuild_dnsmasq_blocklist()
    return {"ok": True}

# ─────────────────────────────────────────────
# ROUTES PLANNINGS
# ─────────────────────────────────────────────
@app.get("/api/schedules")
async def get_schedules(auth=Depends(verify_token)):
    return load_json(SCHEDULES_FILE, [])

@app.post("/api/schedules")
async def create_schedule(sched: ScheduleCreate, auth=Depends(verify_token)):
    schedules = load_json(SCHEDULES_FILE, [])
    new_sched = {**sched.dict(), "id": secrets.token_hex(8), "created_at": datetime.now().isoformat()}
    schedules.append(new_sched)
    save_json(SCHEDULES_FILE, schedules)
    return new_sched

@app.delete("/api/schedules/{sched_id}")
async def delete_schedule(sched_id: str, auth=Depends(verify_token)):
    schedules = [s for s in load_json(SCHEDULES_FILE, []) if s.get("id") != sched_id]
    save_json(SCHEDULES_FILE, schedules)
    return {"ok": True}

# ─────────────────────────────────────────────
# ROUTES GLOBAL
# ─────────────────────────────────────────────
@app.post("/api/global/pause")
async def set_global_pause(req: GlobalPauseRequest, auth=Depends(verify_token)):
    config = get_config()
    config["global_pause"] = req.paused
    save_json(CONFIG_FILE, config)
    apply_global_pause(req.paused)
    save_iptables()
    return {"paused": req.paused}

@app.get("/api/global/status")
async def get_global_status(auth=Depends(verify_token)):
    config = get_config()
    ap_ip = config.get("ap_ip", "192.168.4.1")
    ap_if = config.get("interface_ap", "wlan0")
    wan_if = config.get("interface_wan", "eth0")

    # Stats réseau WiFi (interface AP)
    code, rx, _ = run_cmd(f"cat /sys/class/net/{ap_if}/statistics/rx_bytes 2>/dev/null || echo 0")
    code, tx, _ = run_cmd(f"cat /sys/class/net/{ap_if}/statistics/tx_bytes 2>/dev/null || echo 0")

    code, uptime, _ = run_cmd("uptime -p 2>/dev/null || echo 'inconnu'")
    code, temp, _   = run_cmd("cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0")
    temp_c = int(temp or 0) / 1000

    # Hostapd actif ?
    code_ap, _, _ = run_cmd("systemctl is-active hostapd 2>/dev/null")
    hotspot_active = (code_ap == 0)

    # Clients WiFi (iw)
    code_iw, iw_out, _ = run_cmd(f"iw dev {ap_if} station dump 2>/dev/null")
    wifi_clients = iw_out.count("Station") if code_iw == 0 else 0

    devices = load_json(DEVICES_FILE, {})
    online_count = sum(1 for d in get_connected_devices() if d.get("online"))

    return {
        "global_pause":   config.get("global_pause", False),
        "local_ip":       ap_ip,
        "uptime":         uptime,
        "cpu_temp":       round(temp_c, 1),
        "rx_bytes":       int(rx or 0),
        "tx_bytes":       int(tx or 0),
        "online_devices": online_count,
        "total_devices":  len(devices),
        "categories":     list(CATEGORY_DOMAINS.keys()),
        # Infos hotspot
        "hotspot_active": hotspot_active,
        "ap_ssid":        config.get("ap_ssid", "GuardianPi"),
        "wifi_clients":   wifi_clients,
        "mode":           "hotspot",
    }

@app.get("/api/categories")
async def get_categories(auth=Depends(verify_token)):
    return [{"id": k, "name": k, "domain_count": len(v)} for k, v in CATEGORY_DOMAINS.items()]

# ─────────────────────────────────────────────
# SERVIR FRONTEND
# ─────────────────────────────────────────────
frontend_dir = Path(__file__).parent.parent / "frontend" / "public"
if frontend_dir.exists():
    app.mount("/", StaticFiles(directory=str(frontend_dir), html=True), name="static")

# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=False, workers=1)
