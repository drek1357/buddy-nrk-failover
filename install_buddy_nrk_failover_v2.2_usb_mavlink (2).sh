#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[-] Будь ласка, запустіть цей скрипт через sudo: sudo ./install.sh"
    exit 1
fi

echo "[+] Резервне копіювання конфігурації та GPS-кешу без видалення оригіналів..."
BACKUP_DIR="/var/backups/buddy-install-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
if [ -f /opt/buddy/config.json ]; then
    cp -p /opt/buddy/config.json "$BACKUP_DIR/config.json"
    echo "[+] Конфігурацію збережено в $BACKUP_DIR/config.json"
fi
if [ -f /opt/buddy/gps_last.json ]; then
    cp -p /opt/buddy/gps_last.json "$BACKUP_DIR/gps_last.json"
    echo "[+] GPS-кеш збережено в $BACKUP_DIR/gps_last.json"
fi

echo "[+] Зупинка старої служби..."
systemctl stop wifi-failover.service 2>/dev/null || true
systemctl disable wifi-failover.service 2>/dev/null || true
rm -f /etc/systemd/system/wifi-failover.service
systemctl daemon-reload
# Не видаляємо /opt/buddy: так зберігаються конфігурація, GPS-кеш та інші дані.

echo "[+] Встановлення системних залежностей..."
apt update
apt install -y python3 python3-flask python3-waitress network-manager iw curl iptables iproute2

echo "[+] Встановлення MAVLink Router для USB-підключення Matek H743..."
if ! command -v mavlink-routerd >/dev/null 2>&1; then
    if ! apt-get install -y mavlink-router; then
        echo "[!] Пакет mavlink-router недоступний у APT; збираємо офіційний MAVLink Router з вихідного коду..."
        apt-get install -y git meson ninja-build pkg-config gcc g++ libsystemd-dev libglib2.0-dev
        MAVLINK_BUILD_DIR="$(mktemp -d /tmp/buddy-mavlink-router.XXXXXX)"
        if ! git clone --depth 1 https://github.com/mavlink-router/mavlink-router.git "$MAVLINK_BUILD_DIR/src"; then
            echo "[-] Не вдалося завантажити MAVLink Router. Перевірте інтернет та повторіть інсталяцію."
            exit 1
        fi
        meson setup "$MAVLINK_BUILD_DIR/src/build" "$MAVLINK_BUILD_DIR/src" --buildtype=release
        ninja -C "$MAVLINK_BUILD_DIR/src/build"
        ninja -C "$MAVLINK_BUILD_DIR/src/build" install
        ldconfig
        rm -rf "$MAVLINK_BUILD_DIR"
    fi
fi
if ! command -v mavlink-routerd >/dev/null 2>&1; then
    echo "[-] mavlink-routerd не встановлено; неможливо налаштувати USB-MAVLink."
    exit 1
fi

# Вимикаємо штатний unit пакета, щоб він не конфліктував з BUDDY-маршрутом.
systemctl disable --now mavlink-router.service 2>/dev/null || true

# Налаштування USB-порту можна перевизначити вручну в цьому файлі.
mkdir -p /etc/default
if [ ! -f /etc/default/buddy-mavlink-router ]; then
    cat << 'MAVLINK_DEFAULTS_EOF' > /etc/default/buddy-mavlink-router
# Порожнє значення = автоматичний пошук /dev/serial/by-id/*, /dev/ttyACM*, /dev/ttyUSB*.
# Якщо знайдено не той послідовний пристрій, вкажіть точний шлях, наприклад /dev/ttyACM0.
MAVLINK_DEVICE=""
# Для USB CDC зазвичай достатньо 115200; значення використовується як параметр serial endpoint.
MAVLINK_BAUD="115200"
MAVLINK_WAIT_SEC="90"
MAVLINK_DEFAULTS_EOF
    chmod 600 /etc/default/buddy-mavlink-router
fi

cat << 'MAVLINK_LAUNCHER_EOF' > /usr/local/sbin/buddy-mavlink-router-start
#!/bin/bash
set -euo pipefail

DEFAULTS_FILE=/etc/default/buddy-mavlink-router
[ ! -f "$DEFAULTS_FILE" ] || source "$DEFAULTS_FILE"
MAVLINK_DEVICE="${MAVLINK_DEVICE:-}"
MAVLINK_BAUD="${MAVLINK_BAUD:-115200}"
MAVLINK_WAIT_SEC="${MAVLINK_WAIT_SEC:-90}"

if ! [[ "$MAVLINK_BAUD" =~ ^[0-9]+$ ]]; then
    echo "Invalid MAVLINK_BAUD; expected a number" >&2
    exit 2
fi
if ! [[ "$MAVLINK_WAIT_SEC" =~ ^[0-9]+$ ]]; then
    MAVLINK_WAIT_SEC=90
fi

