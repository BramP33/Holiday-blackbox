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