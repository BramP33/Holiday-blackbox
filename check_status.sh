#!/bin/bash

echo "🔍 Holiday Blackbox - System Status"
echo "==================================="
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_service() {
    local service_name=$1
    if systemctl is-active --quiet "$service_name"; then
        echo -e "✅ ${GREEN}$service_name${NC} - Running"
    else
        echo -e "❌ ${RED}$service_name${NC} - Not running"
        echo "   Status: $(systemctl is-active $service_name)"
    fi
}

check_port() {
    local port=$1
    local service_name=$2
    if nc -z localhost "$port" 2>/dev/null; then
        echo -e "✅ ${GREEN}Port $port${NC} ($service_name) - Accessible"
    else
        echo -e "❌ ${RED}Port $port${NC} ($service_name) - Not accessible"
    fi
}

echo "🔧 Backend Services:"
check_service "blackbox.service"
check_service "blackbox-web.service"
check_service "blackbox-poweroff.service"

echo ""
echo "🌐 Web Interfaces:"
check_port "8080" "Web Interface"

echo ""
echo "📁 Directories:"
if [ -d "/home/blackbox/Holiday-blackbox/Software/.venv" ]; then
    echo -e "✅ ${GREEN}Python venv${NC} - Present"
else
    echo -e "❌ ${RED}Python venv${NC} - Missing"
fi

if [ -d "/mnt/nvme/Blackbox" ]; then
    echo -e "✅ ${GREEN}Data directory${NC} - Present"
else
    echo -e "⚠️  ${YELLOW}Data directory${NC} - Missing"
fi

echo ""
echo "🔌 Hardware:"
if [ -e "/dev/spidev0.0" ]; then
    echo -e "✅ ${GREEN}SPI${NC} - Enabled"
else
    echo -e "⚠️  ${YELLOW}SPI${NC} - Disabled (run 'sudo raspi-config' to enable)"
fi

echo ""
echo "📊 Quick URLs:"
echo "   🌐 Web Interface: http://localhost:8080"
echo "   🌐 Network Access: http://$(hostname).local:8080"
echo ""
echo "📋 Logs:"
echo "   Backend: journalctl -u blackbox.service -f"
echo "   Web:     journalctl -u blackbox-web.service -f"
echo ""