#!/bin/bash
set -e

echo "🚀 Holiday Blackbox - Backend Only Setup"
echo "========================================"
echo ""
echo "This script installs ONLY the Python backend and web interface"
echo "No Flutter installation needed - use VS Code for Flutter development!"
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

log_info "Starting backend-only installation for user: $USER"

# 1. System Update
log_info "Updating system packages..."
sudo apt update

# 2. Install essential dependencies (no Flutter/GUI packages)
log_info "Installing Python and backend dependencies..."
sudo apt install -y \
    python3-pip python3-venv python3-pil python3-dev \
    python3-rpi-lgpio python3-lgpio python3-spidev \
    ffmpeg fonts-dejavu avahi-daemon network-manager \
    build-essential git curl wget

# 3. Navigate to Software directory
log_info "Setting up Python backend..."
cd ~/Holiday-blackbox/Software

# 4. Make scripts executable
chmod +x scripts/*.sh

# 5. Run the Python installation
log_info "Installing Python virtual environment and dependencies..."
./scripts/install.sh

# 6. Enable backend services (but not Flutter service)
log_info "Enabling backend services..."
sudo systemctl enable --now blackbox.service blackbox-web.service blackbox-poweroff.service

# 7. Add user to required groups
log_info "Adding user to required groups..."
sudo usermod -aG video,input,netdev,bluetooth,spi,gpio blackbox || true

# 8. Create data directories
log_info "Setting up data directories..."
sudo mkdir -p /mnt/nvme/Blackbox || true
sudo chown -R blackbox:blackbox /mnt/nvme/Blackbox || true

log_success "Backend installation completed successfully!"
echo ""
echo "🎉 Holiday Blackbox Backend is now running!"
echo ""
echo "📋 Status:"
echo "   ✅ Python backend: http://localhost:8080"
echo "   ✅ Web interface: http://blackbox.local:8080"
echo "   ✅ Services running: blackbox.service, blackbox-web.service"
echo ""
echo "🔧 For Flutter development:"
echo "   - Open VS Code"
echo "   - Install Flutter extension"
echo "   - Open: ~/Holiday-blackbox/Software/flutter_frontend/"
echo "   - Run: flutter pub get"
echo "   - Press F5 to debug"
echo ""
echo "⚙️  Configuration:"
echo "   - Edit config: ~/Holiday-blackbox/Software/config.yml"
echo "   - View logs: journalctl -u blackbox-web.service -f"
echo ""
echo "🔴 Note: SPI might need enabling via 'sudo raspi-config' for e-paper display"