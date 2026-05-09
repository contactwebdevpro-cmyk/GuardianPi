# 🛡️ GuardianPi — Routeur Parental Intelligent

**Plug & Play parental control router for home networks**

GuardianPi transforme un Raspberry Pi 3B en routeur parental complet, accessible via un beau dashboard web, sans aucune application à installer.

---

## 📸 Dashboard

Interface mobile-first, accessible depuis n'importe quel navigateur :

- `http://192.168.1.xxx:8080` (remplacez par votre IP locale)
- Identifiants par défaut : `admin` / `guardianpi`

---

## ✨ Fonctionnalités

### Contrôle par appareil
- 🔴 **Bloquer** instantanément un appareil
- ⏸️ **Pause internet** en 1 clic
- 👤 **Profils** : Enfant, Ado, Adulte (avec règles automatiques)
- 🏷️ **Nommez** vos appareils par prénom

### Filtrage de contenu
- 🔞 Blocage par catégorie : Adultes, Jeux d'argent, Réseaux sociaux, Streaming, Jeux vidéo, Publicités
- 🚫 Blocage de sites personnalisés
- ✅ Liste blanche (toujours autorisé)
- Filtrage par DNS (transparent, fonctionne sur tout appareil)

### Plannings horaires
- 📅 Internet uniquement de 18h à 20h du lundi au vendredi
- Par appareil, par jour de la semaine
- Coupure automatique hors des plages

### Pause globale
- ⏸️ Couper internet pour **toute la maison** en 1 clic
- 🏖️ **Mode vacances** : désactive temporairement toutes les restrictions

### Surveillance réseau
- Scan automatique des appareils connectés
- Affichage IP, MAC, nom, statut en ligne/hors ligne
- Température CPU et uptime du Pi

---

## 🔌 Comment brancher le Raspberry Pi

```
[Box Internet / Routeur]
         │
         │ (câble Ethernet)
         │
    [Raspberry Pi 3B]   ← GuardianPi installé ici
         │
         │ (WiFi ou second Ethernet)
         │
    [Switch / Appareils]
    ├── PC de bureau
    ├── iPhone Emma
    ├── iPad Léo
    └── TV Salon
```

Le Raspberry Pi agit comme **passerelle** entre votre box et vos appareils. Tout le trafic passe par lui.

> **Alternative simple** : Branchez le Pi entre votre box et votre switch/WiFi existant. Configurez vos appareils pour utiliser l'IP du Pi comme gateway et DNS.

---

## 🚀 Installation en 1 commande

Sur votre Raspberry Pi (avec Raspberry Pi OS Lite) :

```bash
curl -sSL https://raw.githubusercontent.com/votre-repo/guardianpi/main/scripts/install.sh | sudo bash
```

**Temps d'installation estimé : 5–10 minutes**

À la fin, le script affiche :
```
✅ GuardianPi installé avec succès !

📍 Accédez au dashboard :
   http://192.168.1.42:8080

🔐 Identifiants par défaut :
   Utilisateur : admin
   Mot de passe : guardianpi
```

---

## 🖥️ Prérequis

| Élément | Requis |
|---------|--------|
| Matériel | Raspberry Pi 3B (ou 3B+, 4) |
| OS | Raspberry Pi OS Lite (64-bit recommandé) |
| Connexion | Ethernet vers la box |
| Accès | SSH activé |

### Préparer le Raspberry Pi

