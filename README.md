# 🛡️ GuardianPi — Routeur Parental Intelligent (Mode Hotspot WiFi)

**Plug & Play parental control router — Le Pi crée son propre réseau WiFi**

GuardianPi transforme un Raspberry Pi 3B en **point d'accès WiFi** avec contrôle parental complet.
Les téléphones et tablettes se connectent au réseau "GuardianPi" → le filtrage est automatique, **aucune configuration DNS manuelle nécessaire**.

---

## 🔑 Pourquoi le Mode Hotspot ?

| Ancienne approche (DNS) | Nouvelle approche (Hotspot WiFi) |
|------------------------|----------------------------------|
| Fonctionne que si chaque appareil configure le Pi comme DNS | Transparent : aucune config sur les téléphones |
| Impossible sur iOS/Android (champ DNS inaccessible) | Les appareils se connectent au WiFi "GuardianPi" |
| Contournable en changeant de DNS | Le Pi est la passerelle → tout le trafic passe par lui |

---

## 🏗️ Architecture Réseau

```
[BOX INTERNET]
      │
      │ câble Ethernet (WAN)
      │
[RASPBERRY PI 3B]  ← IP fixe sur eth0 (reçue par DHCP depuis la box)
  hostapd (WiFi AP) → SSID : "GuardianPi"
  dnsmasq → DHCP : 192.168.4.100–200
  iptables → NAT wlan0 → eth0 + blocage MAC
      │
      │ 📶 WiFi "GuardianPi"
      │
  ├── 📱 iPhone Emma  → IP auto 192.168.4.101
  ├── 📱 iPad Léo     → IP auto 192.168.4.102
  ├── 💻 Laptop       → IP auto 192.168.4.103
  └── 📺 TV Salon     → IP auto 192.168.4.104
```

Quand un appareil se connecte au WiFi "GuardianPi", le Pi lui attribue automatiquement :
- Une adresse IP (DHCP)
- Sa propre adresse comme **passerelle** (tout le trafic passe par lui)
- Sa propre adresse comme **DNS** (filtrage transparent)

---

## 📱 Comment ça marche pour l'utilisateur

**Sur le téléphone de l'enfant :**
1. Réglages → WiFi → choisir **GuardianPi**
2. Entrer le mot de passe WiFi (configuré dans le dashboard)
3. Connecté → le filtrage parental est actif automatiquement ✓

**Aucune configuration DNS, aucune app à installer.**

---

## 🚀 Installation en 1 commande

```bash
sudo bash install.sh
```

**Prérequis :**
- Raspberry Pi 3B (ou 3B+, 4) avec WiFi intégré
- Câble Ethernet branché vers votre box (WAN)
- Raspberry Pi OS Lite (64-bit recommandé)
- SSH activé

---

## ✨ Fonctionnalités

### Gestion du Hotspot WiFi
- 📶 Création automatique du réseau WiFi "GuardianPi"
- 🔑 Changement SSID/mot de passe WiFi depuis le dashboard
- 📊 Voir les appareils connectés en temps réel
- 🔄 Redémarrage hotspot sans SSH

### Contrôle par appareil
- 🔴 **Bloquer** instantanément un appareil (iptables par MAC)
- ⏸️ **Pause internet** en 1 clic
- 👤 **Profils** : Enfant, Ado, Adulte
- 🏷️ Nommer vos appareils

### Filtrage de contenu
- 🔞 Blocage par catégorie (adultes, jeux, réseaux sociaux, streaming, etc.)
- 🚫 Blocage de sites personnalisés
- Filtrage DNS transparent (tous les appareils WiFi, sans config)

### Plannings horaires
- 📅 Internet uniquement sur des plages horaires
- Par appareil, par jour de la semaine
- Coupure automatique

---

## 🔧 Architecture technique

| Composant | Rôle |
|-----------|------|
| **hostapd** | Crée le point d'accès WiFi (SSID, WPA2) |
| **dnsmasq** | Distribue les IPs (DHCP) + filtre les DNS |
| **iptables** | NAT (WiFi→Internet) + blocage par MAC |
| **FastAPI** | Backend API + sert le dashboard |
| **systemd** | Démarrage automatique de tous les services |

### Flux réseau d'un appareil connecté

```
[Téléphone]
  → connecte au WiFi "GuardianPi"
  → reçoit IP 192.168.4.x via DHCP (dnsmasq)
  → gateway = 192.168.4.1 (Pi)
  → DNS = 192.168.4.1 (Pi → filtrage)
  → trafic HTTP/HTTPS → iptables FORWARD → eth0 → box → internet
  → si MAC bloqué → iptables DROP
  → si domaine bloqué → dnsmasq retourne 0.0.0.0
```

---

## 📍 Accès au Dashboard

Depuis un appareil connecté au WiFi GuardianPi :
```
http://192.168.4.1:8080
```

Depuis votre réseau principal (box) :
```
http://<IP_du_Pi>:8080
```

---

## 🛠️ Commandes utiles

```bash
# Voir les appareils connectés au WiFi
cat /var/lib/misc/dnsmasq.leases

# Statut du hotspot
systemctl status hostapd

# Statut DHCP/DNS
systemctl status dnsmasq

# Logs temps réel
journalctl -u guardianpi -f
journalctl -u hostapd -f

# Redémarrer tout
sudo systemctl restart hostapd dnsmasq guardianpi

# Voir les règles de blocage MAC
sudo iptables -L FORWARD -n -v
```

---

## 🐛 Dépannage

### Le WiFi "GuardianPi" n'apparaît pas
```bash
systemctl status hostapd
journalctl -u hostapd -n 30
# Vérifier que wlan0 existe
ip link show wlan0
```

### Les appareils ne reçoivent pas d'IP
```bash
systemctl status dnsmasq
# Vérifier l'IP statique de wlan0
ip addr show wlan0
# Elle doit être 192.168.4.1/24
```

### Pas d'internet sur les appareils connectés
```bash
# Vérifier le forwarding
cat /proc/sys/net/ipv4/ip_forward
# Doit afficher : 1

# Vérifier le NAT
sudo iptables -t nat -L POSTROUTING -n -v
# Doit avoir une règle MASQUERADE sur eth0
```

---

## 📄 Licence
MIT — Libre d'utilisation, modification et distribution.
