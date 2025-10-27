#!/bin/bash
# ===========================================================
#  Oracle OLVM Migration Tool - Dialog GUI Version (Erweitert)
#  - DHCP/Manuell Netz
#  - OLVM API Test (HTTPS)
#  - Hostname-Erkennung (Windows Registry, NT→Win11)
#  - CA-Handling (vorhanden oder Download)
#  - PID-Lock, Logging, Shutdown-Frage
# ===========================================================
set -euo pipefail

TITLE="Oracle OLVM Migration Tool"
LOGFILE="/var/log/migration.log"
PIDFILE="/run/migration.pid"
TMPFILE="$(mktemp)"
trap "rm -f '$TMPFILE'" EXIT

# Nur eine Instanz:
if [ -f "$PIDFILE" ]; then
  dialog --title "$TITLE" --msgbox "Die Migration-GUI läuft bereits (PID $(cat "$PIDFILE"))." 8 70
  exit 1
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

msgbox() { dialog --title "$TITLE" --msgbox "$1" 10 80; }
die()    { msgbox "FEHLER: $1"; echo "[ERROR] $1" >>"$LOGFILE"; exit 1; }

need_cmds=(dialog virt-v2v lsblk mount awk curl nmcli ip ipcalc hivexregedit)
for c in "${need_cmds[@]}"; do
  command -v "$c" >/dev/null 2>&1 || die "Fehlendes Kommando: $c"
done

echo "=== Start $(date -u) UTC ===" >>"$LOGFILE"

# ---------------- Netzwerk: DHCP versuchen, sonst manuell ----------------
msgbox "Überprüfe Netzwerkverbindung..."
IFACE="$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '$2=="ethernet" {print $1; exit}')"
if [ -z "$IFACE" ]; then
  # Fallback: erstes nicht-lo Interface
  IFACE="$(ip -o link show | awk -F': ' '$2 !~ /lo/ {print $2; exit}')"
fi
[ -n "$IFACE" ] || die "Kein Netzwerkinterface gefunden."

# DHCP versuchen
nmcli device reapply "$IFACE" >/dev/null 2>&1 || true
nmcli device connect "$IFACE" >/dev/null 2>&1 || true
nmcli device modify "$IFACE" ipv4.method auto >/dev/null 2>&1 || true
sleep 3

