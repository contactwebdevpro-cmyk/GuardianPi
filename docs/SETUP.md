# 📘 Guide de déploiement GuardianPi

## Étape 1 — Préparer la carte SD

### Télécharger Raspberry Pi Imager

→ https://www.raspberrypi.com/software/

### Configurer l'OS

1. Cliquez **CHOISIR L'OS**
2. Sélectionnez : `Raspberry Pi OS Lite (64-bit)`
   - "Lite" = pas d'interface graphique = plus léger et stable
3. Cliquez l'engrenage ⚙️ pour les options avancées :
   - **Hostname** : `guardianpi`
   - **Activer SSH** : ✅ (avec mot de passe)
   - **Username** : `pi`
   - **Password** : votre choix (notez-le !)
   - **Locale** : Europe/Paris, fr_FR
4. Flashez sur une carte SD ≥ 16 Go

---

## Étape 2 — Brancher le Raspberry Pi

### Configuration réseau recommandée

```
[Votre box internet]
        │
        │ Câble Ethernet CAT5e/6
        │
  [PORT ETH0 du Pi]  ← Entrée (WAN)
  [Raspberry Pi 3B]
  [WiFi wlan0]       ← Sortie (LAN, optionnel)
        │
        └── Vos appareils se connectent via le WiFi du Pi
            OU via un switch branché sur le Pi
```

### Configuration alternative (la plus simple)

Si vous ne voulez pas reconfigurer votre réseau :

1. Branchez le Pi à votre box (eth0)
2. Installez GuardianPi
3. Sur chaque appareil enfant : changez le **DNS** pour pointer vers l'IP du Pi
   - Exemple : DNS = `192.168.1.42` (IP du Pi)
   - Cela suffit pour le filtrage DNS des sites

---

## Étape 3 — Premier démarrage

1. Insérez la carte SD dans le Pi
2. Branchez l'alimentation (câble USB-C 5V/3A)
3. Attendez 90 secondes

### Se connecter en SSH

```bash
# Depuis votre PC (même réseau)
ssh pi@guardianpi.local

# Si ça ne marche pas, trouvez l'IP :
# Sur votre box : regarder les appareils connectés
# Chercher "guardianpi"
```

---

## Étape 4 — Installer GuardianPi

```bash
# Sur le Raspberry Pi, en SSH :
curl -sSL https://raw.githubusercontent.com/votre-repo/guardianpi/main/scripts/install.sh | sudo bash
```

Attendez 5–10 minutes. L'installation est entièrement automatique.

---

## Étape 5 — Accéder au dashboard

1. Notez l'IP affichée à la fin de l'installation (ex: `192.168.1.42`)
2. Depuis votre téléphone ou PC sur le même réseau :
   - Ouvrez le navigateur
   - Tapez : `http://192.168.1.42:8080`
3. Connectez-vous :
   - **Utilisateur** : `admin`
   - **Mot de passe** : `guardianpi`
4. **Changez immédiatement le mot de passe** dans Réglages !

---

## Étape 6 — Configuration initiale

### Nommer les appareils

1. Onglet **Accueil** (🏠)
2. Cliquez `⋯` sur chaque appareil
3. Donnez un nom : "iPhone Emma", "iPad Léo"
4. Choisissez le profil : Enfant / Ado / Adulte

### Bloquer les sites adultes

1. Onglet **Règles** (🚫)
2. Section "Filtrage par catégorie"
3. Toggle ON sur "🔞 Adultes"

### Définir des horaires

1. Onglet **Planning** (📅)
2. `+ Ajouter`
3. Exemple pour "iPad Léo" :
   - Nom : "Soir semaine"
   - Appareil : iPad Léo
   - Jours : Lun Mar Mer Jeu Ven
   - Internet autorisé de : 18:00 à 20:00
4. `Créer`

---

## Maintenance

### Sauvegarde configuration

```bash
# Sur le Pi :
sudo tar -czf ~/guardianpi-backup-$(date +%Y%m%d).tar.gz /etc/guardianpi
```

### Mise à jour

```bash
sudo bash /opt/guardianpi/scripts/update.sh
```

### Réinitialisation complète

```bash
sudo systemctl stop guardianpi
sudo rm -rf /etc/guardianpi/data/*.json
sudo systemctl start guardianpi
# Les identifiants reviennent à admin/guardianpi
```

---

## En cas de problème

```bash
# Diagnostic rapide
sudo bash /opt/guardianpi/scripts/diagnose.sh

# Logs en temps réel
journalctl -u guardianpi -f
```

---

*Temps total d'installation (carte SD incluse) : environ 20 minutes*
