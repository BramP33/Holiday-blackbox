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

# Configure HyperPixel 4.0 display (simple config method)
echo "🖥️ Configuring HyperPixel 4.0 display..."
CONFIG_PATH="/boot/config.txt"
if [ -f /boot/firmware/config.txt ]; then
  CONFIG_PATH="/boot/firmware/config.txt"
fi

if ! grep -q "dtoverlay=vc4-kms-dpi-hyperpixel4" "$CONFIG_PATH" 2>/dev/null; then
  echo "Adding HyperPixel configuration..."
  cat <<EOF | sudo tee -a "$CONFIG_PATH" >/dev/null

# HyperPixel 4.0 Configuration  
dtoverlay=vc4-kms-dpi-hyperpixel4
dtparam=rotate=90,touchscreen-swapped-x-y,touchscreen-inverted-y
EOF
else
  echo "HyperPixel already configured."
fi

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