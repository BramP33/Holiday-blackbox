Holiday Blackbox — Install Guide (Raspberry Pi OS Lite)

Quick NVMe Boot Checklist (recommended)
- Use Raspberry Pi Imager to flash Raspberry Pi OS Lite (64‑bit) directly to the NVMe SSD via a USB–NVMe adapter.
- In Imager advanced settings: set hostname (blackbox), enable SSH, set username/password, and Wi‑Fi (optional).
- Install the NVMe in the Pi 5, remove any microSD, and boot. If it doesn’t boot:
  - Update bootloader: sudo apt update && sudo apt full-upgrade -y; sudo rpi-eeprom-update -a; sudo reboot
  - Set boot order: sudo raspi-config → Advanced Options → Boot Order → NVMe/USB first
- Confirm: lsblk should show / on nvme0n1p2.
- Create a data folder: sudo mkdir -p /mnt/nvme; set paths.nvme_mount: /mnt/nvme in Software/config.yml

Full Step‑by‑Step Install
1) Flash Raspberry Pi OS Lite
- Install Raspberry Pi Imager. Choose OS → Raspberry Pi OS Lite (64‑bit). Choose Storage → your microSD or the NVMe (recommended). Use Advanced settings to set hostname, SSH, user, Wi‑Fi, and locale. Write and insert into Pi.

2) First boot and update
- SSH: ssh <user>@blackbox.local (or use the IP from your router)
- Update: sudo apt update && sudo apt full-upgrade -y && sudo reboot

3) Enable SPI and install packages
- sudo raspi-config → Interface Options → SPI → Enable
- sudo apt install -y git python3-pip python3-rpi.gpio python3-spidev python3-pil ffmpeg fonts-dejavu avahi-daemon
- For AP-mode: sudo apt install -y network-manager && sudo systemctl enable --now NetworkManager

4) Prepare NVMe mount
- If you didn’t boot from NVMe, format and mount it:
  - sudo parted /dev/nvme0n1 --script mklabel gpt mkpart primary ext4 0% 100%
  - sudo mkfs.ext4 -L BLACKBOX /dev/nvme0n1p1
  - sudo mkdir -p /mnt/nvme
  - echo 'UUID=<uuid> /mnt/nvme ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
  - sudo mount -a && df -h | grep /mnt/nvme

5) Wire the e-paper and buttons
- E‑paper (epd2in7_V2): connect SPI pins as per Waveshare manual (MOSI=GPIO10, CLK=GPIO11, CS=GPIO8, DC=GPIO25, RST=GPIO17, BUSY=GPIO24, 3.3V, GND).
- Buttons (internal pull‑ups, active‑low): GPIO5, GPIO6, GPIO13, GPIO19 to GND.

6) Install the Waveshare Python library
- Preferred: sudo pip3 install waveshare-epd
- Or from repo: git clone https://github.com/waveshareteam/e-Paper.git and copy waveshare_epd into site‑packages.

7) Get and install Holiday Blackbox
- git clone https://github.com/<your-account>/Holiday-blackbox.git
- cd Holiday-blackbox/Software
- python3 -m pip install -r requirements.txt
- chmod +x scripts/*.sh && ./scripts/install.sh
- Enable services: sudo systemctl enable --now blackbox.service blackbox-web.service

8) Configure
- On first run, Software/config.yml is created. Edit trip name/dates, AP SSID/password, weather coords, device labels, and nvme mount.
- nano ~/Holiday-blackbox/Software/config.yml
- Restart: sudo systemctl restart blackbox blackbox-web

9) Use
- Start back‑up from the e‑paper menu. Web: http://blackbox.local:8080/

Remote Updates
- Simple method with provided script:
  - ssh <user>@blackbox.local
  - cd ~/Holiday-blackbox/Software && ./scripts/update.sh
  - This pulls the latest code (if using Git), installs Python deps, and restarts services.
- Manual method:
  - ssh in, then:
    - cd ~/Holiday-blackbox && git pull
    - cd Software && python3 -m pip install -r requirements.txt
    - sudo systemctl restart blackbox blackbox-web

Tips & Troubleshooting
- Check e‑paper service: systemctl status blackbox; logs: journalctl -u blackbox -e
- Web not reachable: systemctl status blackbox-web; try http://<pi-ip>:8080/
- AP‑mode: nmcli dev wifi hotspot ifname wlan0 ssid Blackbox password pi
- Low power pauses backup: use a quality PSU and cable.

