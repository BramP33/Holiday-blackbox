#!/bin/bash
set -e

echo "🚀 Holiday Blackbox - Ultimate Fresh Install"
echo "============================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as blackbox user
if [ "$USER" != "blackbox" ]; then
    log_error "Please run as 'blackbox' user"
    exit 1
fi

# Check architecture
if [ "$(uname -m)" != "aarch64" ]; then
    log_error "This script requires ARM64 (aarch64) architecture"
    exit 1
fi

log_info "Starting installation for user: $USER on $(uname -m)"

# 1. System Update
log_info "Updating system packages..."
sudo apt update && sudo apt full-upgrade -y

# 2. Install ALL dependencies in one go
log_info "Installing all required dependencies..."
sudo apt install -y \
    git curl wget build-essential cmake ninja-build pkg-config clang \
    python3-pip python3-venv python3-pil python3-dev \
    ffmpeg fonts-dejavu avahi-daemon network-manager \
    xserver-xorg xinit openbox unclutter \
    libgtk-3-dev libgles2-mesa-dev \
    liblzma-dev \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-libav libgstreamer1.0-dev \
    bluez bluez-tools \
    device-tree-compiler \
    python3-rpi-lgpio python3-lgpio python3-spidev

# Install GTK3 (handle different package names)
sudo apt install -y libgtk-3-0 || sudo apt install -y libgtk-3-0t64 || true

# Install MPV (handle different package names)  
sudo apt install -y libmpv1 || sudo apt install -y libmpv2 || sudo apt install -y mpv || true
sudo apt install -y libmpv-dev || true

# 3. Install Flutter
log_info "Installing Flutter for ARM64..."
FLUTTER_VERSION="3.24.5"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

cd /tmp
if [ ! -f "flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" ]; then
    wget "$FLUTTER_URL"
fi

# Clean any existing Flutter
sudo rm -rf /opt/flutter /mnt/nvme/flutter

# Extract to SSD location
sudo mkdir -p /mnt/nvme
tar xf "flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
sudo mv flutter /mnt/nvme/flutter
sudo chown -R blackbox:blackbox /mnt/nvme/flutter
sudo ln -sf /mnt/nvme/flutter /opt/flutter

# Add Flutter to PATH
if ! grep -q "/opt/flutter/bin" ~/.bashrc; then
    echo 'export PATH="$PATH:/opt/flutter/bin"' >> ~/.bashrc
fi
export PATH="$PATH:/opt/flutter/bin"

# 4. Verify Flutter
log_info "Verifying Flutter installation..."
/opt/flutter/bin/flutter doctor --accept-licenses
/opt/flutter/bin/flutter precache --linux

# 5. Clone Holiday Blackbox
log_info "Cloning Holiday Blackbox repository..."
cd ~
if [ -d "Holiday-blackbox" ]; then
    cd Holiday-blackbox
    git pull
else
    git clone https://github.com/BramP33/Holiday-blackbox.git
    cd Holiday-blackbox
fi

# 6. Install Python backend
log_info "Installing Python backend..."
cd Software
chmod +x scripts/*.sh
./scripts/install.sh

# 7. Build Flutter app
log_info "Building native Flutter application..."
cd flutter_frontend
/opt/flutter/bin/flutter pub get
/opt/flutter/bin/flutter build linux --release

# 8. Deploy Flutter app
log_info "Deploying Flutter application..."
sudo mkdir -p /opt/blackbox_flutter

# Flutter may create different build paths depending on the system
# Try arm64-specific path first, then fall back to generic linux path
if [ -d "build/linux/arm64/release/bundle" ]; then
    log_info "Using ARM64-specific build output"
    sudo cp -r build/linux/arm64/release/bundle/* /opt/blackbox_flutter/
elif [ -d "build/linux/release/bundle" ]; then
    log_info "Using generic Linux build output"
    sudo cp -r build/linux/release/bundle/* /opt/blackbox_flutter/
else
    log_error "Flutter build output not found in expected locations!"
    exit 1
fi

sudo chmod +x /opt/blackbox_flutter/blackbox_flutter
sudo chown -R blackbox:blackbox /opt/blackbox_flutter

# 9. Create optimized .xinitrc
log_info "Creating X11 configuration..."
cat > ~/.xinitrc << 'EOF'
#!/bin/sh
# Disable screensaver and power management
xset -dpms
xset s off
xset s noblank

# Hide cursor after 1 second of inactivity  
unclutter -idle 1 -root &

# Set environment variables
export BLACKBOX_BASE_URL=http://127.0.0.1:8080
export DISPLAY=:0

# Start Flutter app in fullscreen
exec /opt/blackbox_flutter/blackbox_flutter --window-decorator=false --fullscreen
EOF
chmod +x ~/.xinitrc

# 11. Update Flutter service
log_info "Configuring Flutter autostart service..."
sudo tee /etc/systemd/system/blackbox-flutter.service > /dev/null << EOF
[Unit]
Description=Holiday Blackbox Flutter Native App
After=graphical-session.target
Requires=graphical-session.target

[Service]
Type=simple
User=blackbox
Group=blackbox
Environment=DISPLAY=:0
Environment=BLACKBOX_BASE_URL=http://127.0.0.1:8080
WorkingDirectory=/home/blackbox
ExecStart=/usr/bin/startx /home/blackbox/.xinitrc -- -nocursor -keeptty vt7
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
EOF

# 12. Enable all services
log_info "Enabling and starting services..."
sudo systemctl daemon-reload
sudo systemctl enable --now blackbox.service
sudo systemctl enable --now blackbox-web.service  
sudo systemctl enable --now blackbox-poweroff.service
sudo systemctl enable blackbox-flutter.service

# 13. Configure user groups
log_info "Adding user to required groups..."
sudo usermod -aG video,input,netdev,bluetooth,spi,gpio,fuse blackbox

# 14. Create data directories
log_info "Setting up data directories..."
sudo mkdir -p /mnt/nvme/Blackbox
sudo chown -R blackbox:blackbox /mnt/nvme/Blackbox

# 15. Final system tweaks
log_info "Applying final optimizations..."

# Auto-login for blackbox user
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin blackbox --noclear %I \$TERM
EOF

# Disable unnecessary services to save resources
sudo systemctl disable --now ModemManager.service
sudo systemctl disable --now wpa_supplicant.service || true

log_success "Installation completed successfully!"
echo ""
echo "🎉 Holiday Blackbox is now installed!"
echo ""
echo "📋 Next steps:"
echo "   1. Reboot: sudo reboot"
echo "   2. After reboot, the Flutter app should start automatically"
echo "   3. Web interface: http://blackbox.local:8080"
echo "   4. Edit config: ~/Holiday-blackbox/Software/config.yml"
echo ""
echo "🔧 Troubleshooting:"
echo "   - Check services: sudo systemctl status blackbox-flutter.service"
echo "   - View logs: journalctl -u blackbox-flutter.service -f"
echo "   - Manual start: sudo systemctl start blackbox-flutter.service"
echo ""
log_warning "REBOOT REQUIRED for all changes to take effect!"