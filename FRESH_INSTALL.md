# 🚀 Holiday Blackbox - Fresh Install Guide

## Pre-Installation
1. **Flash Raspberry Pi OS Desktop (64-bit)** to SD card
2. **Enable SSH** during imaging (or create `ssh` file on boot partition)
3. **Set username**: `blackbox` and password
4. **Boot Pi and get IP address**

## One-Command Installation

SSH into your Pi and run:

```bash
curl -sSL https://raw.githubusercontent.com/BramP33/Holiday-blackbox/main/ultimate_setup.sh | bash
```

This will:
- ✅ Update system and install dependencies
- ✅ Configure HyperPixel 4.0 display
- ✅ Install Flutter for ARM64
- ✅ Install Holiday Blackbox backend
- ✅ Build and deploy native Flutter app
- ✅ Set up autostart services
- ✅ Configure all permissions and groups

## After Installation

1. **Reboot**: `sudo reboot`
2. **Test touchscreen**: Touch interface should appear on HyperPixel
3. **Test backend**: Visit `http://blackbox.local:8080`
4. **Configure settings**: Edit `~/Holiday-blackbox/Software/config.yml`

## Troubleshooting

If something goes wrong:
```bash
# Check services
sudo systemctl status blackbox-web.service
sudo systemctl status blackbox-flutter.service

# Check logs
journalctl -u blackbox-flutter.service -f
```

## Manual Steps (if automated fails)

1. **HyperPixel not working**: Check `/boot/firmware/config.txt` for dtoverlay
2. **Flutter not starting**: Check X11 permissions and display
3. **Backend not responding**: Check Python venv and dependencies
