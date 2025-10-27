#!/bin/bash
# ===============================================================
#  Oracle Linux Migration Live ISO Builder (UEFI + Legacy BIOS)
# ===============================================================
set -euo pipefail

WORKDIR="$(pwd)/migration-live"
ISO_SRC="$WORKDIR/OracleLinux-R9-U3-x86_64-dvd.iso"
ISO_OUT="$WORKDIR/oracle-migration-live.iso"
OVERLAY="$(pwd)/overlay"

echo "=== Building Oracle Migration Live ISO (UEFI + BIOS) ==="
mkdir -p "$WORKDIR/custom_iso" "$WORKDIR/mnt"

# Helper: run mit/ohne sudo
run() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------
# Paketliste (für Changelog)
# ---------------------------------------------------------------
{
  echo "=== Paketliste $(date -u) UTC ==="
  if command -v dnf >/dev/null 2>&1; then
    run dnf clean all || true
    run dnf -y update || true
  fi
  rpm -qa --qf "%{NAME}-%{VERSION}-%{RELEASE}\n" | sort
} > "$WORKDIR/new_pkgs.txt"

# ---------------------------------------------------------------
# Oracle ISO mounten
# ---------------------------------------------------------------
echo ">>> Mount ISO: $ISO_SRC"
if ! run mount -o loop "$ISO_SRC" "$WORKDIR/mnt" 2>/dev/null; then
  echo "❌ Konnte Oracle ISO nicht mounten. Abbruch."
  exit 1
fi

# ---------------------------------------------------------------
# Inhalte kopieren + Bootdateien prüfen
# ---------------------------------------------------------------
echo ">>> Kopiere Originaldateien..."
rsync -a "$WORKDIR/mnt/" "$WORKDIR/custom_iso/"

# Legacy BIOS-Dateien prüfen
if [ ! -f "$WORKDIR/custom_iso/isolinux/isolinux.bin" ]; then
  echo "❌ isolinux/isolinux.bin fehlt – Legacy Boot nicht möglich!"
  exit 1
fi
if [ ! -f "$WORKDIR/custom_iso/isolinux/boot.cat" ]; then
  echo "❌ isolinux/boot.cat fehlt – Legacy Boot nicht möglich!"
  exit 1
fi

# UEFI-Bootdatei prüfen
if [ ! -f "$WORKDIR/custom_iso/images/efiboot.img" ]; then
  echo "❌ images/efiboot.img fehlt – UEFI Boot nicht möglich!"
  exit 1
fi

run umount "$WORKDIR/mnt" 2>/dev/null || true

# ---------------------------------------------------------------
# Overlay anwenden (unsere Migration-GUI etc.)
# ---------------------------------------------------------------
echo ">>> Wende Overlay an..."
rsync -a "$OVERLAY/" "$WORKDIR/custom_iso/"

# ---------------------------------------------------------------
# ISO-Erzeugungstool bestimmen
# ---------------------------------------------------------------
if command -v mkisofs >/dev/null 2>&1; then
  ISO_CMD="mkisofs"
elif command -v xorriso >/dev/null 2>&1; then
  ISO_CMD="xorriso -as mkisofs"
else
  echo "❌ Kein ISO-Erzeugungstool gefunden."
  exit 1
fi

# ---------------------------------------------------------------
# Bootfähiges Hybrid-ISO (UEFI + BIOS)
# ---------------------------------------------------------------
echo ">>> Erzeuge bootfähiges Hybrid-ISO (UEFI + Legacy BIOS)..."
$ISO_CMD -R -J -T -V "Oracle_Migration_Live" \
  -o "$ISO_OUT" "$WORKDIR/custom_iso" \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -eltorito-alt-boot \
  -e images/efiboot.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat

echo "✅ Bootfähiges Hybrid-ISO erfolgreich erstellt: $ISO_OUT"
