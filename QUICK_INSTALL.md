# Holiday Blackbox - Bulletproof SSH Setup (HyperPixel)

## Prerequisites
- Fresh Raspberry Pi OS Lite Bookworm (64-bit) 
- SSH enabled and connected to WiFi
- Hostname set to `blackbox` (optional maar handig)
- **Pimoroni HyperPixel 4.0 touchscreen connected**

## 1. SSH into your Pi
```bash
ssh pi@blackbox.local
# of gebruik het IP adres: ssh pi@192.168.1.xxx
```

## 2. Run this ONE command - does everything:
```bash
curl -fsSL https://raw.githubusercontent.com/BramP33/Holiday-blackbox/main/quick_setup.sh | bash
```

**Or copy/paste this entire block:**
```bash
#!/bin/bash
set -e

echo "🚀 Holiday Blackbox - HyperPixel Quick Setup Starting..."

# Update system
echo "📦 Updating system..."
sudo apt update && sudo apt full-upgrade -y

# Install dependencies (NO SPI - using HyperPixel display)
echo "📚 Installing dependencies..."
sudo apt install -y \
  git \
  python3-pip \
  python3-venv \
  python3-pil \
  ffmpeg \
  fonts-dejavu \
  avahi-daemon \
  network-manager \
  xserver-xorg \
  xinit \
  openbox \
  libgtk-3-0 \
  device-tree-compiler \
  curl \
  build-essential

# Enable NetworkManager for AP mode
sudo systemctl enable --now NetworkManager

# Install HyperPixel 4.0 display drivers
echo "🖥️ Installing HyperPixel 4.0 display drivers..."
curl https://get.pimoroni.com/hyperpixel4 | bash

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

# Add user to groups (NO gpio/spi groups - HyperPixel doesn't need them)
echo "👤 Adding user to required groups..."
sudo usermod -aG video,input "$USER"

# Create data directory
echo "💾 Setting up data directory..."
sudo mkdir -p /mnt/nvme
sudo chown -R "$USER:$USER" /mnt/nvme

echo "✅ Installation complete!"
echo ""
echo "🔄 REBOOT REQUIRED for HyperPixel display and group changes to take effect:"
echo "   sudo reboot"
echo ""
echo "After reboot:"
echo "   🌐 Web interface: http://blackbox.local:8080"
echo "   📱 HyperPixel display should show touchscreen interface"
echo "   🔧 Config file: ~/Holiday-blackbox/Software/config.yml"
echo ""
echo "🚨 Don't forget to:"
echo "   1. Edit config.yml for your trip settings"
echo "   2. Test touch interface on the HyperPixel"
echo "   3. Connect any USB devices you want to backup"
echo ""
echo "💡 NO GPIO pins are used with HyperPixel setup - all pins are free for other uses!"
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

# Check HyperPixel display (should show Flutter touch interface)
sudo systemctl status blackbox-flutter
```

## 5. Configure your trip
```bash
nano ~/Holiday-blackbox/Software/config.yml
# Edit trip name, dates, WiFi settings, etc.

# Restart after config changes
sudo systemctl restart blackbox blackbox-web
```

---

## Hardware Setup

### HyperPixel 4.0 Display
- **NO manual wiring needed** - HyperPixel uses the 40-pin header automatically
- Touch interface will show after reboot
- Display is rotated to landscape automatically 
- **ALL GPIO pins are free** for other uses (no e-paper, no buttons needed)

### USB Storage
- Connect USB drives, cameras, phones via USB ports
- Automatic backup detection and import

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

### HyperPixel display not working?
```bash
# Check HyperPixel driver installation
ls /boot/overlays/hyperpixel*
dmesg | grep -i hyperpixel

# Check Flutter touch interface
sudo systemctl status blackbox-flutter
journalctl -u blackbox-flutter -e
```

### Touch not responding?
```bash
# Check input devices
cat /proc/bus/input/devices | grep -A5 -i touch

# Test touch events
sudo evtest
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

## Flutter Touch Interface (Auto-installed)

The HyperPixel setup automatically includes a Flutter touch interface that will:

1. **Auto-start on boot** - Shows on the HyperPixel display
2. **Full touch control** - No physical buttons needed
3. **Media browsing** - Swipe through photos/videos
4. **Settings** - WiFi, backup settings, trip configuration
5. **Live backup progress** - Real-time status updates

### Manual Flutter Operations (if needed):

```bash
# Check Flutter service status
sudo systemctl status blackbox-flutter

# Restart Flutter interface
sudo systemctl restart blackbox-flutter

# View Flutter logs
journalctl -u blackbox-flutter -f

# Test Flutter manually (from SSH)
export DISPLAY=:0
cd ~/Holiday-blackbox/Software/flutter_frontend
/opt/blackbox_flutter/blackbox_flutter
```

---

## Advantages of HyperPixel Setup:

✅ **No GPIO pin conflicts** - All 40 pins available for other projects  
✅ **Full touchscreen interface** - Much more intuitive than e-paper + buttons  
✅ **Faster UI** - Real-time updates, smooth animations  
✅ **Better media viewing** - High-resolution photo/video preview  
✅ **Easier setup** - No manual wiring of displays or buttons  
✅ **Future-proof** - Easy to add more touch features  

This setup gives you the full Holiday Blackbox experience with a modern touch interface!