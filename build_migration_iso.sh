#!/bin/bash
# ===============================================================
#  Oracle Linux Migration Live ISO Builder (Minimal, Deutsch, Offline)
# ===============================================================
set -euo pipefail

WORKDIR="$(pwd)/migration-live"
ISO_SRC="$WORKDIR/OracleLinux-R9-U3-x86_64-dvd.iso"
ISO_OUT="$WORKDIR/oracle-migration-live.iso"
OVERLAY="$(pwd)/overlay"

echo "=== Building Oracle Migration Live ISO ==="
mkdir -p "$WORKDIR/custom_iso" "$WORKDIR/mnt"

# Paketstände protokollieren (für Changelog)
{
  echo "=== Paketliste $(date -u) UTC ==="
  sudo dnf clean all || true
  sudo dnf -y update || true
  rpm -qa --qf "%{NAME}-%{VERSION}-%{RELEASE}\n" | sort
} > "$WORKDIR/new_pkgs.txt"

# ISO mounten & kopieren
sudo mount -o loop "$ISO_SRC" "$WORKDIR/mnt"
rsync -a "$WORKDIR/mnt/" "$WORKDIR/custom_iso/"
sudo umount "$WORKDIR/mnt"

# Overlay einspielen
rsync -a "$OVERLAY/" "$WORKDIR/custom_iso/"

# Neues ISO erzeugen
genisoimage -R -J -T -V "Oracle Migration Live" \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -o "$ISO_OUT" "$WORKDIR/custom_iso"

echo "✅ ISO erstellt: $ISO_OUT"
