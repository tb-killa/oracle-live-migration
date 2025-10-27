#!/bin/bash
# ============================================================
#  Build Oracle Migration Live ISO (UEFI + Legacy BIOS)
#  Unterstützt automatisches Caching, Overlay-Anwendung,
#  ISO-Minimierung und Hybrid-Boot-Erzeugung.
# ============================================================

set -euo pipefail

WORKDIR=$(pwd)/migration-live
ISO_SRC="$WORKDIR/OracleLinux-R9-U3-x86_64-dvd.iso"
ISO_OUT="$WORKDIR/oracle-migration-live.iso"
OVERLAY=$(pwd)/overlay
CUSTOM_DIR="$WORKDIR/custom_iso"

echo "=== Building Oracle Migration Live ISO (UEFI + BIOS) ==="

mkdir -p "$CUSTOM_DIR"

# 1️⃣ ISO extrahieren
echo ">>> Extrahiere ISO-Inhalt..."
echo ">>> Verwende xorriso für Extraktion (UDF-kompatibel)..."
xorriso -osirrox on -indev "$ISO_SRC" -extract / "$CUSTOM_DIR" || {
  echo "❌ Fehler beim Extrahieren der ISO-Datei!"
  exit 1
}

# Testausgabe
echo ">>> Testausgabe: Beispielhafte Inhalte aus dem ISO:"
ls -l "$CUSTOM_DIR" | head -n 15
echo "---------------------------------------------------------------"

# 2️⃣ Boot-Dateien prüfen
echo ">>> Prüfe Bootdateien..."
missing=0
for file in \
  "$CUSTOM_DIR/isolinux/isolinux.bin" \
  "$CUSTOM_DIR/isolinux/boot.cat" \
  "$CUSTOM_DIR/images/efiboot.img"; do
  if [ ! -f "$file" ]; then
    echo "❌ Fehlende Bootdatei: $file"
    missing=1
  else
    echo "✅ Gefunden: $(basename "$file")"
  fi
done

if [ $missing -ne 0 ]; then
  echo "❌ Mindestens eine Bootdatei fehlt – Build abgebrochen!"
  exit 1
fi

# 3️⃣ Nicht benötigte Inhalte entfernen (Größenoptimierung)
echo ">>> Bereinige ISO-Inhalt für Minimal-Variante..."
rm -rf "$CUSTOM_DIR/AppStream" "$CUSTOM_DIR/BaseOS/Packages" || true
du -sh "$CUSTOM_DIR" | awk '{print ">>> Nach Bereinigung beträgt die Größe: "$1}'

# 4️⃣ Overlay anwenden
echo ">>> Wende Overlay an..."
rsync -a "$OVERLAY/" "$CUSTOM_DIR/" || {
  echo "❌ Fehler beim Anwenden des Overlays!"
  exit 1
}

# 5️⃣ Hybrid-ISO erzeugen (UEFI + BIOS)
echo ">>> Erzeuge bootfähiges Hybrid-ISO (UEFI + Legacy BIOS)..."

xorriso -as mkisofs \
  -R -J -V "Oracle Migration Live" \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e images/efiboot.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -o "$ISO_OUT" "$CUSTOM_DIR" || {
    echo "❌ Fehler beim ISO-Erzeugen!"
    exit 5
  }

echo "✅ ISO erfolgreich erzeugt: $ISO_OUT"
du -sh "$ISO_OUT"

# 6️⃣ Hybrid-Testausgabe
echo ">>> Prüfe El-Torito-Bootstruktur:"
xorriso -indev "$ISO_OUT" -report_el_torito as_mkisofs | grep -E "Boot record|BIOS|EFI" || true

echo "=== Build erfolgreich abgeschlossen. ==="
