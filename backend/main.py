#!/usr/bin/env python3
"""
GuardianPi - Routeur parental intelligent
Backend FastAPI principal
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

DEVICES_FILE = DATA_DIR / "devices.json"
RULES_FILE = DATA_DIR / "rules.json"
SCHEDULES_FILE = DATA_DIR / "schedules.json"
CONFIG_FILE = DATA_DIR / "config.json"
TOKENS_FILE = DATA_DIR / "tokens.json"
STATS_FILE = DATA_DIR / "stats.json"

BLOCKED_DOMAINS_FILE = Path("/etc/guardianpi/blocked_domains.conf")
WHITELIST_FILE = Path("/etc/guardianpi/whitelist.conf")

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
# HELPERS FICHIERS
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

# ─────────────────────────────────────────────
# AUTH
# ─────────────────────────────────────────────
security = HTTPBearer(auto_error=False)

def get_config():
    return load_json(CONFIG_FILE, {
        "username": "admin",
        "password_hash": hashlib.sha256(b"guardianpi").hexdigest(),
        "setup_done": False,
        "interface_wan": "eth0",
        "interface_lan": "wlan0",
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
    profile: Optional[str] = None  # "child", "teen", "adult", "custom"

class RuleCreate(BaseModel):
    mac: str
    type: str  # "block_category", "block_domain", "whitelist_domain"
    value: str
    enabled: bool = True

class ScheduleCreate(BaseModel):
    mac: str
    name: str
    days: List[str]  # ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    start_time: str  # "HH:MM"
    end_time: str    # "HH:MM"
    enabled: bool = True

class GlobalPauseRequest(BaseModel):
    paused: bool

# ─────────────────────────────────────────────
# APP
# ─────────────────────────────────────────────
app = FastAPI(title="GuardianPi API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─────────────────────────────────────────────
# RÉSEAU - FONCTIONS SYSTÈME
# ─────────────────────────────────────────────
def run_cmd(cmd: str, check=False) -> tuple[int, str, str]:
    """Exécute une commande shell."""
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return result.returncode, result.stdout.strip(), result.stderr.strip()

def get_connected_devices() -> List[Dict]:
    """Scan ARP + DHCP leases pour détecter les appareils."""
    devices = {}
    
    # Lire les leases DHCP
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
    
    # Scan ARP table
    code, out, _ = run_cmd("arp -n 2>/dev/null || ip neigh show 2>/dev/null")
    if code == 0:
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 3:
                ip = parts[0]
                # Format: IP ... MAC
                for i, p in enumerate(parts):
                    if ":" in p and len(p) == 17:
                        mac = p.lower()
                        if mac not in devices and mac != "00:00:00:00:00:00":
                            devices[mac] = {
                                "mac": mac,
                                "ip": ip,
                                "hostname": "Appareil inconnu",
                                "online": True,
                                "last_seen": datetime.now().isoformat()
                            }
    
    # Si pas de vrais résultats (dev mode), retourner données simulées
    if not devices:
        devices = {
            "aa:bb:cc:dd:ee:01": {"mac": "aa:bb:cc:dd:ee:01", "ip": "192.168.1.101", "hostname": "iPhone-Emma", "online": True, "last_seen": datetime.now().isoformat()},
            "aa:bb:cc:dd:ee:02": {"mac": "aa:bb:cc:dd:ee:02", "ip": "192.168.1.102", "hostname": "iPad-Léo", "online": True, "last_seen": datetime.now().isoformat()},
            "aa:bb:cc:dd:ee:03": {"mac": "aa:bb:cc:dd:ee:03", "ip": "192.168.1.103", "hostname": "Laptop-Papa", "online": False, "last_seen": (datetime.now() - timedelta(minutes=30)).isoformat()},
            "aa:bb:cc:dd:ee:04": {"mac": "aa:bb:cc:dd:ee:04", "ip": "192.168.1.104", "hostname": "TV-Salon", "online": True, "last_seen": datetime.now().isoformat()},
        }
    
    return list(devices.values())

def block_device_mac(mac: str, blocked: bool):
    """Bloque/débloque un appareil via iptables."""
    mac_clean = mac.replace("-", ":").upper()
    config = get_config()
    wan = config.get("interface_wan", "eth0")
    
    if blocked:
        # Bloquer tout trafic sortant pour ce MAC
        run_cmd(f"iptables -D FORWARD -m mac --mac-source {mac_clean} -j DROP 2>/dev/null")
        run_cmd(f"iptables -I FORWARD -m mac --mac-source {mac_clean} -j DROP")
    else:
        # Débloquer
        run_cmd(f"iptables -D FORWARD -m mac --mac-source {mac_clean} -j DROP 2>/dev/null")

def pause_device_mac(mac: str, paused: bool):
    """Pause internet pour un appareil (même que bloquer mais temporaire)."""
    block_device_mac(mac, paused)

def apply_global_pause(paused: bool):
    """Pause globale de tout le trafic sortant."""
    config = get_config()
    wan = config.get("interface_wan", "eth0")
    
    if paused:
        run_cmd(f"iptables -D FORWARD -o {wan} -j DROP 2>/dev/null")
        run_cmd(f"iptables -I FORWARD -o {wan} -j DROP")
        # Exclure le Pi lui-même
        local_ip = get_local_ip()
        if local_ip:
            run_cmd(f"iptables -I FORWARD -s {local_ip} -o {wan} -j ACCEPT")
    else:
        run_cmd(f"iptables -D FORWARD -o {wan} -j DROP 2>/dev/null")

def get_local_ip() -> str:
    code, out, _ = run_cmd("hostname -I | awk '{print $1}'")
    return out.strip() if code == 0 else ""

def rebuild_dnsmasq_blocklist():
    """Reconstruit la liste de blocage DNS depuis les règles actives."""
    rules = load_json(RULES_FILE, [])
    devices = load_json(DEVICES_FILE, {})
    
    blocked_domains = set()
    
    # Domaines bloqués globalement par catégorie
    for rule in rules:
        if not rule.get("enabled"):
            continue
        if rule["type"] == "block_category":
            cat = rule["value"]
            blocked_domains.update(CATEGORY_DOMAINS.get(cat, []))
        elif rule["type"] == "block_domain":
            blocked_domains.add(rule["value"])
    
    # Écrire le fichier dnsmasq
    lines = []
    for domain in sorted(blocked_domains):
        lines.append(f"address=/{domain}/0.0.0.0")
        lines.append(f"address=/.{domain}/0.0.0.0")
    
    BLOCKED_DOMAINS_FILE.parent.mkdir(parents=True, exist_ok=True)
    BLOCKED_DOMAINS_FILE.write_text("\n".join(lines) + "\n")
    
    # Recharger dnsmasq
    run_cmd("systemctl reload dnsmasq 2>/dev/null || pkill -HUP dnsmasq 2>/dev/null")

def save_iptables():
    """Sauvegarde les règles iptables pour persistance au reboot."""
    run_cmd("iptables-save > /etc/iptables/rules.v4 2>/dev/null")

# ─────────────────────────────────────────────
# TÂCHE DE FOND - SCHEDULER
# ─────────────────────────────────────────────
async def schedule_checker():
    """Vérifie les plannings toutes les minutes."""
    while True:
        try:
            now = datetime.now()
            day_map = {0: "mon", 1: "tue", 2: "wed", 3: "thu", 4: "fri", 5: "sat", 6: "sun"}
            current_day = day_map[now.weekday()]
            current_time = now.strftime("%H:%M")
            
            schedules = load_json(SCHEDULES_FILE, [])
            devices = load_json(DEVICES_FILE, {})
            
            for sched in schedules:
                if not sched.get("enabled"):
                    continue
                mac = sched["mac"]
                if current_day not in sched.get("days", []):
                    continue
                
                in_window = sched["start_time"] <= current_time <= sched["end_time"]
                
                # Si hors plage → couper internet
                device = devices.get(mac, {})
                should_block = not in_window
                
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
    # Restaurer l'état depuis la persistance
    restore_state()

def restore_state():
    """Restaure l'état après reboot."""
    devices = load_json(DEVICES_FILE, {})
    config = get_config()
    
    # Restaurer les blocages
    for mac, device in devices.items():
        if device.get("blocked") or device.get("schedule_blocked"):
            block_device_mac(mac, True)
    
    # Restaurer pause globale
    if config.get("global_pause"):
        apply_global_pause(True)
    
    # Reconstruire DNS
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
    tokens[token] = {
        "username": req.username,
        "expires": (datetime.now() + timedelta(hours=24)).isoformat()
    }
    save_json(TOKENS_FILE, tokens)
    
    return {"token": token, "expires_in": 86400}