get_ip() { ip -4 addr show "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1; }
IP="$(get_ip || true)"

if [ -z "$IP" ]; then
  dialog --title "$TITLE" --yesno "Keine IP via DHCP erhalten.\nMöchtest du die Netzwerkkonfiguration manuell vornehmen?" 10 70
  if [ $? -eq 0 ]; then
    IP=$(dialog --inputbox "IP-Adresse:" 10 60 "192.168.1.100" 3>&1 1>&2 2>&3)
    MASK=$(dialog --inputbox "Netzmaske (CIDR oder 255.x):" 10 60 "255.255.255.0" 3>&1 1>&2 2>&3)
    GW=$(dialog --inputbox "Gateway:" 10 60 "192.168.1.1" 3>&1 1>&2 2>&3)
    DNS=$(dialog --inputbox "DNS-Server:" 10 60 "8.8.8.8" 3>&1 1>&2 2>&3)
    # Maske in Prefix
    if [[ "$MASK" =~ ^[0-9]+$ ]]; then
      PREFIX="$MASK"
    else
      PREFIX="$(ipcalc -p "$IP" "$MASK" | cut -d= -f2)"
    fi
    nmcli con add type ethernet ifname "$IFACE" con-name "migration-manual" ipv4.method manual ipv4.addresses "$IP/$PREFIX" ipv4.gateway "$GW" ipv4.dns "$DNS" autoconnect yes || true
    nmcli con up "migration-manual" || true
    sleep 2
    IP="$(get_ip || true)"
    [ -n "$IP" ] || die "Manuelle Netzwerkkonfiguration fehlgeschlagen."
  else
    die "Keine Netzwerkkonfiguration verfügbar."
  fi
fi

echo "[INFO] Interface=$IFACE IP=$IP" >>"$LOGFILE"
msgbox "Netzwerk verbunden.\nInterface: $IFACE\nIP: $IP"

# ---------------- Disk-Auswahl ----------------
# Liste aller Disks NAME (SIZE)
DISKLIST_RAW="$(lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk"{print $1 " (" $2 ")"}')"
if [ -z "$DISKLIST_RAW" ]; then
  die "Keine physische Festplatte gefunden."
fi

# Dialog-Menü erwartet: key label
# Wir nehmen index als key
i=0
MENU_ARGS=()
while IFS= read -r line; do
  name="$(echo "$line" | awk '{print $1}')"
  label="$line"
  MENU_ARGS+=("$i" "$label")
  DISKNAMES["$i"]="$name"
  i=$((i+1))
done < <(printf "%s\n" "$DISKLIST_RAW")

SEL=$(dialog --title "$TITLE" --menu "Quell-Festplatte wählen (physisches Windows-System):" 15 70 6 "${MENU_ARGS[@]}" 3>&1 1>&2 2>&3) || exit 1
DISK="/dev/${DISKNAMES[$SEL]}"
[ -b "$DISK" ] || die "Ungültiges Device: $DISK"

# ---------------- Hostname aus Windows-Registry ----------------
mkdir -p /mnt/windows
# Versuche typische erste Partition, ggf. mehr versuchen:
tries=("/mnt/windows")
if mount -t auto "${DISK}1" /mnt/windows 2>/dev/null; then
  true
else
  # Heuristik: suche NTFS-Partition
  PART="$(lsblk -ln -o NAME,FSTYPE "$DISK" | awk '$2=="ntfs"{print $1; exit}')"
  if [ -n "$PART" ]; then
    mount -t ntfs-3g "/dev/$PART" /mnt/windows 2>/dev/null || true
  fi
fi

HOSTNAME_AUTO=""
if [ -f /mnt/windows/Windows/System32/config/SYSTEM ]; then
  # hivexregedit exportiert Hierarchien; wir filtern den Wert
  HOSTNAME_AUTO="$(hivexregedit --export /mnt/windows/Windows/System32/config/SYSTEM 'HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\ComputerName\\ActiveComputerName' 2>/dev/null \
    | awk -F'=' '/ComputerName/{print $2}' | tr -d '\r' | tail -n1 || true)"
fi
umount /mnt/windows 2>/dev/null || true

if [ -n "$HOSTNAME_AUTO" ]; then
  dialog --title "$TITLE" --yesno "Automatisch ermittelter Hostname: $HOSTNAME_AUTO\nMöchtest du diesen übernehmen?" 10 70
  if [ $? -eq 0 ]; then
    VMNAME="$HOSTNAME_AUTO"
  else
    VMNAME=$(dialog --inputbox "Manueller VM-Name:" 10 70 "Migration-$(date +%s)" 3>&1 1>&2 2>&3)
  fi
else
  VMNAME=$(dialog --inputbox "Hostname konnte nicht ermittelt werden.\nBitte VM-Namen eingeben:" 10 70 "Migration-$(date +%s)" 3>&1 1>&2 2>&3)
fi

# ---------------- OLVM Zielangaben ----------------
ENGINE_URL=$(dialog --inputbox "OLVM Engine API URL (z.B. https://olvm.local/ovirt-engine/api):" 10 80 "https://" 3>&1 1>&2 2>&3)
CLUSTER=$(dialog --inputbox "Clustername in OLVM:" 10 80 "Default" 3>&1 1>&2 2>&3)
STORAGE=$(dialog --inputbox "Storage-Domain:" 10 80 "Data" 3>&1 1>&2 2>&3)
USERNAME=$(dialog --inputbox "Benutzer (z.B. admin@internal):" 10 80 "admin@internal" 3>&1 1>&2 2>&3)
PASSWORD=$(dialog --passwordbox "Passwort:" 10 80 3>&1 1>&2 2>&3)

# ---------------- OLVM API Test ----------------
msgbox "Teste Erreichbarkeit der OLVM-API..."
if ! curl -k -I --max-time 7 "$ENGINE_URL" 2>/dev/null | grep -qE "HTTP/.* (200|401)"; then
  die "OLVM-API ($ENGINE_URL) nicht erreichbar.\nBitte URL/Netzwerk/Firewall prüfen."
fi
echo "[INFO] OLVM erreichbar: $ENGINE_URL" >>"$LOGFILE"

# ---------------- CA-Handling ----------------
if [ -f /root/olvm-ca.pem ]; then
  dialog --yesno "Eine CA-Datei wurde gefunden (/root/olvm-ca.pem).\nDiese verwenden? (Nein = aus API neu laden)" 10 70
  if [ $? -eq 0 ]; then
    cp /root/olvm-ca.pem /tmp/olvm-ca.pem
  else
    curl -k -s -o /tmp/olvm-ca.pem "${ENGINE_URL%/api}/ca.crt" || die "CA konnte nicht geladen werden."
    cp /tmp/olvm-ca.pem /root/olvm-ca.pem
  fi
else
  curl -k -s -o /tmp/olvm-ca.pem "${ENGINE_URL%/api}/ca.crt" || die "CA konnte nicht geladen werden."
  cp /tmp/olvm-ca.pem /root/olvm-ca.pem
fi

# ---------------- Zusammenfassung ----------------
dialog --yesno "Quelle: $DISK\nVM-Name: $VMNAME\nCluster: $CLUSTER\nStorage: $STORAGE\nEngine: $ENGINE_URL\n\nFortfahren?" 12 80 || exit 0

# ---------------- Migration (virt-v2v Upload) ----------------
(
  echo "10"; echo "# Starte virt-v2v..."
  virt-v2v -v -x \
    -i disk "$DISK" \
    -o rhv-upload \
    -oo rhv-url="$ENGINE_URL" \
    -oo rhv-cafile=/tmp/olvm-ca.pem \
    -oo rhv-cluster="$CLUSTER" \
    -oo rhv-storage="$STORAGE" \
    -oo rhv-direct=true \
    -oo rhv-user="$USERNAME" \
    -oo rhv-password="$PASSWORD" \
    -on "$VMNAME" >>"$LOGFILE" 2>&1
  RC=$?
  if [ $RC -eq 0 ]; then
    echo "100"; echo "# Migration erfolgreich."
  else
    echo "100"; echo "# FEHLER! (siehe $LOGFILE)"
  fi
  sleep 1
) | dialog --title "$TITLE" --gauge "Migration läuft..." 10 80 0

# ---------------- Abschluss ----------------
dialog --title "$TITLE" --yesno "Migration abgeschlossen.\n\nLog: $LOGFILE\n\nSystem jetzt herunterfahren?" 10 70
if [ $? -eq 0 ]; then
  poweroff
else
  msgbox "System bleibt aktiv.\nLogs: $LOGFILE"
fi
