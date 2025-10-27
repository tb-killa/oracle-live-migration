#!/usr/bin/env bash
# ===============================================================
#  Oracle Migration Live ISO Build Script
#  Erstellt ein kompaktes, bootfähiges Oracle Linux 9 Live-Image
# ===============================================================

set -euo pipefail
IFS=$'\n\t'

# --- Pfade -----------------------------------------------------
WORKDIR="$(pwd)/migration-live"
ISO_SRC="$WORKDIR/OracleLinux-R9-U3-x86_64-dvd.iso"
ISO_OUT="$WORKDIR/oracle-migration-live.iso"
OVERLAY="$(pwd)/overlay"
EXTRACT="$WORKDIR/custom_iso"
LOGFILE="$WORKDIR/build.log"

echo "=== Building Oracle Migration Live ISO (UEFI + BIOS) ==="
mkdir -p "$EXTRACT"

# --- Helper ----------------------------------------------------
run() {
    echo "+ $*" >> "$LOGFILE"
    "$@" >> "$LOGFILE" 2>&1
}

# --- Paketliste protokollieren --------------------------------
echo "=== Paketliste $(date -u) UTC ===" > "$LOGFILE"
run dnf clean all || true
run dnf -y update || true
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' | sort >> "$LOGFILE"

# --- ISO-Existenz prüfen --------------------------------------
if [ ! -f "$ISO_SRC" ]; then
    echo "❌ ISO nicht gefunden: $ISO_SRC"
    echo "Bitte vorher heruntergeladen oder gecached bereitstellen."
    exit 1
fi

# --- Extraktion ------------------------------------------------
echo ">>> Extrahiere ISO-Inhalt..."
run command -v xorriso
echo ">>> Verwende xorriso für Extraktion (UDF-kompatibel)..."
run xorriso -osirrox on -indev "$ISO_SRC" -extract / "$EXTRACT"

# --- Testausgabe -----------------------------------------------
echo ">>> Testausgabe: Beispielhafte Inhalte aus dem ISO:"
ls -l "$EXTRACT" | head -n 20
echo "---------------------------------------------------------------"

# --- Bootdateien prüfen ----------------------------------------
echo ">>> Prüfe Bootdateien..."
MISSING=0
for file in "$EXTRACT/isolinux/isolinux.bin" \
             "$EXTRACT/isolinux/boot.cat" \
             "$EXTRACT/images/efiboot.img"; do
    if [ ! -f "$file" ]; then
        echo "❌ Fehlende Bootdatei: $file"
        MISSING=1
    else
        echo "✅ Gefunden: $(basename "$file")"
    fi
done
if [ "$MISSING" -ne 0 ]; then
    echo "❌ Mindestens eine Bootdatei fehlt – Abbruch!"
    exit 1
fi

# --- Bereinigung unnötiger Inhalte ------------------------------
echo ">>> Bereinige ISO-Inhalt für Minimal-Variante..."
# Entferne AppStream, Debug- und Source-Pakete
rm -rf "$EXTRACT/AppStream" || true
find "$EXTRACT" -type f -name "*-debuginfo*.rpm" -delete || true
find "$EXTRACT" -type f -name "*-source*.rpm" -delete || true

# Entferne DNF-Übersetzungen und Metadaten
rm -rf "$EXTRACT"/repodata/*translation* "$EXTRACT"/repodata/*.gz || true

# Entferne Dokumente, EULA, Logos
rm -f "$EXTRACT"/{EULA,GPL,OL*-RELNOTES*.zip} || true

# Entferne große Firmware-Pakete (optional)
find "$EXTRACT" -type f -name "iwlwifi-*.ucode" -delete || true
find "$EXTRACT" -type f -name "*.bin" -path "*/amdgpu/*" -delete || true

# Entferne Installations-Hilfsdateien
rm -f "$EXTRACT/isolinux"/{boot.msg,vesamenu.c32,splash.png} || true

# Entferne unnötige Baumdateien
rm -f "$EXTRACT"/{.discinfo,.treeinfo,extra_files.json,media.repo} || true

echo ">>> Nach Bereinigung beträgt die Größe:"
du -sh "$EXTRACT" || true

# --- Overlay anwenden ------------------------------------------
echo ">>> Wende Overlay an..."
if [ -d "$OVERLAY" ]; then
    rsync -a --exclude='.gitkeep' "$OVERLAY"/ "$EXTRACT"/
else
    echo "⚠️ Kein Overlay-Verzeichnis gefunden ($OVERLAY)"
fi

# --- Bootfähiges Hybrid-ISO erstellen ---------------------------
echo ">>> Erzeuge bootfähiges Hybrid-ISO (UEFI + Legacy BIOS)..."
run xorriso -as mkisofs \
  -iso-level 3 \
  -UDF \
  -full-iso9660-filenames \
  -allow-limited-size \
  -volid "ORACLE-MIGRATION" \
  -eltorito-boot isolinux/isolinux.bin \
  -eltorito-catalog isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e images/efiboot.img -no-emul-boot -isohybrid-gpt-basdat \
  -output "$ISO_OUT" "$EXTRACT"

# --- Abschluss --------------------------------------------------
if [ -f "$ISO_OUT" ]; then
    echo "✅ ISO erfolgreich erstellt!"
    ls -lh "$ISO_OUT"
else
    echo "❌ ISO-Erstellung fehlgeschlagen!"
    exit 1
fi

echo "🎉 Build abgeschlossen."