@app.post("/api/auth/logout")
async def logout(auth = Depends(verify_token), credentials: HTTPAuthorizationCredentials = Depends(security)):
    tokens = load_json(TOKENS_FILE, {})
    tokens.pop(credentials.credentials, None)
    save_json(TOKENS_FILE, tokens)
    return {"ok": True}

@app.post("/api/auth/change-password")
async def change_password(req: ChangePasswordRequest, auth = Depends(verify_token)):
    config = get_config()
    current_hash = hashlib.sha256(req.current_password.encode()).hexdigest()
    if current_hash != config["password_hash"]:
        raise HTTPException(status_code=400, detail="Mot de passe actuel incorrect")
    config["password_hash"] = hashlib.sha256(req.new_password.encode()).hexdigest()
    save_json(CONFIG_FILE, config)
    return {"ok": True}

# ─────────────────────────────────────────────
# ROUTES APPAREILS
# ─────────────────────────────────────────────
@app.get("/api/devices")
async def get_devices(auth = Depends(verify_token)):
    live_devices = get_connected_devices()
    saved_devices = load_json(DEVICES_FILE, {})
    
    merged = []
    for d in live_devices:
        mac = d["mac"]
        saved = saved_devices.get(mac, {})
        merged.append({
            **d,
            "name": saved.get("name", d["hostname"]),
            "blocked": saved.get("blocked", False),
            "paused": saved.get("paused", False),
            "profile": saved.get("profile", "adult"),
            "schedule_blocked": saved.get("schedule_blocked", False),
            "total_online_minutes": saved.get("total_online_minutes", 0),
        })
    
    # Ajouter appareils offline connus
    for mac, saved in saved_devices.items():
        if not any(d["mac"] == mac for d in merged):
            merged.append({
                "mac": mac,
                "ip": saved.get("ip", "—"),
                "hostname": saved.get("hostname", "Inconnu"),
                "name": saved.get("name", saved.get("hostname", "Inconnu")),
                "online": False,
                "last_seen": saved.get("last_seen", ""),
                "blocked": saved.get("blocked", False),
                "paused": saved.get("paused", False),
                "profile": saved.get("profile", "adult"),
                "schedule_blocked": saved.get("schedule_blocked", False),
                "total_online_minutes": saved.get("total_online_minutes", 0),
            })
    
    # Sauvegarder l'état actuel
    for d in merged:
        if d["online"]:
            saved_devices[d["mac"]] = {
                **saved_devices.get(d["mac"], {}),
                "ip": d["ip"],
                "hostname": d["hostname"],
                "last_seen": datetime.now().isoformat(),
            }
    save_json(DEVICES_FILE, saved_devices)
    
    return merged

