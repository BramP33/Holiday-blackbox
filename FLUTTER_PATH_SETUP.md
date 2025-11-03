# Flutter PATH Setup Guide

## Problem
Na het installeren van Flutter via VS Code is de `flutter` command niet beschikbaar in je terminal.

## Quick Fix

### Optie 1: Automatisch Setup Script (Aanbevolen)
```bash
cd ~/Holiday-blackbox/scripts
./setup_flutter_path.sh
```

Dit script:
- 🔍 Zoekt automatisch je Flutter installatie
- ✅ Detecteert je shell (bash/zsh)
- 📝 Voegt Flutter toe aan je PATH in het juiste configuratie bestand
- 🔄 Biedt aan om direct te herladen

### Optie 2: Handmatig Flutter Locatie Vinden

```bash
# Zoek waar Flutter geïnstalleerd is
find ~ -name flutter -type f -path "*/bin/flutter" 2>/dev/null

# Veelvoorkomende locaties:
# ~/flutter/bin/flutter
# ~/snap/flutter/common/flutter/bin/flutter
# /opt/flutter/bin/flutter
```

### Optie 3: Handmatig PATH Toevoegen

Als je Flutter bijvoorbeeld gevonden hebt in `~/flutter/`:

**Voor Bash (~/.bashrc):**
```bash
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

**Voor Zsh (~/.zshrc):**
```bash
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Optie 4: Tijdelijk voor Huidige Terminal
```bash
# Vervang het pad met je eigen Flutter locatie
export PATH="$HOME/flutter/bin:$PATH"

# Test of het werkt
flutter --version
```

## Verificatie

Na het setup, test of Flutter werkt:

```bash
# Check Flutter versie
flutter --version

# Check Flutter doctor
flutter doctor

# Test of rebuild script werkt
cd ~/Holiday-blackbox/scripts
./rebuild_flutter.sh
```

## Troubleshooting

### "flutter: command not found" blijft bestaan

1. **Check of het PATH correct is toegevoegd:**
   ```bash
   cat ~/.bashrc | grep flutter  # of ~/.zshrc voor zsh
   ```

2. **Herlaad je shell configuratie:**
   ```bash
   source ~/.bashrc  # of ~/.zshrc voor zsh
   ```

3. **Of start een nieuwe terminal sessie**

4. **Check of Flutter echt bestaat op die locatie:**
   ```bash
   ls -la ~/flutter/bin/flutter
   ```

### Flutter gevonden maar werkt niet

```bash
# Check permissions
chmod +x ~/flutter/bin/flutter

# Check Flutter doctor voor problemen
~/flutter/bin/flutter doctor
```

### Multiple Flutter versies geïnstalleerd

Als je meerdere Flutter installaties hebt, kies je de juiste:

```bash
# Zie welke Flutter momenteel wordt gebruikt
which flutter

# Zie alle Flutter installaties
find ~ -name flutter -type f -path "*/bin/flutter" 2>/dev/null

# Update je PATH om de juiste te gebruiken
```

## Automatische Detectie in Scripts

De `rebuild_flutter.sh` probeert nu automatisch Flutter te vinden op deze locaties:
1. `~/flutter/bin/flutter`
2. `~/snap/flutter/common/flutter/bin/flutter`
3. `/opt/flutter/bin/flutter`
4. `~/development/flutter/bin/flutter`
5. `~/.flutter/bin/flutter`

Als je Flutter ergens anders hebt, voeg het dan toe aan je PATH of run het setup script.

## Snap Installation (Alternative)

Als je Flutter wilt installeren via snap (makkelijkste methode):

```bash
sudo snap install flutter --classic
```

Dit installeert Flutter automatisch in je PATH.

---

**Laatste update:** 3 november 2025
