#!/bin/bash
# ===============================================================
#  Oracle Linux Migration Live ISO Builder
#  (Dual Boot: UEFI + BIOS, CI-kompatibel ohne Mount)
# ===============================================================
set -euo pipefail

WORKDIR="$(pwd)/migration-live"
ISO_SRC="$WORKDIR/OracleLinux-R9-U3-x86_64-dvd.iso"
ISO_OUT="$WORKDIR/oracle-migration-live.iso"
OVERLAY="$(pwd)/overlay"

echo "=== Building Oracle Migration Live ISO (UEFI + BIOS) ==="
mkdir -p "$WORKDIR/custom_iso"

# ---------------------------------------------------------------
# Root/Sudo-kompatible Helper-Funktion
# ---------------------------------------------------------------
run() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------
# Paketliste für Changelog
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
# ISO extrahieren (xorriso-kompatibel, kein Mount nötig)
# ---------------------------------------------------------------
echo ">>> Extrahiere ISO-Inhalt..."
cd "$WORKDIR"

if command -v xorriso >/dev/null 2>&1; then
  echo ">>> Verwende xorriso für Extraktion (UDF-kompatibel)..."
  xorriso -osirrox on -indev "$ISO_SRC" -extract / "$WORKDIR/custom_iso"
elif command -v bsdtar >/dev/null 2>&1; then
  echo ">>> Fallback: Verwende bsdtar..."
  bsdtar -xf "$ISO_SRC" -C "$WORKDIR/custom_iso"
elif command -v 7z >/dev/null 2>&1; then
  echo ">>> Letzter Versuch: Verwende 7z..."
  7z x -y -o"$WORKDIR/custom_iso" "$ISO_SRC"
elif command -v 7za >/dev/null 2>&1; then
  echo ">>> Letzter Versuch: Verwende 7za..."
  7za x -y -o"$WORKDIR/custom_iso" "$ISO_SRC"
else
  echo "❌ Kein Entpackwerkzeug (xorriso, bsdtar, 7z/7za) gefunden!"
  exit 1
fi

# ---------------------------------------------------------------
# Testausgabe – zeige extrahierte Hauptverzeichnisse
# ---------------------------------------------------------------
echo ">>> Testausgabe: Beispielhafte Inhalte aus dem ISO:"
ls -l "$WORKDIR/custom_iso" | head -n 15 || true
ls -l "$WORKDIR/custom_iso/isolinux" 2>/dev/null | head -n 5 || true
ls -l "$WORKDIR/custom_iso/images" 2>/dev/null | head -n 5 || true
echo "---------------------------------------------------------------"

cd - >/dev/null

# ---------------------------------------------------------------
# Bootdateien prüfen
# ---------------------------------------------------------------
echo ">>> Prüfe Bootdateien..."
missing=0
for file in \
  "$WORKDIR/custom_iso/isolinux/isolinux.bin" \
  "$WORKDIR/custom_iso/isolinux/boot.cat" \
  "$WORKDIR/custom_iso/images/efiboot.img"; do
  if [ ! -f "$file" ]; then
    echo "❌ Fehlende Bootdatei: $file"
    missing=1
  else
    echo "✅ Gefunden: ${file##*/}"
  fi
done

if [ $missing -ne 0 ]; then
  echo "❌ Mindestens eine Bootdatei fehlt – Build abgebrochen!"
  exit 1
fi

# ---------------------------------------------------------------
# Overlay anwenden (Migration-GUI, Tools, Services etc.)
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
  echo "❌ Kein ISO-Erzeugungstool (mkisofs/xorriso) gefunden."
  exit 1
fi

# ---------------------------------------------------------------
# Bootfähiges Hybrid-ISO erzeugen (UEFI + BIOS)
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