@app.patch("/api/devices/{mac}")
async def update_device(mac: str, update: DeviceUpdate, auth = Depends(verify_token)):
    mac = mac.lower().replace("-", ":")
    devices = load_json(DEVICES_FILE, {})
    device = devices.get(mac, {"mac": mac})
    
    if update.name is not None:
        device["name"] = update.name
    
    if update.blocked is not None:
        device["blocked"] = update.blocked
        block_device_mac(mac, update.blocked)
        save_iptables()
    
    if update.paused is not None:
        device["paused"] = update.paused
        pause_device_mac(mac, update.paused)
        save_iptables()
    
    if update.profile is not None:
        device["profile"] = update.profile
        # Appliquer profil automatique
        if update.profile == "child":
            # Bloquer adulte, jeux, réseaux sociaux
            for cat in ["adult", "gaming", "social"]:
                existing = load_json(RULES_FILE, [])
                if not any(r["mac"] == mac and r["type"] == "block_category" and r["value"] == cat for r in existing):
                    existing.append({"mac": mac, "type": "block_category", "value": cat, "enabled": True, "id": secrets.token_hex(8)})
                save_json(RULES_FILE, existing)
        elif update.profile == "teen":
            existing = load_json(RULES_FILE, [])
            if not any(r["mac"] == mac and r["type"] == "block_category" and r["value"] == "adult" for r in existing):
                existing.append({"mac": mac, "type": "block_category", "value": "adult", "enabled": True, "id": secrets.token_hex(8)})
            save_json(RULES_FILE, existing)
        rebuild_dnsmasq_blocklist()
    
    devices[mac] = device
    save_json(DEVICES_FILE, devices)
    
    return device

