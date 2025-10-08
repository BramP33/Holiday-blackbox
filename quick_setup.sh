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
  libgtk-3-dev \
  device-tree-compiler \
  curl \
  build-essential \
  cmake \
  ninja-build \
  pkg-config \
  clang \
  liblzma-dev \
  libmpv1 \
  libmpv-dev \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-libav \
  libgstreamer1.0-dev \
  bluez \
  bluez-tools

# Enable NetworkManager for AP mode
sudo systemctl enable --now NetworkManager

# Display configuration - configure your display manually
echo "🖥️ Display configuration skipped - configure manually if needed"

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
sudo usermod -aG video,input,netdev,bluetooth "$USER"

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
echo "   📱 Configure your display manually for touchscreen interface"
echo "   🔧 Config file: ~/Holiday-blackbox/Software/config.yml"
echo ""
echo "🚨 Don't forget to:"
echo "   1. Configure your display/touchscreen if needed"
echo "   2. Edit config.yml for your trip settings"
echo "   3. Connect any USB devices you want to backup"