1. Téléchargez [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Choisissez **Raspberry Pi OS Lite (64-bit)**
3. Dans les options avancées : activez SSH, définissez nom d'hôte `guardianpi`
4. Flashez la carte SD
5. Branchez et démarrez

---

## 📁 Structure du projet

```
guardianpi/
├── backend/
│   ├── main.py              # API FastAPI complète
│   └── requirements.txt
├── frontend/
│   └── public/
│       └── index.html       # Dashboard HTML/CSS/JS (single file)
├── scripts/
│   ├── install.sh           # Installation automatique
│   ├── update.sh            # Mise à jour
│   └── diagnose.sh          # Diagnostic
├── docs/
│   └── SETUP.md
└── README.md
```

---

## 🔧 Architecture technique

```
┌─────────────────────────────────────────────────────┐
│                   Raspberry Pi 3B                    │
│                                                     │
│  ┌──────────────┐    ┌─────────────────────────┐    │
│  │   dnsmasq    │    │    FastAPI Backend       │    │
│  │  (DNS + DHCP)│    │    (port 8080)           │    │
│  │              │    │                         │    │
│  │ • Blocage DNS│    │ • API REST              │    │
│  │ • DHCP local │    │ • Gestion iptables      │    │
│  └──────────────┘    │ • Plannings (asyncio)   │    │
│                      │ • Auth JWT              │    │
│  ┌──────────────┐    └─────────────────────────┘    │
│  │  iptables    │                                    │
│  │              │    ┌─────────────────────────┐    │
│  │ • Block MAC  │    │    Frontend (SPA)       │    │
│  │ • NAT        │    │    HTML + Tailwind-like │    │
│  │ • Firewall   │    │    (servi par FastAPI)  │    │
│  └──────────────┘    └─────────────────────────┘    │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │           Persistance (JSON + iptables)     │    │
│  │   /etc/guardianpi/data/                     │    │
│  │   ├── devices.json                          │    │
│  │   ├── rules.json                            │    │
│  │   ├── schedules.json                        │    │
│  │   └── config.json                           │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

### Composants

| Composant | Technologie | Rôle |
|-----------|-------------|------|
| Backend | Python FastAPI | API REST, logique métier |
| Frontend | HTML/CSS/JS vanilla | Dashboard (aucune dépendance) |
| DNS Filtering | dnsmasq | Blocage de sites par domaine |
| IP Filtering | iptables | Blocage par adresse MAC |
| Persistance | JSON files | Sauvegarde locale robuste |
| Service | systemd | Démarrage automatique |

---

## 🛡️ Sécurité

- 🔐 Authentification par token (session 24h)
- 🏠 Accès **LAN uniquement** (jamais exposé sur internet)
- 🔒 HTTPS optionnel avec certificat auto-signé
- 🔑 Mot de passe hashé (SHA-256)
- 📵 Aucune télémétrie, aucune donnée envoyée à l'extérieur

### Changer le mot de passe (IMPORTANT)

Via le dashboard : Réglages → Changer le mot de passe

Ou en ligne de commande :
```bash
# Sur le Raspberry Pi
NEW_HASH=$(echo -n 'votre-nouveau-mot-de-passe' | sha256sum | cut -d' ' -f1)
# Modifier /etc/guardianpi/data/config.json → password_hash
```

---

## 📖 Guide d'utilisation

### Bloquer un appareil (3 clics)

1. Ouvrez le dashboard
2. Trouvez l'appareil dans la liste
3. Cliquez le toggle → bloqué immédiatement

### Bloquer TikTok pour tous

1. Onglet **Règles** (🚫)
2. Section "Réseaux sociaux" → toggle OFF
3. TikTok, Instagram, Snapchat, Twitter sont bloqués

### Définir des horaires pour l'iPad de Léo

1. Onglet **Planning** (📅)
2. `+ Ajouter`
3. Sélectionner `iPad-Léo`
4. Nom : "Soir semaine", Lun–Ven, 18h00–20h00
5. `Créer` → Internet disponible uniquement 18h–20h

### Profils automatiques

| Profil | Bloque automatiquement |
|--------|------------------------|
| 👶 Enfant | Adultes + Jeux vidéo + Réseaux sociaux |
| 🧒 Ado | Adultes + Jeux d'argent |
| 👤 Adulte | Rien (accès complet) |

---

## 🔄 Après une coupure de courant

GuardianPi reprend automatiquement :
- ✅ Service redémarre via systemd
- ✅ Règles iptables restaurées
- ✅ Blocages DNS rechargés
- ✅ Appareils bloqués/en pause restaurés

**Aucune action manuelle nécessaire.**

---

## 🛠️ Commandes utiles

```bash
# Voir les logs en temps réel
journalctl -u guardianpi -f

# Redémarrer le service
sudo systemctl restart guardianpi

# Voir les appareils connectés
arp -n

# Diagnostic complet
sudo bash /opt/guardianpi/scripts/diagnose.sh

# Mise à jour
sudo bash /opt/guardianpi/scripts/update.sh

# Sauvegarder la configuration
cp -r /etc/guardianpi /tmp/guardianpi-backup-$(date +%Y%m%d)
```

---

## 🐛 Dépannage

### Dashboard inaccessible
```bash
# Vérifier que le service tourne
systemctl status guardianpi

# Vérifier le port
ss -tlnp | grep 8080

# Logs d'erreur
journalctl -u guardianpi -n 50
```

### DNS ne filtre pas
```bash
# Vérifier dnsmasq
systemctl status dnsmasq

# Tester le DNS
dig @192.168.100.1 facebook.com

# Voir les domaines bloqués
cat /etc/guardianpi/blocked_domains.conf
```

### Appareil non détecté
```bash
# Scan manuel
sudo nmap -sn 192.168.100.0/24

# Table ARP
arp -n
```

---

## 📦 FAQ

**Q: Fonctionne-t-il avec le WiFi de la box ?**  
R: Oui — vos appareils se connectent à votre WiFi normal, et le Pi intercepte le trafic via iptables/DNS.

**Q: Peut-on bypasser les blocages ?**  
R: Le blocage DNS peut être contourné avec un VPN. Le blocage MAC via iptables est plus robuste. Pour les enfants, c'est suffisant.

**Q: Le Pi ralentit-il internet ?**  
R: Négligeable. Le Pi 3B gère facilement 100 Mbps, largement suffisant pour une maison.

**Q: Fonctionne-t-il sans internet ?**  
R: Le LAN fonctionne toujours. Le dashboard est accessible même sans internet.

---

## 📄 Licence

MIT License — Libre d'utilisation, modification et distribution.

---

*GuardianPi — Protégez votre famille, simplement.*
