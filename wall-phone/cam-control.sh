#!/data/data/com.termux/files/usr/bin/bash
BROKER=192.168.1.230
USER=wallphone
PASSWORD=siraju24@
TOPIC=cctv/control
CAM_PKG=com.pas.webcam

termux-wake-lock
trap 'termux-wake-unlock; exit' INT TERM

while true; do
  mosquitto_sub -h "$BROKER" -u "$USER" -P "$PASSWORD" -t "$TOPIC" 2>&1 \
  | while read -r line; do
      action=$(echo "$line" | jq -r '.action' 2>/dev/null)
      case "$action" in
        start) su -c "am start -n $CAM_PKG/.Rolling && sleep 0.2 && am start -n xyz.wallpanel.app/.ui.activities.BrowserActivityNative" >/dev/null 2>&1 ;;
        stop)  su -c "am force-stop $CAM_PKG && am start -n xyz.wallpanel.app/.ui.activities.BrowserActivityNative" >/dev/null 2>&1 ;;
      esac
    done
  sleep 5
done
