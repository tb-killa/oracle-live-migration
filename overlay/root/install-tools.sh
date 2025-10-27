#!/bin/bash
set -e
echo "Installiere benötigte Pakete (minimal)..."
dnf install -y virt-v2v virtio-win qemu-img dialog hivex ntfs-3g curl NetworkManager iproute ipcalc
systemctl enable NetworkManager
systemctl enable migration-autostart.service
# Standard-Root-Passwort:
echo "root:migrationroot" | chpasswd
