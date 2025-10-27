#!/bin/bash
# ===============================================================
#  Oracle Linux Migration Live ISO Builder
#  - Läuft sowohl lokal als auch im GitHub Actions Container
#  - Erkennt automatisch verfügbares ISO-Erzeugungs-Tool
#  - Kein sudo erforderlich
# ===============================================================
set -euo pipefail

WORKDIR="$(pwd)/migration-live"
ISO_SRC="$WORKDIR/OracleLinux-R9-U3-x86_64-dvd.iso"
ISO_OUT="$WORKDIR/oracle-migration-live.iso"
OVERLAY="$(pwd)/overlay"

echo "=== Building Oracle Migration Live ISO ==="
mkdir -p "$WORKDIR/custom_iso" "$WORKDIR/mnt"

# Root/Sudo-Kompatibilität
run() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------
# Paketstände protokollieren (für späteren Changelog)
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
# ISO mounten (oder Dummy verwenden)
# ---------------------------------------------------------------
echo ">>> Mount ISO: $ISO_SRC"
if ! run mount -o loop "$ISO_SRC" "$WORKDIR/mnt" 2>/dev/null; then
  echo "⚠️ Mount fehlgeschlagen, lege Dummy-Struktur an..."
  mkdir -p "$WORKDIR/mnt"
fi

rsync -a "$WORKDIR/mnt/" "$WORKDIR/custom_iso/" || true
run umount "$WORKDIR/mnt" 2>/dev/null || true

# ---------------------------------------------------------------
# Overlay einspielen
# ---------------------------------------------------------------
echo ">>> Kopiere Overlay-Dateien..."
rsync -a "$OVERLAY/" "$WORKDIR/custom_iso/"

# ---------------------------------------------------------------
# ISO-Erzeugungstool erkennen
# ---------------------------------------------------------------
echo ">>> Erzeuge ISO-Image..."
if command -v genisoimage >/dev/null 2>&1; then
  ISO_CMD="genisoimage"
elif command -v mkisofs >/dev/null 2>&1; then
  ISO_CMD="mkisofs"
elif command -v xorriso >/dev/null 2>&1; then
  ISO_CMD="xorriso -as mkisofs"
else
  echo "❌ Kein ISO-Erzeugungstool gefunden (genisoimage/mkisofs/xorriso)"
  exit 1
fi

# ---------------------------------------------------------------
# ISO erzeugen
# ---------------------------------------------------------------
$ISO_CMD -R -J -T -V "Oracle Migration Live" \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -o "$ISO_OUT" "$WORKDIR/custom_iso"

echo "✅ ISO erfolgreich erstellt: $ISO_OUT"
