# Holiday Blackbox - Bulletproof SSH Setup

## Prerequisites
- Fresh Raspberry Pi OS Lite Bookworm (64-bit) 
- SSH enabled and connected to WiFi
- Hostname set to `blackbox` (optional maar handig)

## 1. SSH into your Pi
```bash
ssh pi@blackbox.local
# of gebruik het IP adres: ssh pi@192.168.1.xxx
```

## 2. Run this ONE command - does everything:
```bash
curl -fsSL https://raw.githubusercontent.com/BramP33/Holiday-blackbox/main/quick_setup.sh | bash
```

**Of als je het lokaal wilt doen (copy/paste deze hele blok):**
```bash
#!/bin/bash
set -e

echo "🚀 Holiday Blackbox - Quick Setup Starting..."

# Update system
echo "📦 Updating system..."
sudo apt update && sudo apt full-upgrade -y

# Enable SPI
echo "🔧 Enabling SPI..."
sudo raspi-config nonint do_spi 0

# Install dependencies
echo "📚 Installing dependencies..."
sudo apt install -y \
  git \
  python3-pip \
  python3-venv \
  python3-rpi-lgpio \
  python3-spidev \
  python3-pil \
  ffmpeg \
  fonts-dejavu \
  avahi-daemon \
  network-manager \
  xserver-xorg \
  xinit \
  openbox \
  libgtk-3-0

# Enable NetworkManager for AP mode
sudo systemctl enable --now NetworkManager

# Clone repository
echo "📥 Downloading Holiday Blackbox..."
cd ~
git clone https://github.com/BramP33/Holiday-blackbox.git

# Run install script
echo "🔨 Installing Holiday Blackbox..."
cd Holiday-blackbox/Software
chmod +x scripts/*.sh
./scripts/install.sh

# Enable services
echo "⚙️ Enabling services..."
sudo systemctl enable --now blackbox.service blackbox-web.service blackbox-poweroff.service

# Add user to groups
echo "👤 Adding user to required groups..."
sudo usermod -aG spi,gpio,video,input "$USER"

# Create data directory
echo "💾 Setting up data directory..."
sudo mkdir -p /mnt/nvme
sudo chown -R "$USER:$USER" /mnt/nvme

echo "✅ Installation complete!"
echo ""
echo "🔄 REBOOT REQUIRED for group changes to take effect:"
echo "   sudo reboot"
echo ""
echo "After reboot:"
echo "   🌐 Web interface: http://blackbox.local:8080"
echo "   📱 E-paper display should show menu"
echo "   🔧 Config file: ~/Holiday-blackbox/Software/config.yml"
echo ""
echo "🚨 Don't forget to:"
echo "   1. Connect your e-paper display (SPI pins)"
echo "   2. Connect buttons to GPIO pins"
echo "   3. Edit config.yml for your trip settings"
```

## 3. Reboot
```bash
sudo reboot
```

## 4. After reboot - Test everything
```bash
# Check services
sudo systemctl status blackbox blackbox-web

# Check web interface
curl http://localhost:8080

# Check e-paper (should show menu)
journalctl -u blackbox -f
```

## 5. Configure your trip
```bash
nano ~/Holiday-blackbox/Software/config.yml
# Edit trip name, dates, WiFi settings, etc.

# Restart after config changes
sudo systemctl restart blackbox blackbox-web
```

---

## Hardware Connections

### E-paper Display (Waveshare 2.7" V2)
- VCC → 3.3V
- GND → GND  
- DIN → GPIO10 (MOSI)
- CLK → GPIO11 (SCLK)
- CS → GPIO8 (CE0)
- DC → GPIO25
- RST → GPIO17
- BUSY → GPIO24

### Buttons (connect to GND)
- Button 1 → GPIO5
- Button 2 → GPIO6  
- Button 3 → GPIO13
- Button 4 → GPIO19

---

## Troubleshooting

### Service not starting?
```bash
journalctl -u blackbox -e
journalctl -u blackbox-web -e
```

### Web interface not accessible?
```bash
sudo systemctl status blackbox-web
ss -tlnp | grep 8080
```

### E-paper not working?
```bash
# Check SPI is enabled
ls -la /dev/spi*

# Test waveshare library
python3 -c "from waveshare_epd import epd2in7_V2; print('OK')"
```

### Can't connect to WiFi?
```bash
# Use NetworkManager
sudo nmcli dev wifi connect "YourWiFi" password "YourPassword"
```

### Need to update code?
```bash
cd ~/Holiday-blackbox/Software
./scripts/update.sh
```

---

## Optional: Flutter GUI Setup

If you want the touch interface (requires more setup):

```bash
# Install Flutter for ARM64
cd ~
wget https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.22.0-stable.tar.xz
tar xf flutter_linux_3.22.0-stable.tar.xz
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Enable Linux desktop
flutter config --enable-linux-desktop

# Build the app
cd ~/Holiday-blackbox/Software/flutter_frontend
flutter pub get
flutter build linux --release

# Deploy
sudo cp -r build/linux/x64/release/bundle /opt/blackbox_flutter
sudo systemctl restart blackbox-flutter
```

This guide gets you 90% there with minimal fuss!