# ─────────────────────────────────────────────
# ROUTES RÈGLES
# ─────────────────────────────────────────────
@app.get("/api/rules")
async def get_rules(auth = Depends(verify_token)):
    return load_json(RULES_FILE, [])

@app.post("/api/rules")
async def create_rule(rule: RuleCreate, auth = Depends(verify_token)):
    rules = load_json(RULES_FILE, [])
    new_rule = {
        **rule.dict(),
        "id": secrets.token_hex(8),
        "created_at": datetime.now().isoformat()
    }
    rules.append(new_rule)
    save_json(RULES_FILE, rules)
    rebuild_dnsmasq_blocklist()
    return new_rule

@app.delete("/api/rules/{rule_id}")
async def delete_rule(rule_id: str, auth = Depends(verify_token)):
    rules = load_json(RULES_FILE, [])
    rules = [r for r in rules if r.get("id") != rule_id]
    save_json(RULES_FILE, rules)
    rebuild_dnsmasq_blocklist()
    return {"ok": True}

@app.patch("/api/rules/{rule_id}")
async def toggle_rule(rule_id: str, enabled: bool, auth = Depends(verify_token)):
    rules = load_json(RULES_FILE, [])
    for r in rules:
        if r.get("id") == rule_id:
            r["enabled"] = enabled
    save_json(RULES_FILE, rules)
    rebuild_dnsmasq_blocklist()
    return {"ok": True}

# ─────────────────────────────────────────────
# ROUTES PLANNINGS
# ─────────────────────────────────────────────
@app.get("/api/schedules")
async def get_schedules(auth = Depends(verify_token)):
    return load_json(SCHEDULES_FILE, [])

@app.post("/api/schedules")
async def create_schedule(sched: ScheduleCreate, auth = Depends(verify_token)):
    schedules = load_json(SCHEDULES_FILE, [])
    new_sched = {
        **sched.dict(),
        "id": secrets.token_hex(8),
        "created_at": datetime.now().isoformat()
    }
    schedules.append(new_sched)
    save_json(SCHEDULES_FILE, schedules)
    return new_sched

@app.delete("/api/schedules/{sched_id}")
async def delete_schedule(sched_id: str, auth = Depends(verify_token)):
    schedules = load_json(SCHEDULES_FILE, [])
    schedules = [s for s in schedules if s.get("id") != sched_id]
    save_json(SCHEDULES_FILE, schedules)
    return {"ok": True}

# ─────────────────────────────────────────────
# ROUTES GLOBAL
# ─────────────────────────────────────────────
@app.post("/api/global/pause")
async def set_global_pause(req: GlobalPauseRequest, auth = Depends(verify_token)):
    config = get_config()
    config["global_pause"] = req.paused
    save_json(CONFIG_FILE, config)
    apply_global_pause(req.paused)
    save_iptables()
    return {"paused": req.paused}

@app.get("/api/global/status")
async def get_global_status(auth = Depends(verify_token)):
    config = get_config()
    local_ip = get_local_ip()
    
    # Stats réseau
    code, rx, _ = run_cmd("cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null || echo 0")
    code, tx, _ = run_cmd("cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null || echo 0")
    
    # Uptime
    code, uptime, _ = run_cmd("uptime -p 2>/dev/null || echo 'inconnu'")
    
    # Temp CPU (Pi)
    code, temp, _ = run_cmd("cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0")
    temp_c = int(temp or 0) / 1000
    
    devices = load_json(DEVICES_FILE, {})
    online_count = sum(1 for d in get_connected_devices() if d.get("online"))
    
    return {
        "global_pause": config.get("global_pause", False),
        "local_ip": local_ip,
        "uptime": uptime,
        "cpu_temp": round(temp_c, 1),
        "rx_bytes": int(rx or 0),
        "tx_bytes": int(tx or 0),
        "online_devices": online_count,
        "total_devices": len(devices),
        "categories": list(CATEGORY_DOMAINS.keys())
    }

@app.get("/api/categories")
async def get_categories(auth = Depends(verify_token)):
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
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8080,
        reload=False,
        workers=1
    )
