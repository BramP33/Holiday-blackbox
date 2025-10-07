# WiFi Functionaliteit voor Flutter App op Raspberry Pi

## Overzicht

De Flutter app heeft nu volledige WiFi-functionaliteit die werkt op Raspberry Pi met Raspberry Pi OS Lite Bookworm. De implementatie gebruikt NetworkManager (`nmcli`) om WiFi-netwerken te scannen en verbindingen te maken.

## Belangrijke Features

### 1. WiFi Netwerk Scanning
- Automatisch scannen naar beschikbare WiFi-netwerken
- Real-time updates van netwerk lijst
- Weergave van signaalsterkte, beveiligingstype en frequentie
- Onderscheid tussen 2.4GHz en 5GHz netwerken

### 2. Netwerk Verbindingen
- Verbinden met open en beveiligde netwerken
- Wachtwoord invoer voor beveiligde netwerken
- Automatische herverbinding met bekende netwerken
- Foutafhandeling met gebruiksvriendelijke berichten

### 3. Netwerk Beheer
- Bekijken van huidige verbinding details
- "Vergeten" van opgeslagen netwerken (long press)
- Real-time verbindingsstatus monitoring
- Netwerk informatie zoals signaalsterkte en beveiliging

### 4. Access Point Mode
- Weergave van huidige AP configuratie
- Schakelaar tussen WiFi client en AP mode

## Technische Implementatie

### WiFiService (`lib/services/wifi_service.dart`)
Dit is de kernservice die alle WiFi-functionaliteit beheert:

```dart
// Initialiseren van de service
await WiFiService.instance.initialize();

// Scannen naar netwerken
final networks = await WiFiService.instance.scanNetworks();

// Verbinden met netwerk
final result = await WiFiService.instance.connectToNetwork(
  ssid: 'NetworkName',
  password: 'password123',
);

// Vergeten van netwerk
await WiFiService.instance.forgetNetwork('NetworkName');
```

### Gebruikte Linux Tools
- **nmcli**: Voor netwerk scanning, verbinden en configuratie
- **NetworkManager**: Voor netwerk beheer op systeem niveau

### Commands die gebruikt worden
```bash
# Check nmcli beschikbaarheid
which nmcli

# Scan voor WiFi netwerken
nmcli -t -f SSID,BSSID,MODE,CHAN,FREQ,RATE,SIGNAL,BARS,SECURITY dev wifi list

# Verbind met netwerk
nmcli dev wifi connect "SSID" password "PASSWORD"

# Vergeet netwerk
nmcli connection delete "CONNECTION_NAME"

# Bekijk actieve verbindingen
nmcli -t -f ACTIVE,SSID,BSSID,MODE,CHAN,FREQ,RATE,SIGNAL,BARS,SECURITY dev wifi list
```

## UI Componenten

### WiFiSettingsScreen (`lib/screens/wifi_settings_screen.dart`)
Het hoofdscherm voor WiFi-instellingen met:
- WiFi en AP toggle switches
- Netwerk scan functionaliteit
- Lijst van beschikbare netwerken
- Huidige verbinding details

### WiFiDebugScreen (`lib/screens/wifi_debug_screen.dart`)
Debug scherm voor troubleshooting met:
- Service status informatie
- Live logs van WiFi operaties
- Manual scan triggers
- Netwerk lijst weergave

## Error Handling

De implementatie heeft robuuste error handling voor:
- NetworkManager niet beschikbaar
- Onjuiste wachtwoorden
- Verbindingstime-outs
- Netwerk niet gevonden
- Algemene systeem fouten

## Vereisten

### Systeem Vereisten
- Raspberry Pi met Raspberry Pi OS Lite Bookworm
- NetworkManager geïnstalleerd (`sudo apt install network-manager`)
- WiFi interface (meestal `wlan0`)

### Flutter Dependencies
```yaml
dependencies:
  connectivity_plus: ^5.0.2  # Voor verbindingsstatus monitoring
  process: ^5.0.2            # Voor Linux process execution (optioneel)
```

## Debugging

### WiFi Debug Screen
Toegankelijk via Settings → WiFi Debug, toont:
- Service initialisatie status
- Real-time logs van alle WiFi operaties
- Gevonden netwerken
- Huidige verbindingsstatus

### Logging
Debug logging kan worden in-/uitgeschakeld in `wifi_service.dart`:
```dart
const bool _kDebugWiFi = true;  // Zet op false voor productie
```

### Veel voorkomende problemen

1. **NetworkManager niet beschikbaar**
   ```bash
   sudo apt install network-manager
   sudo systemctl enable NetworkManager
   sudo systemctl start NetworkManager
   ```

2. **Geen WiFi interface gevonden**
   ```bash
   # Check beschikbare interfaces
   nmcli device status
   
   # Check WiFi radio status
   nmcli radio wifi
   ```

3. **Permissie problemen**
   Zorg ervoor dat de user in de `netdev` groep zit:
   ```bash
   sudo usermod -a -G netdev $USER
   ```

## Gebruik

1. Open de Flutter app
2. Ga naar Settings → Wi-Fi
3. Schakel WiFi in
4. Druk op "Scan" om netwerken te zoeken
5. Tik op een netwerk om te verbinden
6. Voer wachtwoord in voor beveiligde netwerken
7. Long press op bekende netwerken voor opties (vergeten, details)

Voor debugging, gebruik Settings → WiFi Debug om logs en status te bekijken.