find_usb_device() {
    local candidate
    if [ -n "$MAVLINK_DEVICE" ]; then
        if [ -e "$MAVLINK_DEVICE" ]; then
            printf '%s\n' "$MAVLINK_DEVICE"
            return 0
        fi
        return 1
    fi
    for candidate in /dev/serial/by-id/*; do
        if [ -e "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
    done
    for candidate in /dev/ttyACM* /dev/ttyUSB*; do
        if [ -e "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 1
}

DEVICE=""
WAITED=0
while [ "$WAITED" -lt "$MAVLINK_WAIT_SEC" ]; do
    DEVICE="$(find_usb_device || true)"
    if [ -n "$DEVICE" ]; then break; fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [ -z "$DEVICE" ]; then
    echo "Matek USB port not found after ${MAVLINK_WAIT_SEC}s. Check USB cable/device." >&2
    exit 1
fi
case "$DEVICE" in
    /dev/*) ;;
    *) echo "Invalid USB serial device path: $DEVICE" >&2; exit 2 ;;
esac

ROUTER_BIN="$(command -v mavlink-routerd || true)"
if [ -z "$ROUTER_BIN" ]; then echo "mavlink-routerd not found in PATH" >&2; exit 127; fi

# Використовуємо налаштовані в BUDDY порти, але перевіряємо їх як числа.
UDP_PORT="$(python3 -c 'import json; p="/opt/buddy/config.json"; c=json.load(open(p)) if __import__("os").path.exists(p) else {}; print(c.get("mavlink_port",14550))' 2>/dev/null || echo 14550)"
COMMAND_PORT="$(python3 -c 'import json,os; p="/opt/buddy/config.json"; c=json.load(open(p)) if os.path.exists(p) else {}; print(c.get("mavlink_local_src",14555))' 2>/dev/null || echo 14555)"
[[ "$UDP_PORT" =~ ^[0-9]+$ ]] || UDP_PORT=14550
[[ "$COMMAND_PORT" =~ ^[0-9]+$ ]] || COMMAND_PORT=14555
if [ "$UDP_PORT" -lt 1 ] || [ "$UDP_PORT" -gt 65535 ]; then UDP_PORT=14550; fi
if [ "$COMMAND_PORT" -lt 1 ] || [ "$COMMAND_PORT" -gt 65535 ] || [ "$COMMAND_PORT" = "$UDP_PORT" ]; then COMMAND_PORT=14555; fi

RUNTIME_DIR=/run/buddy-mavlink-router
CONFIG_FILE="$RUNTIME_DIR/main.conf"
mkdir -p "$RUNTIME_DIR/config.d"
chmod 700 "$RUNTIME_DIR"
cat > "$CONFIG_FILE" <<EOF
[General]
MavlinkDialect = ardupilotmega
ReportStats = true

[UartEndpoint matek_usb]
Device = $DEVICE
Baud = $MAVLINK_BAUD
FlowControl = false

# Копія телеметрії для BUDDY: парсинг GPS, статусів і журналу.
[UdpEndpoint buddy_app]
Mode = Normal
Address = 127.0.0.1
Port = $UDP_PORT

# Вхідні пакети від BUDDY (передані від QGroundControl) до Matek H743.
[UdpEndpoint buddy_commands]
Mode = Server
Address = 127.0.0.1
Port = $COMMAND_PORT
EOF
chmod 600 "$CONFIG_FILE"
echo "MAVLink USB device: $DEVICE; UDP telemetry: 127.0.0.1:$UDP_PORT; commands: 127.0.0.1:$COMMAND_PORT" >&2
exec "$ROUTER_BIN" -c "$CONFIG_FILE" -d "$RUNTIME_DIR/config.d"
MAVLINK_LAUNCHER_EOF
chmod 750 /usr/local/sbin/buddy-mavlink-router-start

cat << 'MAVLINK_SERVICE_EOF' > /etc/systemd/system/buddy-mavlink-router.service
[Unit]
Description=BUDDY USB MAVLink Router for Matek H743
After=wifi-failover.service systemd-udev-settle.service
Wants=wifi-failover.service systemd-udev-settle.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/buddy-mavlink-router-start
Restart=always
RestartSec=3
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
MAVLINK_SERVICE_EOF
systemctl daemon-reload
systemctl enable buddy-mavlink-router.service

if ! command -v zerotier-cli &> /dev/null; then
    echo "[+] Встановлення ZeroTier..."
    curl -s https://install.zerotier.com | bash
fi

echo "[+] Налаштування ZeroTier та NetworkManager (щоб NM не скидав інтерфейси zt*)..."
mkdir -p /etc/NetworkManager/conf.d
cat << 'NM_EOF' > /etc/NetworkManager/conf.d/99-unmanaged-zerotier.conf
[keyfile]
unmanaged-devices=interface-name:zt*
NM_EOF
systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager 2>/dev/null || true

systemctl enable zerotier-one 2>/dev/null || true
systemctl start zerotier-one 2>/dev/null || true

echo "[+] Увімкнення Wi-Fi модуля wlan0..."
nmcli radio wifi on 2>/dev/null || true
ip link set wlan0 up 2>/dev/null || true

echo "[+] Створення робочої директорії /opt/buddy..."
mkdir -p /opt/buddy
chmod 700 /opt/buddy
cd /opt/buddy

# Наявні config.json і gps_last.json залишаються на місці; права виставляємо без зміни вмісту.
if [ -f /opt/buddy/config.json ]; then chmod 600 /opt/buddy/config.json; fi
if [ -f /opt/buddy/gps_last.json ]; then chmod 600 /opt/buddy/gps_last.json; fi

echo "[+] Створення файлу app.py..."
cat << 'EOF' > /opt/buddy/app.py
#!/usr/bin/env python3
import os
import re
import json
import math
import shlex
import socket
import struct
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import logging
from logging.handlers import RotatingFileHandler
from functools import wraps
from flask import Flask, Response, jsonify, render_template_string, request

CONFIG_FILE = "/opt/buddy/config.json"
GPS_CACHE_FILE = "/opt/buddy/gps_last.json"

def load_config():
    default_config = {
        "admin_user": os.getenv("BUDDY_USER", "admin"),
        "admin_pass": os.getenv("BUDDY_PASS", "admin"),
        "telegram_token": os.getenv("BUDDY_TG_TOKEN", ""),
        "telegram_chat_id": os.getenv("BUDDY_TG_CHAT_ID", ""),
        "zerotier_net": "",
        "mavlink_port": 14550,
        "mavlink_local_src": 14555,
        "mavlink_command_src": 14556,
        "qgc_target_ip": "",
        "allow_open_wifi": True,
        "wifi_scan_delay_sec": 60,
        "wifi_scan_retry_sec": 60,
        "offline_gps_alert_sec": 300,
        "gps_max_speed_mps": 35.0,
        "gps_jump_threshold_m": 150.0
    }
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                for k, v in default_config.items():
                    if k not in data:
                        data[k] = v
                return data
        except Exception as e:
            logging.error(f"Помилка читання конфігурації: {e}")
    return default_config

def save_config_file(cfg):
    try:
        temp_file = CONFIG_FILE + ".tmp"
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=4, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temp_file, 0o600)
        os.replace(temp_file, CONFIG_FILE)
    except Exception as e:
        logging.error(f"Помилка збереження конфігурації: {e}")

config = load_config()

log_formatter = logging.Formatter('%(asctime)s [%(levelname)s] %(message)s')
file_handler = RotatingFileHandler('/opt/buddy/buddy.log', maxBytes=2*1024*1024, backupCount=3, encoding='utf-8')
file_handler.setFormatter(log_formatter)
console_handler = logging.StreamHandler()
console_handler.setFormatter(log_formatter)
logging.basicConfig(level=logging.INFO, handlers=[file_handler, console_handler])

app = Flask(__name__)

LAN_IFACE = "eth0"
WLAN_IFACE = "wlan0"
MAX_TELEGRAM_QUEUE_SIZE = 100

state_lock = threading.Lock()
current_mode = "LAN"
lan_has_internet = False
wlan_has_internet = False
lan_recovery_waiting = False
wifi_signal_strength = "Не підключено"
active_wifi_ssid = ""
failover_in_progress = False
mavlink_status_text = "Перевірка..."
mavlink_packets_count = 0

all_internet_lost_since = None
all_internet_alert_sent = False
lan_internet_lost_since = None
lan_internet_alert_sent = False
wlan_internet_lost_since = None
last_wifi_scan_attempt = 0.0
last_gps_disk_save = 0.0

gps_state = {
    "has_fix": False,
    "fix_type": 0,
    "satellites": 0,
    "valid_lat": None,
    "valid_lon": None,
    "valid_alt_m": None,
    "valid_speed_mps": 0.0,
    "valid_eph": None,
    "valid_timestamp": None,
    "raw_lat": None,
    "raw_lon": None,
    "raw_alt_m": None,
    "raw_timestamp": None,
    "spoofing_detected": False,
    "spoof_lat": None,
    "spoof_lon": None,
    "spoof_alt_m": None,
    "spoof_reason": "",
    "spoof_jump_m": 0.0,
    "spoof_speed_mps": 0.0,
    "spoof_timestamp": None,
    "spoof_alert_sent": False,
    "consistent_recovery_hits": 0
}

def load_gps_cache():
    if os.path.exists(GPS_CACHE_FILE):
        try:
            with open(GPS_CACHE_FILE, "r", encoding="utf-8") as f:
                saved = json.load(f)
            with state_lock:
                for k in [
                    "valid_lat", "valid_lon", "valid_alt_m", "valid_speed_mps",
                    "valid_timestamp", "satellites", "spoofing_detected",
                    "spoof_lat", "spoof_lon", "spoof_alt_m", "spoof_reason", "spoof_timestamp"
                ]:
                    if k in saved and saved[k] is not None:
                        gps_state[k] = saved[k]
                if gps_state["valid_lat"] is not None and gps_state["valid_lon"] is not None:
                    gps_state["has_fix"] = True
        except Exception as e:
            logging.warning(f"Не вдалося прочитати кеш GPS: {e}")

def save_gps_cache(force=False):
    global last_gps_disk_save
    now = time.time()
    if not force and (now - last_gps_disk_save) < 10.0:
        return
    last_gps_disk_save = now
    try:
        with state_lock:
            payload = {
                "valid_lat": gps_state["valid_lat"],
                "valid_lon": gps_state["valid_lon"],
                "valid_alt_m": gps_state["valid_alt_m"],
                "valid_speed_mps": gps_state["valid_speed_mps"],
                "valid_timestamp": gps_state["valid_timestamp"],
                "satellites": gps_state["satellites"],
                "spoofing_detected": gps_state["spoofing_detected"],
                "spoof_lat": gps_state["spoof_lat"],
                "spoof_lon": gps_state["spoof_lon"],
                "spoof_alt_m": gps_state["spoof_alt_m"],
                "spoof_reason": gps_state["spoof_reason"],
                "spoof_timestamp": gps_state["spoof_timestamp"]
            }
        temp_file = GPS_CACHE_FILE + ".tmp"
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temp_file, 0o600)
        os.replace(temp_file, GPS_CACHE_FILE)
    except Exception as e:
        logging.debug(f"Помилка збереження кешу GPS: {e}")

load_gps_cache()

telegram_queue = []
queue_lock = threading.Lock()
flush_lock = threading.Lock()
last_tg_update_id = 0

def check_auth(username, password):
    return username == config["admin_user"] and password == config["admin_pass"]

def authenticate():
    return Response(
        'Вхід заборонено. Введіть правильний логін та пароль.\n', 401,
        {'WWW-Authenticate': 'Basic realm="NRK Failover Panel"'})

def requires_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.authorization
        if not auth or not check_auth(auth.username, auth.password):
            return authenticate()
        return f(*args, **kwargs)
    return decorated

def run_cmd(cmd, timeout=15):
    try:
        if isinstance(cmd, str):
            cmd = shlex.split(cmd)
        if os.geteuid() == 0 and cmd and cmd[0] == "sudo":
            cmd.pop(0)
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (res.stdout or "") + ("\n" + res.stderr if res.stderr else "")
        return out.strip()
    except Exception as e:
        logging.error(f"Помилка команди {cmd}: {e}")
        return str(e)

def haversine_m(lat1, lon1, lat2, lon2):
    r = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2.0) ** 2 + math.cos(phi1) * math.cos(phi2) * (math.sin(dlambda / 2.0) ** 2)
    return 2.0 * r * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1.0 - a)))

def format_ts(ts):
    if not ts:
        return "невідомо"
    return time.strftime("%H:%M:%S (%d.%m.%Y)", time.localtime(ts))

def update_gps_position(lat, lon, alt_m=0.0, fix_type=3, satellites=0, eph=None, speed_mps=0.0):
    if lat is None or lon is None:
        return
    if abs(lat) < 0.0001 and abs(lon) < 0.0001:
        return
    if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
        return

    now = time.time()
    max_speed = float(config.get("gps_max_speed_mps", 35.0))
    jump_thresh = float(config.get("gps_jump_threshold_m", 150.0))

    spoof_msg_to_send = None
    force_disk_save = False

    with state_lock:
        prev_raw_lat = gps_state["raw_lat"]
        prev_raw_lon = gps_state["raw_lon"]
        prev_raw_ts = gps_state["raw_timestamp"]

        gps_state["raw_lat"] = lat
        gps_state["raw_lon"] = lon
        gps_state["raw_alt_m"] = alt_m
        gps_state["raw_timestamp"] = now
        gps_state["fix_type"] = fix_type
        if satellites > 0:
            gps_state["satellites"] = satellites

        if fix_type < 2:
            return

        gps_state["has_fix"] = True
        prev_lat = gps_state["valid_lat"]
        prev_lon = gps_state["valid_lon"]
        prev_alt = gps_state["valid_alt_m"]
        prev_ts = gps_state["valid_timestamp"]

        is_spoof = False
        reason = ""
        dist_m = 0.0
        calc_speed = 0.0

        if prev_lat is not None and prev_lon is not None and prev_ts is not None:
            dt = max(0.2, now - prev_ts)
            dist_m = haversine_m(prev_lat, prev_lon, lat, lon)
            calc_speed = dist_m / dt

            if dist_m > jump_thresh and calc_speed > max_speed:
                is_spoof = True
                reason = f"Стрибок координат на {dist_m:.0f} м за {dt:.1f} с ({calc_speed:.1f} м/с > ліміту {max_speed:.0f} м/с)"
            elif prev_alt is not None and dt < 10.0 and abs(alt_m - prev_alt) > 250.0:
                is_spoof = True
                reason = f"Аномальний стрибок висоти на {abs(alt_m - prev_alt):.0f} м за {dt:.1f} с"

            if is_spoof and gps_state["spoofing_detected"] and prev_raw_lat is not None and prev_raw_ts is not None:
                raw_dt = max(0.2, now - prev_raw_ts)
                raw_dist = haversine_m(prev_raw_lat, prev_raw_lon, lat, lon)
                if (raw_dist / raw_dt) <= max_speed and raw_dt >= 0.8:
                    gps_state["consistent_recovery_hits"] += 1
                else:
                    gps_state["consistent_recovery_hits"] = 0

                if gps_state["consistent_recovery_hits"] >= 15 and dt > 60.0:
                    is_spoof = False
                    gps_state["consistent_recovery_hits"] = 0

        if is_spoof:
            gps_state["spoofing_detected"] = True
            gps_state["spoof_lat"] = lat
            gps_state["spoof_lon"] = lon
            gps_state["spoof_alt_m"] = alt_m
            gps_state["spoof_reason"] = reason
            gps_state["spoof_jump_m"] = dist_m
            gps_state["spoof_speed_mps"] = calc_speed
            gps_state["spoof_timestamp"] = now
            force_disk_save = True

            if not gps_state["spoof_alert_sent"]:
                gps_state["spoof_alert_sent"] = True
                spoof_msg_to_send = (
                    f"🚨 УВАГА! Зафіксовано GPS-СПУФІНГ!\n"
                    f"⚠️ Причина: {reason}\n"
                    f"📍 Координата спуфінгу: {lat:.6f}, {lon:.6f} (висота: {alt_m:.1f} м)\n"
                    f"🗺 Карта (спуфінг): https://maps.google.com/?q={lat:.6f},{lon:.6f}\n"
                    f"✅ Остання відома достовірна координата: {prev_lat:.6f}, {prev_lon:.6f} "
                    f"(оновлено о {format_ts(prev_ts)})\n"
                    f"🗺 Карта (достовірна): https://maps.google.com/?q={prev_lat:.6f},{prev_lon:.6f}"
                )
        else:
            gps_state["valid_lat"] = lat
            gps_state["valid_lon"] = lon
            gps_state["valid_alt_m"] = alt_m
            gps_state["valid_speed_mps"] = speed_mps
            gps_state["valid_eph"] = eph
            gps_state["valid_timestamp"] = now
            gps_state["consistent_recovery_hits"] = 0
            if gps_state["spoofing_detected"]:
                logging.info("GPS-координати повернулися в межі достовірного руху.")
                force_disk_save = True
            gps_state["spoofing_detected"] = False
            gps_state["spoof_alert_sent"] = False

    save_gps_cache(force=force_disk_save)

    if spoof_msg_to_send:
        send_telegram_message(spoof_msg_to_send)
        flush_telegram_queue_async()

def flag_statustext_spoofing(text_msg):
    low = text_msg.lower()
    if any(k in low for k in ["gps glitch", "spoof", "ekf2_gps", "ekf3_gps"]):
        now = time.time()
        with state_lock:
            gps_state["spoofing_detected"] = True
            gps_state["spoof_reason"] = f"Повідомлення автопілота: {text_msg}"
            gps_state["spoof_timestamp"] = now
            if gps_state["raw_lat"] is not None:
                gps_state["spoof_lat"] = gps_state["raw_lat"]
                gps_state["spoof_lon"] = gps_state["raw_lon"]
                gps_state["spoof_alt_m"] = gps_state["raw_alt_m"]
        save_gps_cache(force=True)

def parse_mavlink_datagram(data):
    idx = 0
    n = len(data)
    while idx < n:
        stx = data[idx]
        if stx == 0xFE:
            if idx + 6 > n:
                break
            payload_len = data[idx + 1]
            msgid = data[idx + 5]
            pkt_end = idx + 6 + payload_len + 2
            if pkt_end > n:
                break
            payload = data[idx + 6 : idx + 6 + payload_len]
            idx = pkt_end
        elif stx == 0xFD:
            if idx + 10 > n:
                break
            payload_len = data[idx + 1]
            incompat_flags = data[idx + 2]
            msgid = data[idx + 7] | (data[idx + 8] << 8) | (data[idx + 9] << 16)
            sig_len = 13 if (incompat_flags & 0x01) else 0
            pkt_end = idx + 10 + payload_len + 2 + sig_len
            if pkt_end > n:
                break
            payload = data[idx + 10 : idx + 10 + payload_len]
            idx = pkt_end
        else:
            idx += 1
            continue

        try:
            if msgid == 24:
                padded = payload.ljust(30, b'\x00')[:30]
                _, lat_i, lon_i, alt_mm, eph, _, vel_cms, _, fix_type, sats = struct.unpack('<QiiiHHHHBB', padded)
                if fix_type >= 2 and (lat_i != 0 or lon_i != 0):
                    update_gps_position(
                        lat=lat_i / 1e7,
                        lon=lon_i / 1e7,
                        alt_m=alt_mm / 1000.0,
                        fix_type=fix_type,
                        satellites=sats,
                        eph=eph / 100.0 if eph != 65535 else None,
                        speed_mps=vel_cms / 100.0 if vel_cms != 65535 else 0.0
                    )
            elif msgid == 33:
                padded = payload.ljust(28, b'\x00')[:28]
                _, lat_i, lon_i, alt_mm, _, vx_cms, vy_cms, _, _ = struct.unpack('<IiiiihhhH', padded)
                if lat_i != 0 or lon_i != 0:
                    spd = math.hypot(vx_cms / 100.0, vy_cms / 100.0)
                    update_gps_position(
                        lat=lat_i / 1e7,
                        lon=lon_i / 1e7,
                        alt_m=alt_mm / 1000.0,
                        fix_type=3,
                        satellites=0,
                        speed_mps=spd
                    )
            elif msgid == 253:
                padded = payload.ljust(51, b'\x00')[:51]
                txt = padded[1:51].split(b'\x00', 1)[0].decode('utf-8', errors='ignore').strip()
                if txt:
                    flag_statustext_spoofing(txt)
        except Exception as e:
            logging.debug(f"Помилка розбору MAVLink пакета (msgid={msgid}): {e}")

def gpsd_poller_worker():
    while True:
        try:
            with socket.create_connection(("127.0.0.1", 2947), timeout=5) as s:
                s.sendall(b'?WATCH={"enable":true,"json":true};\n')
                s_file = s.makefile("r", encoding="utf-8", errors="ignore")
                for line in s_file:
                    if '"class":"TPV"' in line:
                        try:
                            obj = json.loads(line)
                            mode = int(obj.get("mode", 0))
                            lat = obj.get("lat")
                            lon = obj.get("lon")
                            alt = float(obj.get("alt", 0.0))
                            spd = float(obj.get("speed", 0.0))
                            if mode >= 2 and lat is not None and lon is not None:
                                update_gps_position(float(lat), float(lon), alt_m=alt, fix_type=mode, speed_mps=spd)
                        except Exception:
                            pass
        except Exception:
            time.sleep(15)

def build_gps_summary_text():
    with state_lock:
        g = dict(gps_state)

    if not g["has_fix"] and g["valid_lat"] is None and g["spoof_lat"] is None:
        return "📍 GPS: Відомих координат ще немає (очікування даних MAVLink / GPS)"

    lines = []
    if g["spoofing_detected"]:
        s_lat = g["spoof_lat"] if g["spoof_lat"] is not None else g["raw_lat"]
        s_lon = g["spoof_lon"] if g["spoof_lon"] is not None else g["raw_lon"]
        s_alt = g["spoof_alt_m"] if g["spoof_alt_m"] is not None else (g["raw_alt_m"] or 0.0)
        lines.append("🚨 СТАТУС GPS: ВИЯВЛЕНО СПУФІНГ!")
        if g["spoof_reason"]:
            lines.append(f"⚠️ Причина: {g['spoof_reason']}")
        if s_lat is not None and s_lon is not None:
            lines.append(f"📍 Координата спуфінгу: {s_lat:.6f}, {s_lon:.6f} (вис: {s_alt:.1f} м, час: {format_ts(g['spoof_timestamp'])})")
            lines.append(f"🗺 Карта (спуфінг): https://maps.google.com/?q={s_lat:.6f},{s_lon:.6f}")
        if g["valid_lat"] is not None and g["valid_lon"] is not None:
            lines.append(
                f"✅ Остання відома чиста координата (до спуфінгу): {g['valid_lat']:.6f}, {g['valid_lon']:.6f} "
                f"(час: {format_ts(g['valid_timestamp'])})"
            )
            lines.append(f"🗺 Карта (до спуфінгу): https://maps.google.com/?q={g['valid_lat']:.6f},{g['valid_lon']:.6f}")
    else:
        v_lat = g["valid_lat"]
        v_lon = g["valid_lon"]
        v_alt = g["valid_alt_m"] or 0.0
        lines.append(f"📍 Останні відомі координати GPS (без спуфінгу): {v_lat:.6f}, {v_lon:.6f} (висота: {v_alt:.1f} м, супутників: {g['satellites']})")
        lines.append(f"🕒 Час фіксації: {format_ts(g['valid_timestamp'])}")
        lines.append(f"🗺 Google Maps: https://maps.google.com/?q={v_lat:.6f},{v_lon:.6f}")
    return "\n".join(lines)

def build_offline_5min_gps_alert(outage_seconds, scope_label="повна втрата Інтернету (LAN + Wi-Fi)"):
    mins = int(outage_seconds // 60)
    secs = int(outage_seconds % 60)
    with state_lock:
        g = dict(gps_state)

    header = f"⏱🚨 ВТРАТА ІНТЕРНЕТУ БІЛЬШЕ 5 ХВИЛИН ({mins} хв {secs} с — {scope_label})!\n"

    if not g["has_fix"] and g["valid_lat"] is None and g["spoof_lat"] is None:
        return (
            header +
            "📍 Останні відомі координати GPS: відсутні (дані від автопілота ще не надходили)."
        )

    if g["spoofing_detected"]:
        s_lat = g["spoof_lat"] if g["spoof_lat"] is not None else g["raw_lat"]
        s_lon = g["spoof_lon"] if g["spoof_lon"] is not None else g["raw_lon"]
        s_alt = g["spoof_alt_m"] if g["spoof_alt_m"] is not None else (g["raw_alt_m"] or 0.0)
        msg = (
            header +
            "🚨 УВАГА: БУВ ЗАФІКСОВАНИЙ GPS-СПУФІНГ!\n"
            f"⚠️ Деталі спуфінгу: {g['spoof_reason'] or 'Аномальний стрибок координат'}\n"
            f"📍 Координата спуфінгу: {s_lat:.6f}, {s_lon:.6f} (висота: {s_alt:.1f} м)\n"
            f"🕒 Час фіксації спуфінгу: {format_ts(g['spoof_timestamp'])}\n"
            f"🗺 Координата спуфінгу на карті: https://maps.google.com/?q={s_lat:.6f},{s_lon:.6f}"
        )
        if g["valid_lat"] is not None and g["valid_lon"] is not None:
            msg += (
                f"\n\n✅ Остання відома достовірна координата (до спуфінгу): "
                f"{g['valid_lat']:.6f}, {g['valid_lon']:.6f} ({format_ts(g['valid_timestamp'])})\n"
                f"🗺 Достовірна точка: https://maps.google.com/?q={g['valid_lat']:.6f},{g['valid_lon']:.6f}"
            )
        return msg
    else:
        v_lat = g["valid_lat"]
        v_lon = g["valid_lon"]
        v_alt = g["valid_alt_m"] or 0.0
        return (
            header +
            "✅ Спуфінгу GPS не було.\n"
            f"📍 Останні відомі координати GPS: {v_lat:.6f}, {v_lon:.6f}\n"
            f"⛰ Висота: {v_alt:.1f} м | 🛰 Супутників: {g['satellites']} | 🚗 Швидкість: {g['valid_speed_mps']:.1f} м/с\n"
            f"🕒 Час фіксації координат: {format_ts(g['valid_timestamp'])}\n"
            f"🗺 Google Maps: https://maps.google.com/?q={v_lat:.6f},{v_lon:.6f}"
        )

def send_telegram_message(message, reply_markup=None):
    logging.info(f"[TG] {message}")
    if not config.get("telegram_token") or not config.get("telegram_chat_id"):
        return
    item = {"text": message, "reply_markup": reply_markup}
    with queue_lock:
        if len(telegram_queue) >= MAX_TELEGRAM_QUEUE_SIZE:
            telegram_queue.pop(0)
        telegram_queue.append(item)

def flush_telegram_queue():
    if not config.get("telegram_token") or not config.get("telegram_chat_id"):
        return
    if not flush_lock.acquire(blocking=False):
        return
    try:
        with queue_lock:
            if not telegram_queue:
                return
            messages_to_send = list(telegram_queue)

        sent_count = 0
        for item in messages_to_send:
            url = f"https://api.telegram.org/bot{config['telegram_token']}/sendMessage"
            payload = {
                'chat_id': config['telegram_chat_id'],
                'text': item['text']
            }
            if item.get('reply_markup'):
                payload['reply_markup'] = json.dumps(item['reply_markup'])
            data = urllib.parse.urlencode(payload).encode('utf-8')
            try:
                req = urllib.request.Request(url, data=data, headers={'User-Agent': 'NRKBuddy/2.2'})
                urllib.request.urlopen(req, timeout=5)
                sent_count += 1
            except Exception as e:
                logging.warning(f"Не вдалося доставити повідомлення в Telegram: {e}")
                break

        if sent_count > 0:
            with queue_lock:
                del telegram_queue[:sent_count]
    finally:
        flush_lock.release()

def flush_telegram_queue_async():
    threading.Thread(target=flush_telegram_queue, daemon=True).start()

def build_status_report():
    zt = get_zerotier_details()
    lan_ip = get_iface_ip(LAN_IFACE)
    wlan_ip = get_iface_ip(WLAN_IFACE)
    mav_port = config.get("mavlink_port", 14550)
    with state_lock:
        mode = current_mode
        lan_ok = lan_has_internet
        wlan_ok = wlan_has_internet
        sig = wifi_signal_strength
    qgc_ip = zt["ip"] if zt["ip"] != "Немає" else (wlan_ip if mode == "WIFI" and wlan_ip != "Немає" else lan_ip)
    gps_txt = build_gps_summary_text()
    return (
        f"📊 СТАТУС БОРТУ NRK:\n"
        f"🔹 Активний режим: {'🔌 LAN (Кабель)' if mode == 'LAN' else '📡 Wi-Fi (Резерв)'}\n"
        f"🔹 Інтернет на LAN (eth0): {'🟢 Є' if lan_ok else '🔴 Немає'} (IP: {lan_ip})\n"
        f"🔹 Інтернет на Wi-Fi (wlan0): {'🟢 Є' if wlan_ok else '🔴 Немає'} (IP: {wlan_ip})\n"
        f"🔹 Сигнал Wi-Fi: {sig}\n"
        f"🌐 ZeroTier: {zt['state']} | Мережа: {zt['net_status']}\n"
        f"🌐 ZeroTier IP: {zt['ip']}\n"
        f"🎯 QGroundControl (UDP): {qgc_ip}:{mav_port}\n\n"
        f"{gps_txt}"
    )

def telegram_poller_worker():
    global last_tg_update_id
    while True:
        token = config.get("telegram_token", "").strip()
        chat_id_cfg = str(config.get("telegram_chat_id", "")).strip()
        if not token or not chat_id_cfg:
            time.sleep(5)
            continue
        try:
            url = f"https://api.telegram.org/bot{token}/getUpdates?offset={last_tg_update_id + 1}&timeout=10"
            req = urllib.request.Request(url, headers={'User-Agent': 'NRKBuddy/2.2'})
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode('utf-8'))
            if data.get("ok"):
                for upd in data.get("result", []):
                    last_tg_update_id = upd["update_id"]
                    cmd_text = ""
                    from_chat = ""
                    if "message" in upd and "text" in upd["message"]:
                        cmd_text = upd["message"]["text"].strip()
                        from_chat = str(upd["message"]["chat"]["id"])
                    elif "callback_query" in upd:
                        cmd_text = upd["callback_query"].get("data", "")
                        from_chat = str(upd["callback_query"]["message"]["chat"]["id"])

                    if from_chat != chat_id_cfg:
                        continue

                    if cmd_text in ["/status", "status"]:
                        send_telegram_message(build_status_report(), reply_markup={
                            "inline_keyboard": [
                                [{"text": "🔌 Перейти на LAN", "callback_data": "/lan"},
                                 {"text": "📡 Пошук Wi-Fi", "callback_data": "/wifi"}],
                                [{"text": "📍 Координати GPS", "callback_data": "/gps"},
                                 {"text": "🔄 Оновити статус", "callback_data": "/status"}]
                            ]
                        })
                        flush_telegram_queue_async()
                    elif cmd_text in ["/gps", "gps"]:
                        send_telegram_message(build_gps_summary_text())
                        flush_telegram_queue_async()
                    elif cmd_text in ["/lan", "switch_lan"]:
                        ok, msg = switch_to_lan_manual(source="Telegram")
                        send_telegram_message(msg)
                        flush_telegram_queue_async()
                    elif cmd_text in ["/wifi", "switch_wifi"]:
                        threading.Thread(target=auto_failover_routine, kwargs={"force_wifi": True}, daemon=True).start()
        except Exception:
            time.sleep(5)

def get_iface_ip(iface):
    out = run_cmd(["ip", "-4", "-br", "addr", "show", iface], timeout=5)
    for part in out.split():
        if "/" in part and not part.startswith("127."):
            return part.split("/")[0]
    return "Немає"

def get_iface_gateway(iface):
    out = run_cmd(["nmcli", "-g", "IP4.GATEWAY", "device", "show", iface], timeout=5)
    if out and "." in out and not out.startswith("Error"):
        return out.strip()
    routes = run_cmd(["ip", "-4", "route", "show", "dev", iface], timeout=5)
    for line in routes.splitlines():
        if "via " in line:
            parts = line.split()
            idx = parts.index("via")
            if idx + 1 < len(parts):
                return parts[idx + 1]
    return ""

def check_internet_lan():
    ip = get_iface_ip(LAN_IFACE)
    gw = get_iface_gateway(LAN_IFACE)
    if ip == "Немає" or not gw:
        return False
    test_ips = ["8.8.4.4", "1.0.0.1"]
    for tip in test_ips:
        run_cmd(["ip", "route", "replace", f"{tip}/32", "via", gw, "dev", LAN_IFACE, "metric", "5"], timeout=3)
        res = subprocess.run(["ping", "-c", "1", "-W", "2", "-I", LAN_IFACE, tip], capture_output=True)
        if res.returncode == 0:
            return True
    return False

def check_internet_wlan():
    ip = get_iface_ip(WLAN_IFACE)
    if ip == "Немає":
        return False
    for tip in ["8.8.8.8", "1.1.1.1"]:
        res = subprocess.run(["ping", "-c", "1", "-W", "2", "-I", WLAN_IFACE, tip], capture_output=True)
        if res.returncode == 0:
            return True
    return False

def prioritize_wlan_route():
    wlan_gw = get_iface_gateway(WLAN_IFACE)
    if not wlan_gw:
        return False

    run_cmd(["ip", "route", "replace", "default", "via", wlan_gw, "dev", WLAN_IFACE, "metric", "10"], timeout=5)

    eth_gw = get_iface_gateway(LAN_IFACE)
    routes = run_cmd(["ip", "-4", "route", "show", "default", "dev", LAN_IFACE], timeout=5)
    for line in routes.splitlines():
        if "metric " not in line and eth_gw:
            run_cmd(["ip", "route", "replace", "default", "via", eth_gw, "dev", LAN_IFACE, "metric", "500"], timeout=5)
            run_cmd(["ip", "route", "del", "default", "via", eth_gw, "dev", LAN_IFACE, "metric", "0"], timeout=5)

    run_cmd(["ip", "route", "flush", "cache"], timeout=3)
    return True

def switch_to_lan_manual(source="Web"):
    global current_mode, lan_recovery_waiting, lan_has_internet
    run_cmd(["nmcli", "device", "connect", LAN_IFACE], timeout=10)
    time.sleep(2)
    if not check_internet_lan():
        return False, "❌ На кабелі (LAN) зараз немає доступу до інтернету! Перехід скасовано, залишаємось на резервному зв'язку."

    run_cmd(["ip", "route", "del", "default", "dev", WLAN_IFACE, "metric", "10"], timeout=5)
    run_cmd(["ip", "route", "del", "default", "dev", WLAN_IFACE, "metric", "50"], timeout=5)
    eth_gw = get_iface_gateway(LAN_IFACE)
    if eth_gw:
        run_cmd(["ip", "route", "replace", "default", "via", eth_gw, "dev", LAN_IFACE, "metric", "100"], timeout=5)
    # Wi-Fi залишаємо підключеним; змінюємо лише пріоритет маршрутів.
    run_cmd(["ip", "route", "flush", "cache"], timeout=3)

    with state_lock:
        current_mode = "LAN"
        lan_recovery_waiting = False
        lan_has_internet = True

    ensure_zerotier_connected(rebind=True)
    zt = get_zerotier_details()
    lan_ip = get_iface_ip(LAN_IFACE)
    mav_port = config.get("mavlink_port", 14550)
    msg = (
        f"🔌 Виконано перехід на основний кабель (LAN) за командою ({source})!\n"
        f"🌐 LAN IP: {lan_ip}\n"
        f"🌐 ZeroTier IP: {zt['ip']} ({zt['state']})\n"
        f"🎯 QGroundControl UDP: {zt['ip'] if zt['ip'] != 'Немає' else lan_ip}:{mav_port}"
    )
    send_telegram_message(msg)
    flush_telegram_queue_async()
    return True, msg

def ensure_wifi_up():
    run_cmd(["nmcli", "radio", "wifi", "on"], timeout=5)
    run_cmd(["ip", "link", "set", WLAN_IFACE, "up"], timeout=5)

def get_wifi_signal():
    # Лише читаємо стан поточного з'єднання. Не використовуємо `nmcli device wifi list`,
    # бо NetworkManager може запускати сканування ще до завершення таймера затримки.
    out = run_cmd(["iw", "dev", WLAN_IFACE, "link"], timeout=5)
    if "Not connected" in out or "not connected" in out.lower() or not out:
        return "Не підключено", ""

    ssid_match = re.search(r"^\s*SSID:\s*(.+)$", out, flags=re.MULTILINE)
    signal_match = re.search(r"^\s*signal:\s*(-?\d+)\s*dBm", out, flags=re.MULTILINE)
    if not ssid_match:
        return "Не підключено", ""

    ssid = ssid_match.group(1).strip()
    if signal_match:
        dbm = int(signal_match.group(1))
        signal_pct = max(0, min(100, round(2 * (dbm + 100))))
        return f"{ssid} ({signal_pct}%)", ssid
    return ssid, ssid

def get_saved_wifi_connections():
    out = run_cmd(["nmcli", "-t", "-f", "NAME,UUID,TYPE,DEVICE", "connection", "show"], timeout=5)
    saved = []
    for line in out.splitlines():
        parts = re.split(r'(?<!\\):', line)
        if len(parts) >= 4 and ("wireless" in parts[2] or "wifi" in parts[2]):
            saved.append({
                "name": parts[0].replace('\\:', ':'),
                "uuid": parts[1],
                "active": parts[3] == WLAN_IFACE
            })
    return saved

def scan_all_wifi_networks():
    ensure_wifi_up()
    run_cmd(["nmcli", "dev", "wifi", "rescan", "ifname", WLAN_IFACE], timeout=10)
    out = run_cmd(["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,BARS,SECURITY", "device", "wifi", "list", "ifname", WLAN_IFACE], timeout=10)
    saved_names = {s["name"] for s in get_saved_wifi_connections()}
    networks = []
    seen_ssids = set()
    for line in out.splitlines():
        parts = re.split(r'(?<!\\):', line)
        if len(parts) >= 5:
            in_use = parts[0] == '*'
            ssid = parts[1].replace('\\:', ':').strip()
            if not ssid or ssid == "--":
                continue
            try:
                signal = int(parts[2])
            except ValueError:
                signal = 0
            bars = parts[3]
            security = parts[4]
            if ssid not in seen_ssids:
                seen_ssids.add(ssid)
                networks.append({
                    "in_use": in_use,
                    "ssid": ssid,
                    "signal": signal,
                    "bars": bars,
                    "security": security,
                    "is_saved": ssid in saved_names
                })
    networks.sort(key=lambda x: (x["is_saved"], x["signal"]), reverse=True)
    return networks

def connect_to_wifi_network(ssid, password=""):
    ensure_wifi_up()
    saved_map = {s["name"]: s["uuid"] for s in get_saved_wifi_connections()}

    if password:
        if ssid in saved_map:
            uuid = saved_map[ssid]
            run_cmd(["nmcli", "connection", "modify", "uuid", uuid, "wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", password], timeout=5)
            cmd = ["nmcli", "connection", "up", "uuid", uuid, "ifname", WLAN_IFACE]
        else:
            cmd = ["nmcli", "device", "wifi", "connect", ssid, "password", password, "ifname", WLAN_IFACE]
    else:
        if ssid in saved_map:
            cmd = ["nmcli", "connection", "up", "uuid", saved_map[ssid], "ifname", WLAN_IFACE]
        else:
            cmd = ["nmcli", "device", "wifi", "connect", ssid, "ifname", WLAN_IFACE]

    res = run_cmd(cmd, timeout=25)
    success = ("successfully activated" in res.lower()) or ("успішно" in res.lower())
    if success:
        time.sleep(2)
        prioritize_wlan_route()
    return success, res

def auto_failover_routine(force_wifi=False):
    global failover_in_progress, current_mode, wlan_has_internet, last_wifi_scan_attempt
    with state_lock:
        if failover_in_progress:
            return "Already in progress"
        failover_in_progress = True
        last_wifi_scan_attempt = time.time()

    try:
        ensure_wifi_up()
        if not force_wifi:
            run_cmd(["nmcli", "device", "connect", LAN_IFACE], timeout=8)
            time.sleep(2)
            if check_internet_lan():
                with state_lock:
                    current_mode = "LAN"
                send_telegram_message("✅ Перевірка завершена: Інтернет на кабелі (LAN) працює стабільно.")
                flush_telegram_queue_async()
                return "LAN active"

        send_telegram_message("🔍 Пошук доступних Wi-Fi мереж з інтернетом...")
        visible_wifis = scan_all_wifi_networks()
        candidates = []

        for net in visible_wifis:
            ssid = net["ssid"]
            is_open = (not net["security"] or net["security"] == '--' or net["security"] == '')
            if net["is_saved"]:
                candidates.append({"ssid": ssid, "is_saved": True, "signal": net["signal"]})
            elif is_open and config.get("allow_open_wifi", True):
                candidates.append({"ssid": ssid, "is_saved": False, "signal": net["signal"]})

        if not candidates:
            send_telegram_message("⚠️ Не знайдено жодної збереженої або відкритої Wi-Fi мережі в ефірі.")
            return "No Wi-Fi candidates"

        for cand in candidates:
            ssid = cand["ssid"]
            logging.info(f"Пробуємо Wi-Fi кандидата: {ssid} ({cand['signal']}%)")
            ok, _ = connect_to_wifi_network(ssid, password="")
            if not ok:
                continue
            time.sleep(3)
            prioritize_wlan_route()
            if check_internet_wlan():
                with state_lock:
                    current_mode = "WIFI"
                    wlan_has_internet = True
                ensure_zerotier_connected(rebind=True)
                zt = get_zerotier_details()
                wlan_ip = get_iface_ip(WLAN_IFACE)
                mav_port = config.get("mavlink_port", 14550)
                qgc_ip = zt["ip"] if zt["ip"] != "Немає" else wlan_ip
                send_telegram_message(
                    f"✅ УСПІШНО! Роботу переведено на резервний Wi-Fi: {ssid} ({cand['signal']}%)\n"
                    f"📡 Wi-Fi IP: {wlan_ip}\n"
                    f"🌐 ZeroTier: {zt['ip']} ({zt['state']})\n"
                    f"🎯 QGroundControl UDP: {qgc_ip}:{mav_port}\n"
                    f"👁 Моніторинг LAN (eth0) триває у фоновому режимі."
                )
                flush_telegram_queue_async()
                return f"Connected to Wi-Fi: {ssid}"
            else:
                send_telegram_message(f"⚠️ Підключено до Wi-Fi «{ssid}», але інтернет у ній відсутній. Шукаю далі...")

        send_telegram_message("❌ Критично: Жодна зі знайдених Wi-Fi мереж не має виходу в Інтернет. Повторний пошук через 10 сек.")
        return "Failed"
    finally:
        with state_lock:
            failover_in_progress = False

def get_zerotier_details():
    node_id = "Невідомо"
    state = "OFFLINE"
    net_id = config.get("zerotier_net", "").strip()
    net_status = "НЕ ПІДКЛЮЧЕНО"
    zt_ip = "Немає"
    zt_iface = ""

    info_json_raw = run_cmd(["zerotier-cli", "-j", "info"], timeout=5)
    parsed_info = False
    try:
        info_obj = json.loads(info_json_raw)
        if isinstance(info_obj, dict) and "address" in info_obj:
            node_id = str(info_obj.get("address", "Невідомо"))
            state = "ONLINE" if info_obj.get("online") else "OFFLINE"
            parsed_info = True
    except Exception:
        pass

    if not parsed_info:
        info_out = run_cmd(["zerotier-cli", "info"], timeout=5)
        parts = info_out.split()
        if len(parts) >= 3 and parts[0] == "200":
            node_id = parts[2]
        if len(parts) >= 5 and parts[0] == "200":
            state = parts[4]

    nets_json_raw = run_cmd(["zerotier-cli", "-j", "listnetworks"], timeout=5)
    parsed_nets = False
    try:
        nets_list = json.loads(nets_json_raw)
        if isinstance(nets_list, list):
            parsed_nets = True
            target_net = None
            for n_obj in nets_list:
                nwid = str(n_obj.get("nwid") or n_obj.get("id") or "")
                if net_id and nwid == net_id:
                    target_net = n_obj
                    break
            if target_net is None and len(nets_list) > 0:
                target_net = nets_list[0]

            if target_net:
                net_id = str(target_net.get("nwid") or target_net.get("id") or net_id)
                net_status = str(target_net.get("status", "UNKNOWN"))
                zt_iface = str(target_net.get("portDeviceName", ""))
                assigned = target_net.get("assignedAddresses") or []
                for ip_item in assigned:
                    if "." in ip_item:
                        zt_ip = ip_item.split("/")[0]
                        break
    except Exception:
        pass

    if not parsed_nets:
        net_out = run_cmd(["zerotier-cli", "listnetworks"], timeout=5)
        for line in net_out.splitlines():
            if line.startswith("200 listnetworks") and "<nwid>" not in line:
                m_nwid = re.search(r'\b([0-9a-fA-F]{16})\b', line)
                if m_nwid:
                    net_id = m_nwid.group(1)
                for st in ["OK", "ACCESS_DENIED", "REQUESTING_CONFIGURATION", "PORT_ERROR", "NOT_FOUND"]:
                    if f" {st} " in line:
                        net_status = st
                        break
                m_dev = re.search(r'\b(zt[a-z0-9]+)\b', line)
                if m_dev:
                    zt_iface = m_dev.group(1)
                m_ip = re.search(r'\b(\d{1,3}(?:\.\d{1,3}){3})/\d{1,2}\b', line)
                if m_ip:
                    zt_ip = m_ip.group(1)

    if zt_ip == "Немає":
        if zt_iface:
            iface_ip = get_iface_ip(zt_iface)
            if iface_ip != "Немає":
                zt_ip = iface_ip
        else:
            ip_br = run_cmd(["ip", "-4", "-br", "addr", "show"], timeout=5)
            for line in ip_br.splitlines():
                parts = line.split()
                if len(parts) >= 3 and parts[0].startswith("zt"):
                    zt_iface = parts[0]
                    for p in parts[2:]:
                        if "/" in p and not p.startswith("127."):
                            zt_ip = p.split("/")[0]
                            break
                    if zt_ip != "Немає":
                        break

    return {
        "node_id": node_id,
        "state": state,
        "net_id": net_id,
        "net_status": net_status,
        "ip": zt_ip,
        "iface": zt_iface
    }

def ensure_zerotier_connected(rebind=False):
    srv_state = run_cmd(["systemctl", "is-active", "zerotier-one"], timeout=5)
    if srv_state.strip() != "active":
        run_cmd(["systemctl", "start", "zerotier-one"], timeout=10)
        time.sleep(2)
    elif rebind:
        run_cmd(["systemctl", "restart", "zerotier-one"], timeout=10)
        time.sleep(2)

    zt_net = config.get("zerotier_net", "").strip()
    if zt_net and re.fullmatch(r'[0-9a-fA-F]{16}', zt_net):
        zt = get_zerotier_details()
        if zt["net_id"] != zt_net or zt["net_status"] in ["НЕ ПІДКЛЮЧЕНО", "NOT_FOUND"]:
            run_cmd(["zerotier-cli", "join", zt_net], timeout=8)
        run_cmd(["zerotier-cli", "set", zt_net, "allowManaged=1"], timeout=5)

def ensure_iptables_rule(chain, rule_args):
    chk = subprocess.run(["iptables", "-C", chain] + rule_args, capture_output=True)
    if chk.returncode != 0:
        run_cmd(["iptables", "-I", chain] + rule_args, timeout=3)

def setup_mavlink_and_zt_firewall(port):
    p_str = str(port)
    ensure_iptables_rule("INPUT", ["-p", "udp", "--dport", p_str, "-j", "ACCEPT"])
    ensure_iptables_rule("OUTPUT", ["-p", "udp", "--sport", p_str, "-j", "ACCEPT"])
    ensure_iptables_rule("INPUT", ["-p", "udp", "--dport", "9993", "-j", "ACCEPT"])
    ensure_iptables_rule("INPUT", ["-i", "zt+", "-j", "ACCEPT"])
    ensure_iptables_rule("OUTPUT", ["-o", "zt+", "-j", "ACCEPT"])
    ensure_iptables_rule("FORWARD", ["-i", "zt+", "-j", "ACCEPT"])

def drain_udp_socket_worker(sock):
    """Drain replies addressed to the command socket; telemetry is copied to port 14550."""
    sock.settimeout(1.0)
    while True:
        try:
            sock.recvfrom(65535)
        except socket.timeout:
            continue
        except Exception as e:
            logging.debug(f"Завершено читання допоміжного UDP-сокета MAVLink: {e}")
            return

def mavlink_udp_proxy_worker():
    global mavlink_status_text, mavlink_packets_count
    sock = None
    bound_port = None
    qgc_clients = set()
    last_fw_check = 0
    last_router_status_check = 0
    router_active = False
    command_sock = None
    try:
        command_source_port = int(config.get("mavlink_command_src", 14556))
        if not (1 <= command_source_port <= 65535):
            command_source_port = 14556
        command_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        command_sock.bind(("127.0.0.1", command_source_port))
        command_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
        threading.Thread(target=drain_udp_socket_worker, args=(command_sock,), daemon=True).start()
    except Exception as e:
        logging.error(f"Не вдалося створити UDP-сокет команд MAVLink: {e}")
        command_sock = None

    while True:
        port = int(config.get("mavlink_port", 14550))
        local_src_port = int(config.get("mavlink_local_src", 14555))
        target_ip = config.get("qgc_target_ip", "").strip()

        now = time.time()
        if now - last_fw_check > 30 or bound_port != port:
            setup_mavlink_and_zt_firewall(port)
            last_fw_check = now

        if now - last_router_status_check > 10:
            router_state = run_cmd(["systemctl", "is-active", "buddy-mavlink-router.service"], timeout=3).strip()
            router_active = (router_state == "active")
            last_router_status_check = now
            with state_lock:
                if router_active:
                    mavlink_status_text = f"UDP-проксі :{port} активний; USB-MAVLink Router працює"
                else:
                    mavlink_status_text = f"UDP-проксі :{port} активний; USB-MAVLink Router не активний ({router_state or 'невідомо'})"

        if sock is None or bound_port != port:
            if sock:
                sock.close()
                sock = None

            ss_out = run_cmd(["ss", "-ulnp"], timeout=3)
            if f":{port} " in ss_out and "python3" not in ss_out:
                with state_lock:
                    mavlink_status_text = f"Активний системний MAVLink-роутер (UDP :{port} відкрито)"
                time.sleep(5)
                continue

            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                sock.bind(("0.0.0.0", port))
                sock.settimeout(1.0)
                bound_port = port
                with state_lock:
                    mavlink_status_text = f"Вбудований UDP-проксі активний на 0.0.0.0:{port}"
            except Exception as e:
                with state_lock:
                    mavlink_status_text = f"Порт UDP :{port} використовується іншою службою ({e})"
                time.sleep(5)
                continue

        try:
            data, addr = sock.recvfrom(4096)
            if data:
                with state_lock:
                    mavlink_packets_count += 1
                if addr[0].startswith("127.") or addr[1] == local_src_port:
                    parse_mavlink_datagram(data)
                    for client in list(qgc_clients):
                        try:
                            sock.sendto(data, client)
                        except Exception:
                            pass
                    if target_ip:
                        try:
                            sock.sendto(data, (target_ip, port))
                        except Exception:
                            pass
                else:
                    parse_mavlink_datagram(data)
                    qgc_clients.add(addr)
                    try:
                        if command_sock is not None:
                            command_sock.sendto(data, ("127.0.0.1", local_src_port))
                        else:
                            logging.error("Команди MAVLink не надіслано: UDP command socket недоступний")
                    except Exception as e:
                        logging.error(f"Помилка пересилання MAVLink-команди до USB Router: {e}")
        except socket.timeout:
            pass
        except Exception:
            if sock:
                sock.close()
                sock = None
            time.sleep(1)

def network_monitor_worker():
    global lan_has_internet, wlan_has_internet, wifi_signal_strength, active_wifi_ssid
    global current_mode, lan_recovery_waiting
    global all_internet_lost_since, all_internet_alert_sent
    global lan_internet_lost_since, lan_internet_alert_sent
    global wlan_internet_lost_since, last_wifi_scan_attempt

    ensure_zerotier_connected(rebind=False)

    time.sleep(2)
    lan_ok_init = check_internet_lan()
    wlan_ok_init = check_internet_wlan()
    with state_lock:
        lan_has_internet = lan_ok_init
        wlan_has_internet = wlan_ok_init
        if not lan_ok_init and wlan_ok_init:
            current_mode = "WIFI"
            prioritize_wlan_route()
        else:
            current_mode = "LAN"

    send_telegram_message(
        "🚀 Служба BUDDY NRK Failover v2.2 (GPS + Anti-Spoof + ZeroTier Fix) запущена!\n" + build_status_report(),
        reply_markup={
            "inline_keyboard": [
                [{"text": "📊 Статус", "callback_data": "/status"},
                 {"text": "📍 GPS", "callback_data": "/gps"},
                 {"text": "📡 Тест Wi-Fi", "callback_data": "/wifi"}]
            ]
        }
    )

    last_zt_state = ""
    zt_offline_cycles = 0

    while True:
        sig_str, ssid_now = get_wifi_signal()
        lan_ok = check_internet_lan()
        wlan_ok = check_internet_wlan()
        any_internet = lan_ok or wlan_ok

        ensure_zerotier_connected(rebind=False)
        zt_info = get_zerotier_details()
        if any_internet and zt_info["state"] != "ONLINE":
            zt_offline_cycles += 1
            if zt_offline_cycles >= 3:
                logging.info("ZeroTier у стані OFFLINE при наявному інтернеті — перезапуск zerotier-one...")
                ensure_zerotier_connected(rebind=True)
                zt_info = get_zerotier_details()
                zt_offline_cycles = 0
        else:
            zt_offline_cycles = 0

        now = time.time()
        alert_threshold_sec = int(config.get("offline_gps_alert_sec", 300))

        with state_lock:
            wifi_signal_strength = sig_str
            active_wifi_ssid = ssid_now
            lan_has_internet = lan_ok
            wlan_has_internet = wlan_ok
            mode = current_mode
            waiting_lan = lan_recovery_waiting

        if not any_internet:
            if all_internet_lost_since is None:
                all_internet_lost_since = now
                all_internet_alert_sent = False
            elif not all_internet_alert_sent and (now - all_internet_lost_since) >= alert_threshold_sec:
                all_internet_alert_sent = True
                alert_msg = build_offline_5min_gps_alert(
                    now - all_internet_lost_since,
                    scope_label="повна відсутність Інтернету (LAN + Wi-Fi)"
                )
                send_telegram_message(alert_msg)
        else:
            if all_internet_lost_since is not None and all_internet_alert_sent:
                down_dur = int(now - all_internet_lost_since)
                send_telegram_message(
                    f"🟢 Зв'язок з Інтернетом відновлено після перерви ({down_dur // 60} хв {down_dur % 60} с).\n"
                    + build_gps_summary_text()
                )
            all_internet_lost_since = None
            all_internet_alert_sent = False

        if not lan_ok:
            if lan_internet_lost_since is None:
                lan_internet_lost_since = now
                lan_internet_alert_sent = False
            elif not lan_internet_alert_sent and (now - lan_internet_lost_since) >= alert_threshold_sec:
                lan_internet_alert_sent = True
                if not all_internet_alert_sent:
                    alert_msg = build_offline_5min_gps_alert(
                        now - lan_internet_lost_since,
                        scope_label="втрата основного каналу LAN (eth0)"
                    )
                    send_telegram_message(alert_msg)
                    flush_telegram_queue_async()
        else:
            lan_internet_lost_since = None
            lan_internet_alert_sent = False

        if not wlan_ok:
            if wlan_internet_lost_since is None:
                wlan_internet_lost_since = now
        else:
            wlan_internet_lost_since = None

        zt_summary = f"{zt_info['state']}:{zt_info['net_status']}:{zt_info['ip']}"
        if last_zt_state and zt_summary != last_zt_state and zt_info['ip'] != "Немає":
            mav_port = config.get("mavlink_port", 14550)
            send_telegram_message(
                f"🌐 Оновився статус ZeroTier:\n"
                f"Стан: {zt_info['state']} ({zt_info['net_status']})\n"
                f"ZeroTier IP: {zt_info['ip']}\n"
                f"🎯 QGroundControl UDP: {zt_info['ip']}:{mav_port}"
            )
        last_zt_state = zt_summary

        if any_internet:
            flush_telegram_queue()

        if mode == "LAN":
            if not lan_ok:
                # Якщо wlan0 уже має інтернет, використовуємо його без повторного сканування.
                if wlan_ok:
                    prioritize_wlan_route()
                    with state_lock:
                        current_mode = "WIFI"
                    send_telegram_message(
                        "⚠️ Інтернет на кабелі (eth0) зник. Перемикаю маршрут на вже підключений Wi-Fi (wlan0), без нового сканування."
                    )
                    flush_telegram_queue_async()
                else:
                    scan_delay = max(0, int(config.get("wifi_scan_delay_sec", 60)))
                    retry_sec = max(10, int(config.get("wifi_scan_retry_sec", 60)))
                    lost_for = now - lan_internet_lost_since if lan_internet_lost_since is not None else 0
                    if lost_for >= scan_delay and (now - last_wifi_scan_attempt) >= retry_sec:
                        send_telegram_message(
                            f"⚠️ На кабелі (eth0) немає інтернету вже {int(lost_for)} с. "
                            f"Починаю пошук Wi-Fi після затримки {scan_delay} с..."
                        )
                        auto_failover_routine(force_wifi=True)
                    elif lost_for < scan_delay:
                        logging.info(
                            f"LAN без інтернету; очікування перед скануванням Wi-Fi: "
                            f"ще {max(0, int(scan_delay - lost_for))} с"
                        )
                    # Якщо пошук не знайшов мережу, повторюємо його не частіше ніж раз на retry_sec.
            else:
                with state_lock:
                    lan_recovery_waiting = False
                last_wifi_scan_attempt = 0.0

        elif mode == "WIFI":
            if wlan_ok:
                prioritize_wlan_route()
                last_wifi_scan_attempt = 0.0

            if lan_ok and not waiting_lan:
                with state_lock:
                    lan_recovery_waiting = True
                send_telegram_message(
                    "🟢 УВАГА! На кабелі (LAN / eth0) З'ЯВИВСЯ ІНТЕРНЕТ!\n"
                    f"Зараз НРК продовжує працювати через Wi-Fi: {sig_str}.\n"
                    "👉 Ви можете переключитися на кабель за командою у веб-панелі або натиснувши кнопку нижче:",
                    reply_markup={
                        "inline_keyboard": [
                            [{"text": "🔌 Перейти на LAN зараз", "callback_data": "/lan"}]
                        ]
                    }
                )
                flush_telegram_queue_async()
            elif not lan_ok and waiting_lan:
                with state_lock:
                    lan_recovery_waiting = False
                send_telegram_message("ℹ️ Інтернет на кабелі (LAN) знову зник. Залишаємось на резервному Wi-Fi.")
                flush_telegram_queue_async()

            if not wlan_ok:
                scan_delay = max(0, int(config.get("wifi_scan_delay_sec", 60)))
                retry_sec = max(10, int(config.get("wifi_scan_retry_sec", 60)))
                lost_for = now - wlan_internet_lost_since if wlan_internet_lost_since is not None else 0
                if lost_for >= scan_delay and (now - last_wifi_scan_attempt) >= retry_sec:
                    send_telegram_message(
                        f"⚠️ На поточному Wi-Fi ({sig_str}) немає інтернету вже {int(lost_for)} с. "
                        f"Починаю пошук іншої мережі після затримки {scan_delay} с..."
                    )
                    auto_failover_routine(force_wifi=True)
                elif lost_for < scan_delay:
                    logging.info(
                        f"Wi-Fi без інтернету; очікування перед повторним скануванням: "
                        f"ще {max(0, int(scan_delay - lost_for))} с"
                    )

        time.sleep(8)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="uk">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NRK BUDDY - Панель керування зв'язком та GPS</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 16px; }
        .container { max-width: 920px; margin: 0 auto; }
        .card { background: #1e293b; padding: 18px; border-radius: 8px; margin-bottom: 18px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.3); border: 1px solid #334155; }
        .card h2 { margin-top: 0; color: #f1f5f9; font-size: 1.15rem; border-bottom: 1px solid #334155; padding-bottom: 10px; margin-bottom: 14px; }
        .status-badge { display: inline-block; padding: 4px 10px; border-radius: 4px; font-weight: bold; font-size: 0.85rem; }
        .active { background: #166534; color: #4ade80; }
        .inactive { background: #991b1b; color: #fca5a5; }
        .warn { background: #9a3412; color: #fdba74; }
        .info { background: #0369a1; color: #e0f2fe; }
        .btn { border: none; padding: 8px 14px; border-radius: 5px; cursor: pointer; font-weight: 600; font-size: 13px; margin-right: 6px; margin-top: 6px; color: white; transition: opacity 0.15s; }
        .btn:hover { opacity: 0.9; }
        .btn-primary { background: #0284c7; }
        .btn-danger { background: #dc2626; }
        .btn-warning { background: #ea580c; }
        .btn-success { background: #16a34a; }
        .btn-sm { padding: 5px 10px; font-size: 12px; margin: 2px; }
        .lan-alert { display: none; background: linear-gradient(90deg, #166534, #15803d); border: 2px solid #4ade80; padding: 16px; border-radius: 8px; margin-bottom: 18px; align-items: center; justify-content: space-between; flex-wrap: wrap; }
        .spoof-alert { display: none; background: linear-gradient(90deg, #7f1d1d, #991b1b); border: 2px solid #f87171; padding: 14px; border-radius: 8px; margin-bottom: 18px; }
        .qgc-box { background: #020617; border: 1px solid #0284c7; padding: 12px 15px; border-radius: 6px; font-family: monospace; font-size: 13.5px; color: #38bdf8; margin-bottom: 10px; }
        pre { background: #020617; padding: 12px; border-radius: 6px; overflow-x: auto; font-family: monospace; font-size: 12.5px; color: #38bdf8; margin: 8px 0; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; font-size: 13.5px; }
        th, td { padding: 9px; text-align: left; border-bottom: 1px solid #334155; }
        th { background: #0f172a; color: #94a3b8; }
        input[type="text"], input[type="password"], input[type="number"] { background: #0f172a; border: 1px solid #475569; color: white; padding: 7px 10px; border-radius: 4px; width: 100%; box-sizing: border-box; margin-bottom: 10px; }
        .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
        @media (max-width: 680px) { .grid-2 { grid-template-columns: 1fr; } }
        label { font-size: 12.5px; color: #94a3b8; display: block; margin-bottom: 4px; }
    </style>
</head>
<body>
    <div class="container">
        <div id="lan-recovery-banner" class="lan-alert">
            <div>
                <div style="font-weight: bold; font-size: 1.05rem; color: #fff;">🟢 УВАГА: На кабелі (LAN / eth0) з'явився Інтернет!</div>
                <div style="font-size: 0.9rem; color: #dcfce7; margin-top: 4px;">НРК продовжує працювати через резервний Wi-Fi. Ви можете переключитися на кабель за командою:</div>
            </div>
            <button class="btn btn-primary" style="background:#fff; color:#166534; font-size:14px; padding:10px 18px;" onclick="switchToLan()">🔌 ПЕРЕЙТИ НА LAN ЗАРАЗ</button>
        </div>

        <div id="spoof-banner" class="spoof-alert">
            <div style="font-weight: bold; font-size: 1.05rem; color: #fecaca;">🚨 УВАГА: Зафіксовано GPS-спуфінг!</div>
            <div id="spoof-banner-details" style="font-size: 0.9rem; color: #fee2e2; margin-top: 4px;"></div>
        </div>

        <div class="card">
            <h2>📡 Статус зв'язку НРК, GPS та QGroundControl (MAVLink UDP)</h2>
            <div class="grid-2">
                <div>
                    <p><b>Поточний канал роботи:</b> <span id="current-mode" class="status-badge info">Завантаження...</span></p>
                    <p><b>Інтернет на LAN (eth0):</b> <span id="lan-status" class="status-badge warn">Перевірка...</span></p>
                    <p><b>Інтернет на Wi-Fi (wlan0):</b> <span id="wlan-status" class="status-badge warn">Перевірка...</span></p>
                    <p><b>Поточна мережа Wi-Fi:</b> <span id="wifi-signal" class="status-badge info">Очікування...</span></p>
                </div>
                <div>
                    <div class="qgc-box">
                        <div style="color:#94a3b8; font-size:12px; margin-bottom:4px;">🎯 Підключення QGroundControl (UDP):</div>
                        <div><b>ZeroTier IP:Порт:</b> <span id="qgc-zt-addr" style="color:#4ade80;">—</span></div>
                        <div><b>Локальний IP:Порт:</b> <span id="qgc-loc-addr" style="color:#facc15;">—</span></div>
                        <div style="font-size:11.5px; color:#cbd5e1; margin-top:6px;" id="mav-status">Перевірка MAVLink...</div>
                    </div>
                    <div class="qgc-box" style="border-color:#10b981;">
                        <div style="color:#94a3b8; font-size:12px; margin-bottom:4px;">📍 Останні відомі координати GPS та Анти-Спуфінг:</div>
                        <div><b>Статус:</b> <span id="gps-badge" class="status-badge info">Очікування...</span></div>
                        <div style="margin-top:4px;"><b>Остання відома координата:</b> <span id="gps-valid-coords" style="color:#4ade80;">Немає фіксації</span></div>
                        <div id="gps-spoof-row" style="display:none; margin-top:4px;"><b>Координата спуфінгу:</b> <span id="gps-spoof-coords" style="color:#f87171;">—</span></div>
                    </div>
                </div>
            </div>
            <p style="margin-bottom:4px;"><b>Мережеві інтерфейси та маршрути:</b></p>
            <pre id="ip-info">Завантаження...</pre>
            <button class="btn btn-success" onclick="switchToLan()">🔌 Перейти на LAN (eth0)</button>
            <button class="btn btn-warning" onclick="forceWifiFailover()">📡 Знайти робочий Wi-Fi</button>
            <button class="btn btn-primary" onclick="controlService('restart')">🔄 Перезапустити службу</button>
            <div id="action-msg" style="margin-top: 10px; font-weight: bold; color: #38bdf8;"></div>
        </div>

        <div class="card">
            <h2>🌐 Керування мережею ZeroTier</h2>
            <div class="grid-2">
                <div>
                    <p><b>Node ID:</b> <span id="zt-node-id" class="status-badge info">...</span></p>
                    <p><b>Стан клієнта:</b> <span id="zt-state" class="status-badge warn">...</span></p>
                </div>
                <div>
                    <p><b>Статус мережі:</b> <span id="zt-net-status" class="status-badge warn">...</span></p>
                    <p><b>Виданий ZeroTier IP:</b> <span id="zt-ip" class="status-badge active">...</span></p>
                </div>
            </div>
            <div style="margin-top: 10px;">
                <label>ZeroTier Network ID (16 hex-символів):</label>
                <div style="display:flex; gap:8px; flex-wrap:wrap;">
                    <input type="text" id="zt-net-input" placeholder="Наприклад: e59e59a0b9645f9c" style="margin-bottom:0; flex:1; min-width:200px;">
                    <button class="btn btn-success" style="margin-top:0; white-space:nowrap;" onclick="joinZeroTier()">Підключити ZT</button>
                    <button class="btn btn-primary" style="margin-top:0; white-space:nowrap;" onclick="restartZeroTier()">🔄 Перезапустити ZT</button>
                    <button class="btn btn-danger" style="margin-top:0; white-space:nowrap;" onclick="leaveZeroTier()">Відключити</button>
                </div>
                <div id="zt-msg" style="margin-top: 8px; font-weight: bold; color: #4ade80;"></div>
            </div>
        </div>

        <div class="card">
            <h2>📶 Пошук Wi-Fi мереж та підключення з паролем</h2>
            <button class="btn btn-warning" onclick="scanWifi()">🔍 Сканувати ефір зараз</button>
            <div id="wifi-container" style="margin-top: 12px;">Автоматичний пошук запускається після затримки, заданої в налаштуваннях. Для негайного ручного пошуку натисніть кнопку вище.</div>
        </div>

        <div class="card">
            <h2>💾 Збережені Wi-Fi мережі (Профілі пам'яті)</h2>
            <button class="btn btn-primary btn-sm" onclick="loadSavedWifi()">🔄 Оновити список</button>
            <div id="saved-wifi-container" style="margin-top: 10px;">Завантаження...</div>
        </div>

        <div class="card">
            <h2>⚙️ Налаштування MAVLink, GPS Анти-Спуфінгу, Telegram та Доступу</h2>
            <div class="grid-2">
                <div>
                    <label>Порт MAVLink UDP для QGroundControl:</label>
                    <input type="number" id="cfg-mav-port" placeholder="14550">
                    <label>IP оператора QGroundControl (опціонально для прямої відправки UDP):</label>
                    <input type="text" id="cfg-qgc-ip" placeholder="Наприклад: 172.27.27.10">
                    <div class="grid-2" style="gap:8px;">
                        <div>
                            <label>Таймер втрати Інтернету (сек):</label>
                            <input type="number" id="cfg-offline-sec" placeholder="300" min="1">
                        </div>
                        <div>
                            <label>Затримка пошуку Wi-Fi (сек):</label>
                            <input type="number" id="cfg-wifi-delay" placeholder="60" min="0">
                        </div>
                        <div>
                            <label>Інтервал повторного пошуку Wi-Fi (сек):</label>
                            <input type="number" id="cfg-wifi-retry" placeholder="60" min="10">
                        </div>
                        <div>
                            <label>Макс. швидкість НРК без спуфінгу (м/с):</label>
                            <input type="number" id="cfg-max-speed" placeholder="35">
                        </div>
                    </div>
                    <label style="margin-top:4px;">
                        <input type="checkbox" id="cfg-open-wifi" checked> Дозволити автопідключення до відкритих Wi-Fi мереж без пароля
                    </label>
                </div>
                <div>
                    <label>Telegram Bot Token:</label>
                    <input type="text" id="cfg-tg-token" placeholder="Токен бота">
                    <label>Telegram Chat ID:</label>
                    <input type="text" id="cfg-tg-chat" placeholder="ID чату">
                    <div class="grid-2" style="gap:8px;">
                        <div>
                            <label>Логін панелі:</label>
                            <input type="text" id="cfg-adm-user">
                        </div>
                        <div>
                            <label>Пароль панелі:</label>
                            <input type="password" id="cfg-adm-pass">
                        </div>
                    </div>
                </div>
            </div>
            <button class="btn btn-success" onclick="saveConfig()">💾 Зберегти налаштування</button>
            <div id="config-result" style="margin-top: 8px; font-weight: bold; color: #4ade80;"></div>
        </div>

        <div class="card">
            <h2>📋 Журнал подій (Логи у реальному часі)</h2>
            <button class="btn btn-primary btn-sm" onclick="loadLogs()">🔄 Оновити логи</button>
            <pre id="logs">Завантаження...</pre>
        </div>
    </div>

    <script>
        async function loadConfigData() {
            try {
                const res = await fetch('/api/config');
                const d = await res.json();
                document.getElementById('zt-net-input').value = d.zerotier_net || '';
                document.getElementById('cfg-tg-token').value = d.telegram_token || '';
                document.getElementById('cfg-tg-chat').value = d.telegram_chat_id || '';
                document.getElementById('cfg-adm-user').value = d.admin_user || '';
                document.getElementById('cfg-adm-pass').value = d.admin_pass || '';
                document.getElementById('cfg-mav-port').value = d.mavlink_port || 14550;
                document.getElementById('cfg-qgc-ip').value = d.qgc_target_ip || '';
                document.getElementById('cfg-offline-sec').value = d.offline_gps_alert_sec || 300;
                document.getElementById('cfg-wifi-delay').value = d.wifi_scan_delay_sec ?? 60;
                document.getElementById('cfg-wifi-retry').value = d.wifi_scan_retry_sec ?? 60;
                document.getElementById('cfg-max-speed').value = d.gps_max_speed_mps || 35;
                document.getElementById('cfg-open-wifi').checked = d.allow_open_wifi !== false;
            } catch (e) {}
        }

        async function saveConfig() {
            const payload = {
                zerotier_net: document.getElementById('zt-net-input').value.trim(),
                telegram_token: document.getElementById('cfg-tg-token').value.trim(),
                telegram_chat_id: document.getElementById('cfg-tg-chat').value.trim(),
                admin_user: document.getElementById('cfg-adm-user').value.trim(),
                admin_pass: document.getElementById('cfg-adm-pass').value,
                mavlink_port: parseInt(document.getElementById('cfg-mav-port').value) || 14550,
                qgc_target_ip: document.getElementById('cfg-qgc-ip').value.trim(),
                offline_gps_alert_sec: parseInt(document.getElementById('cfg-offline-sec').value) || 300,
                wifi_scan_delay_sec: Math.max(0, parseInt(document.getElementById('cfg-wifi-delay').value || '60')),
                wifi_scan_retry_sec: Math.max(10, parseInt(document.getElementById('cfg-wifi-retry').value || '60')),
                gps_max_speed_mps: parseFloat(document.getElementById('cfg-max-speed').value) || 35.0,
                allow_open_wifi: document.getElementById('cfg-open-wifi').checked
            };
            const res = await fetch('/api/config', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
            const d = await res.json();
            document.getElementById('config-result').innerText = d.message;
            updateStatus();
        }

        async function updateStatus() {
            try {
                const res = await fetch('/api/status');
                const d = await res.json();

                const banner = document.getElementById('lan-recovery-banner');
                banner.style.display = d.lan_recovery_waiting ? 'flex' : 'none';

                const modeEl = document.getElementById('current-mode');
                modeEl.innerText = d.current_mode === 'LAN' ? '🔌 КАБЕЛЬ (LAN eth0)' : '📡 РЕЗЕРВНИЙ WI-FI (wlan0)';
                modeEl.className = 'status-badge ' + (d.current_mode === 'LAN' ? 'active' : 'warn');

                const lanEl = document.getElementById('lan-status');
                lanEl.innerText = d.lan_internet ? '🟢 ПРИСУТНІЙ' : '🔴 ВІДСУТНІЙ';
                lanEl.className = 'status-badge ' + (d.lan_internet ? 'active' : 'inactive');

                const wlanEl = document.getElementById('wlan-status');
                wlanEl.innerText = d.wlan_internet ? '🟢 ПРИСУТНІЙ' : '🔴 ВІДСУТНІЙ';
                wlanEl.className = 'status-badge ' + (d.wlan_internet ? 'active' : 'inactive');

                document.getElementById('wifi-signal').innerText = d.wifi_signal;
                document.getElementById('ip-info').innerText = d.ips;

                document.getElementById('qgc-zt-addr').innerText = d.qgc_zt_address;
                document.getElementById('qgc-loc-addr').innerText = d.qgc_local_address;
                document.getElementById('mav-status').innerText = d.mavlink_status;

                const gpsBadge = document.getElementById('gps-badge');
                const spoofBanner = document.getElementById('spoof-banner');
                const spoofRow = document.getElementById('gps-spoof-row');
                if (d.gps) {
                    if (d.gps.spoofing_detected) {
                        gpsBadge.innerText = '🚨 ВИЯВЛЕНО СПУФІНГ!';
                        gpsBadge.className = 'status-badge inactive';
                        spoofBanner.style.display = 'block';
                        document.getElementById('spoof-banner-details').innerText =
                            `${d.gps.spoof_reason} | Спуфінг-координата: ${d.gps.spoof_coords_str}`;
                        spoofRow.style.display = 'block';
                        document.getElementById('gps-spoof-coords').innerText = d.gps.spoof_coords_str;
                    } else if (d.gps.has_fix) {
                        gpsBadge.innerText = `🟢 Норма (Супутників: ${d.gps.satellites})`;
                        gpsBadge.className = 'status-badge active';
                        spoofBanner.style.display = 'none';
                        spoofRow.style.display = 'none';
                    } else {
                        gpsBadge.innerText = '⏳ Очікування 3D Fix...';
                        gpsBadge.className = 'status-badge warn';
                        spoofBanner.style.display = 'none';
                        spoofRow.style.display = 'none';
                    }
                    document.getElementById('gps-valid-coords').innerText = d.gps.valid_coords_str || 'Немає фіксації';
                }

                document.getElementById('zt-node-id').innerText = d.zt.node_id;
                document.getElementById('zt-state').innerText = d.zt.state;
                document.getElementById('zt-state').className = 'status-badge ' + (d.zt.state === 'ONLINE' ? 'active' : 'warn');
                document.getElementById('zt-net-status').innerText = d.zt.net_status + (d.zt.net_id ? ` (${d.zt.net_id})` : '');
                document.getElementById('zt-net-status').className = 'status-badge ' + (d.zt.net_status === 'OK' ? 'active' : 'warn');
                document.getElementById('zt-ip').innerText = d.zt.ip;
            } catch (e) {}
        }

        async function switchToLan() {
            document.getElementById('action-msg').innerText = '⏳ Перевірка LAN та перемикання маршрутів...';
            const res = await fetch('/api/switch_lan', { method: 'POST' });
            const d = await res.json();
            document.getElementById('action-msg').innerText = d.message;
            updateStatus();
            loadLogs();
        }

        async function forceWifiFailover() {
            document.getElementById('action-msg').innerText = '⏳ Сканування та пошук робочої Wi-Fi мережі з інтернетом...';
            const res = await fetch('/api/smart_wifi', { method: 'POST' });
            const d = await res.json();
            document.getElementById('action-msg').innerText = d.message;
            updateStatus();
            loadLogs();
        }

        async function joinZeroTier() {
            const net_id = document.getElementById('zt-net-input').value.trim();
            if (!net_id) { alert('Введіть Network ID (16 hex-символів)!'); return; }
            document.getElementById('zt-msg').innerText = '⏳ Підключення до мережі ZeroTier...';
            const res = await fetch('/api/zerotier', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'join', net_id })
            });
            const d = await res.json();
            document.getElementById('zt-msg').innerText = d.message;
            updateStatus();
        }

        async function restartZeroTier() {
            document.getElementById('zt-msg').innerText = '⏳ Перезапуск служби zerotier-one...';
            const res = await fetch('/api/zerotier', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'restart' })
            });
            const d = await res.json();
            document.getElementById('zt-msg').innerText = d.message;
            updateStatus();
        }

        async function leaveZeroTier() {
            const net_id = document.getElementById('zt-net-input').value.trim();
            const res = await fetch('/api/zerotier', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'leave', net_id })
            });
            const d = await res.json();
            document.getElementById('zt-msg').innerText = d.message;
            updateStatus();
        }

        async function scanWifi() {
            const container = document.getElementById('wifi-container');
            container.innerHTML = '<p>⏳ Сканування Wi-Fi ефіру...</p>';
            try {
                const res = await fetch('/api/scan');
                const data = await res.json();
                if (!data.networks || data.networks.length === 0) {
                    container.innerHTML = '<p>Мереж не знайдено.</p>';
                } else {
                    let html = '<table><thead><tr><th>Статус</th><th>SSID</th><th>Сигнал</th><th>Захист</th><th>Пароль</th><th>Дія</th></tr></thead><tbody>';
                    data.networks.forEach((net, idx) => {
                        const isOpen = !net.security || net.security === '--' || net.security === '';
                        const savedBadge = net.is_saved ? ' <span class="status-badge info" style="font-size:10px;padding:2px 6px;">Збережена</span>' : '';
                        html += `<tr>
                            <td>${net.in_use ? '🟢 Активна' : '—'}</td>
                            <td><b>${net.ssid}</b>${savedBadge}</td>
                            <td>${net.signal}% (${net.bars})</td>
                            <td>${isOpen ? 'Відкрита' : net.security}</td>
                            <td>${isOpen ? '—' : `<input type="password" id="pass-${idx}" placeholder="${net.is_saved ? 'Збережено (або новий)' : 'Введіть пароль'}" style="width:150px;margin:0;">`}</td>
                            <td><button class="btn btn-primary btn-sm" onclick="connectWifi('${encodeURIComponent(net.ssid)}', ${isOpen}, ${net.is_saved}, 'pass-${idx}')">Підключитись</button></td>
                        </tr>`;
                    });
                    html += '</tbody></table>';
                    container.innerHTML = html;
                }
            } catch (e) { container.innerHTML = '<p>Помилка сканування.</p>'; }
        }

        async function connectWifi(ssidEnc, isOpen, isSaved, passInputId) {
            const ssid = decodeURIComponent(ssidEnc);
            const passEl = document.getElementById(passInputId);
            const password = passEl ? passEl.value : '';
            if (!isOpen && !isSaved && !password) {
                alert('Введіть пароль для підключення до захищеної мережі!');
                return;
            }
            document.getElementById('action-msg').innerText = `⏳ Підключення до Wi-Fi "${ssid}"...`;
            const res = await fetch('/api/connect', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ ssid, password })
            });
            const d = await res.json();
            document.getElementById('action-msg').innerText = d.message;
            updateStatus();
            scanWifi();
            loadSavedWifi();
            loadLogs();
        }

        async function loadSavedWifi() {
            const container = document.getElementById('saved-wifi-container');
            try {
                const res = await fetch('/api/saved_wifi');
                const d = await res.json();
                if (!d.saved || d.saved.length === 0) {
                    container.innerHTML = '<p style="color:#94a3b8;">Немає збережених Wi-Fi профілів.</p>';
                    return;
                }
                let html = '<table><thead><tr><th>Назва профілю (SSID)</th><th>Стан</th><th>Дії</th></tr></thead><tbody>';
                d.saved.forEach(item => {
                    html += `<tr>
                        <td><b>${item.name}</b></td>
                        <td>${item.active ? '<span class="status-badge active">Підключено</span>' : 'Збережено'}</td>
                        <td>
                            <button class="btn btn-success btn-sm" onclick="connectWifi('${encodeURIComponent(item.name)}', false, true, '')">Підключити</button>
                            <button class="btn btn-danger btn-sm" onclick="deleteSavedWifi('${item.uuid}', '${encodeURIComponent(item.name)}')">🗑 Видалити</button>
                        </td>
                    </tr>`;
                });
                html += '</tbody></table>';
                container.innerHTML = html;
            } catch (e) {}
        }

        async function deleteSavedWifi(uuid, nameEnc) {
            const name = decodeURIComponent(nameEnc);
            if (!confirm(`Видалити збережену мережу "${name}"?`)) return;
            const res = await fetch('/api/saved_wifi/delete', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ uuid, name })
            });
            const d = await res.json();
            document.getElementById('action-msg').innerText = d.message;
            loadSavedWifi();
            scanWifi();
        }

        async function loadLogs() {
            try {
                const res = await fetch('/api/logs');
                const d = await res.json();
                document.getElementById('logs').innerText = d.logs || "Записів немає.";
            } catch (e) {}
        }

        async function controlService(action) {
            await fetch('/api/control/' + action, { method: 'POST' });
            setTimeout(updateStatus, 1500);
        }

        loadConfigData();
        updateStatus();
        loadSavedWifi();
        loadLogs();
        setInterval(updateStatus, 4000);
        setInterval(loadLogs, 8000);
    </script>
</body>
</html>
"""

@app.route('/')
@requires_auth
def index():
    return render_template_string(HTML_TEMPLATE)

@app.route('/api/config', methods=['GET', 'POST'])
@requires_auth
def api_config():
    global config
    if request.method == 'POST':
        data = request.json or {}
        previous_mavlink_port = int(config.get("mavlink_port", 14550))
        config.update({
            "admin_user": data.get("admin_user", config["admin_user"]),
            "admin_pass": data.get("admin_pass", config["admin_pass"]),
            "telegram_token": data.get("telegram_token", config["telegram_token"]),
            "telegram_chat_id": data.get("telegram_chat_id", config["telegram_chat_id"]),
            "zerotier_net": data.get("zerotier_net", config["zerotier_net"]).strip(),
            "mavlink_port": int(data.get("mavlink_port", config.get("mavlink_port", 14550))),
            "qgc_target_ip": data.get("qgc_target_ip", config.get("qgc_target_ip", "")).strip(),
            "offline_gps_alert_sec": int(data.get("offline_gps_alert_sec", config.get("offline_gps_alert_sec", 300))),
            "wifi_scan_delay_sec": max(0, int(data.get("wifi_scan_delay_sec", config.get("wifi_scan_delay_sec", 60)))),
            "wifi_scan_retry_sec": max(10, int(data.get("wifi_scan_retry_sec", config.get("wifi_scan_retry_sec", 60)))),
            "gps_max_speed_mps": float(data.get("gps_max_speed_mps", config.get("gps_max_speed_mps", 35.0))),
            "allow_open_wifi": bool(data.get("allow_open_wifi", True))
        })
        save_config_file(config)
        if int(config.get("mavlink_port", 14550)) != previous_mavlink_port:
            run_cmd(["systemctl", "restart", "buddy-mavlink-router.service"], timeout=15)
        ensure_zerotier_connected(rebind=False)
        send_telegram_message(
            f"⚙️ Оновлено налаштування системи через веб-панель "
            f"(MAVLink UDP порт: {config['mavlink_port']}, таймер втрати інтернету: {config['offline_gps_alert_sec']} с, "
            f"затримка пошуку Wi-Fi: {config['wifi_scan_delay_sec']} с, повтор: {config['wifi_scan_retry_sec']} с)."
        )
        flush_telegram_queue_async()
        return jsonify({"success": True, "message": "✅ Налаштування збережено!"})

    return jsonify(config)

@app.route('/api/status')
@requires_auth
def api_status():
    ips = run_cmd("ip -4 -br addr show")
    routes = run_cmd("ip -4 route show default")
    zt = get_zerotier_details()
    lan_ip = get_iface_ip(LAN_IFACE)
    wlan_ip = get_iface_ip(WLAN_IFACE)
    mav_port = config.get("mavlink_port", 14550)

    with state_lock:
        mode = current_mode
        lan_net = lan_has_internet
        wlan_net = wlan_has_internet
        lan_wait = lan_recovery_waiting
        wifi_sig = wifi_signal_strength
        mav_txt = mavlink_status_text
        mav_cnt = mavlink_packets_count
        g = dict(gps_state)

    local_active_ip = wlan_ip if (mode == "WIFI" and wlan_ip != "Немає") else lan_ip
    qgc_zt = f"{zt['ip']}:{mav_port}" if zt["ip"] != "Немає" else "ZeroTier не підключено"
    qgc_loc = f"{local_active_ip}:{mav_port}" if local_active_ip != "Немає" else "Немає локального IP"

    valid_coords_str = "Немає фіксації"
    if g["valid_lat"] is not None and g["valid_lon"] is not None:
        valid_coords_str = f"{g['valid_lat']:.6f}, {g['valid_lon']:.6f} ({format_ts(g['valid_timestamp'])})"

    spoof_coords_str = "—"
    if g["spoof_lat"] is not None and g["spoof_lon"] is not None:
        spoof_coords_str = f"{g['spoof_lat']:.6f}, {g['spoof_lon']:.6f} ({format_ts(g['spoof_timestamp'])})"

    return jsonify({
        "current_mode": mode,
        "lan_internet": lan_net,
        "wlan_internet": wlan_net,
        "lan_recovery_waiting": lan_wait,
        "wifi_signal": wifi_sig,
        "ips": f"{ips}\n\n[Активні шлюзи]:\n{routes}",
        "zt": zt,
        "qgc_zt_address": qgc_zt,
        "qgc_local_address": qgc_loc,
        "mavlink_status": f"{mav_txt} | Пакетів через проксі: {mav_cnt}",
        "gps": {
            "has_fix": g["has_fix"],
            "satellites": g["satellites"],
            "spoofing_detected": g["spoofing_detected"],
            "spoof_reason": g["spoof_reason"],
            "valid_coords_str": valid_coords_str,
            "spoof_coords_str": spoof_coords_str
        }
    })

@app.route('/api/gps', methods=['GET', 'POST'])
@requires_auth
def api_gps():
    if request.method == 'POST':
        data = request.json or {}
        lat = data.get("lat")
        lon = data.get("lon")
        alt_m = float(data.get("alt_m", 0.0))
        fix_type = int(data.get("fix_type", 3))
        satellites = int(data.get("satellites", 0))
        speed_mps = float(data.get("speed_mps", 0.0))
        if lat is not None and lon is not None:
            update_gps_position(float(lat), float(lon), alt_m=alt_m, fix_type=fix_type, satellites=satellites, speed_mps=speed_mps)
            return jsonify({"success": True, "summary": build_gps_summary_text()})
        return jsonify({"success": False, "message": "Не вказано lat/lon"}), 400
    with state_lock:
        return jsonify(dict(gps_state))

@app.route('/api/switch_lan', methods=['POST'])
@requires_auth
def api_switch_lan():
    ok, msg = switch_to_lan_manual(source="Веб-панель")
    return jsonify({"success": ok, "message": msg})

@app.route('/api/smart_wifi', methods=['POST'])
@requires_auth
def api_smart_wifi():
    res_msg = auto_failover_routine(force_wifi=True)
    if "Connected" in res_msg:
        return jsonify({"success": True, "message": f"✅ {res_msg}"})
    elif "Already in progress" in res_msg:
        return jsonify({"success": False, "message": "⏳ Пошук вже виконується, зачекайте..."})
    return jsonify({"success": False, "message": f"❌ {res_msg}"})

@app.route('/api/scan')
@requires_auth
def api_scan():
    return jsonify({"networks": scan_all_wifi_networks()})

@app.route('/api/connect', methods=['POST'])
@requires_auth
def api_connect():
    global current_mode, wlan_has_internet
    data = request.json or {}
    ssid = data.get('ssid', '').strip()
    password = data.get('password', '').strip()
    if not ssid:
        return jsonify({"message": "SSID не вказано"}), 400

    ok, res = connect_to_wifi_network(ssid, password)
    if ok:
        time.sleep(2)
        has_inet = check_internet_wlan()
        with state_lock:
            current_mode = "WIFI"
            wlan_has_internet = has_inet
        ensure_zerotier_connected(rebind=True)
        zt = get_zerotier_details()
        wlan_ip = get_iface_ip(WLAN_IFACE)
        mav_port = config.get("mavlink_port", 14550)
        inet_str = "🟢 Інтернет ПРИСУТНІЙ" if has_inet else "⚠️ Інтернет ВІДСУТНІЙ"
        msg = (
            f"👤 Ручне підключення до Wi-Fi «{ssid}» виконано!\n"
            f"Статус: {inet_str}\n"
            f"📡 Wi-Fi IP: {wlan_ip}\n"
            f"🌐 ZeroTier IP: {zt['ip']} ({zt['state']})\n"
            f"🎯 QGroundControl UDP: {zt['ip'] if zt['ip'] != 'Немає' else wlan_ip}:{mav_port}"
        )
        send_telegram_message(msg)
        flush_telegram_queue_async()
        return jsonify({"message": f"✅ Підключено до '{ssid}' ({inet_str})"})
    return jsonify({"message": f"❌ Помилка підключення: {res}"})

@app.route('/api/saved_wifi')
@requires_auth
def api_saved_wifi():
    return jsonify({"saved": get_saved_wifi_connections()})

@app.route('/api/saved_wifi/delete', methods=['POST'])
@requires_auth
def api_delete_saved_wifi():
    data = request.json or {}
    uuid = data.get("uuid", "").strip()
    name = data.get("name", "").strip()
    if not uuid:
        return jsonify({"message": "❌ Не вказано UUID профілю"}), 400
    res = run_cmd(["nmcli", "connection", "delete", "uuid", uuid], timeout=10)
    send_telegram_message(f"🗑 Видалено збережений профіль Wi-Fi: {name}")
    flush_telegram_queue_async()
    return jsonify({"message": f"🗑 Профіль '{name}' видалено ({res})"})

@app.route('/api/zerotier', methods=['POST'])
@requires_auth
def api_zerotier():
    global config
    data = request.json or {}
    action = data.get("action")
    net_id = data.get("net_id", "").strip()

    if action == "restart":
        ensure_zerotier_connected(rebind=True)
        zt = get_zerotier_details()
        return jsonify({"message": f"🔄 Службу ZeroTier перезапущено! Стан: {zt['state']}, IP: {zt['ip']}"})

    if action == "join":
        if not re.fullmatch(r'[0-9a-fA-F]{16}', net_id):
            return jsonify({"message": "❌ Network ID має складатися рівно з 16 шістнадцяткових символів!"}), 400
        config["zerotier_net"] = net_id
        save_config_file(config)
        ensure_zerotier_connected(rebind=False)
        res = run_cmd(["zerotier-cli", "join", net_id], timeout=8)
        run_cmd(["zerotier-cli", "set", net_id, "allowManaged=1"], timeout=5)
        time.sleep(2)
        zt = get_zerotier_details()
        send_telegram_message(
            f"🌐 Підключення до ZeroTier мережі {net_id}: {res}\n"
            f"Стан: {zt['state']} ({zt['net_status']}) | ZT IP: {zt['ip']}"
        )
        flush_telegram_queue_async()
        return jsonify({"message": f"✅ Підключено ({res}). Статус: {zt['net_status']}, IP: {zt['ip']}"})

    elif action == "leave":
        target_net = net_id or config.get("zerotier_net", "").strip() or get_zerotier_details().get("net_id", "")
        if not target_net:
            return jsonify({"message": "❌ Не вказано Network ID для відключення"}), 400
        res = run_cmd(["zerotier-cli", "leave", target_net], timeout=8)
        if config.get("zerotier_net") == target_net:
            config["zerotier_net"] = ""
            save_config_file(config)
        send_telegram_message(f"🔌 Відключено від мережі ZeroTier {target_net}: {res}")
        flush_telegram_queue_async()
        return jsonify({"message": f"🔌 Відключено від {target_net}: {res}"})

    return jsonify({"message": "❌ Некоректний запит"}), 400

@app.route('/api/logs')
@requires_auth
def api_logs():
    try:
        with open("/opt/buddy/buddy.log", "r", encoding="utf-8") as f:
            lines = f.readlines()[-45:]
        return jsonify({"logs": "".join(lines)})
    except Exception:
        logs = run_cmd(["journalctl", "-u", "wifi-failover.service", "-n", "35", "--no-pager"])
        return jsonify({"logs": logs})

@app.route('/api/control/<action>', methods=['POST'])
@requires_auth
def api_control(action):
    if action in ['start', 'stop', 'restart']:
        send_telegram_message(f"🔄 Команда {action} для служби wifi-failover.service")
        flush_telegram_queue_async()
        run_cmd(["systemctl", action, "wifi-failover.service"])
        return jsonify({"status": "ok"})
    return jsonify({"status": "invalid action"}), 400

if __name__ == '__main__':
    threading.Thread(target=network_monitor_worker, daemon=True).start()
    threading.Thread(target=telegram_poller_worker, daemon=True).start()
    threading.Thread(target=mavlink_udp_proxy_worker, daemon=True).start()
    threading.Thread(target=gpsd_poller_worker, daemon=True).start()
    try:
        from waitress import serve
        logging.info("Запуск сервера Waitress на порту 8081...")
        serve(app, host='0.0.0.0', port=8081, threads=6)
    except ImportError:
        app.run(host='0.0.0.0', port=8081)
EOF

sed -i 's/\xc2\xa0/ /g' /opt/buddy/app.py
sed -i 's/\r$//' /opt/buddy/app.py

chmod +x /opt/buddy/app.py
touch /opt/buddy/buddy.log
chmod 600 /opt/buddy/buddy.log

echo "[+] Створення служби systemd..."
cat << 'EOF' > /etc/systemd/system/wifi-failover.service
[Unit]
Description=BUDDY NRK Wi-Fi Failover, GPS Anti-Spoof & MAVLink Service
After=network.target NetworkManager.service zerotier-one.service
Wants=zerotier-one.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/buddy
ExecStart=/usr/bin/python3 /opt/buddy/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wifi-failover.service
systemctl enable buddy-mavlink-router.service
systemctl restart wifi-failover.service
systemctl restart buddy-mavlink-router.service 2>/dev/null || true

LOCAL_IP=$(hostname -I | awk '{print $1}')
ZT_IP=$(ip -4 -br addr show 2>/dev/null | awk '/^zt/ {split($3,a,"/"); print a[1]; exit}')

echo "======================================================"
echo "[+] УСПІШНО! BUDDY NRK Failover v2.2 встановлено."
echo "------------------------------------------------------"
echo "🔗 Веб-панель (LAN):       http://${LOCAL_IP:-<IP>}:8081"
echo "🌐 Веб-панель (ZeroTier): http://${ZT_IP:-<ZeroTier_IP>}:8081"
echo "🎯 QGroundControl (UDP):  ${ZT_IP:-<ZeroTier_IP>}:14550"
echo "======================================================"
