#!/data/data/com.termux/files/usr/bin/bash
export PATH="/data/data/com.termux/files/usr/bin:/system/bin:$PATH"

BROKER=192.168.1.230
USER=wallphone
PASSWORD=siraju24@
TOPIC_CCTV=cctv/control
TOPIC_PHONE=wallphone/control
CAM_PKG=com.pas.webcam

termux-wake-lock
trap 'termux-wake-unlock; exit' INT TERM

while true; do
  mosquitto_sub -h "$BROKER" -u "$USER" -P "$PASSWORD" -t "$TOPIC_CCTV" -t "$TOPIC_PHONE" 2>&1 \
  | while read -r line; do
      action=$(echo "$line" | jq -r '.action' 2>/dev/null)
      case "$action" in
        live)
          # Only start IP Webcam when live stream is explicitly requested
          su -c "am start -n $CAM_PKG/.Rolling && sleep 0.2 && am start -n xyz.wallpanel.app/.ui.activities.BrowserActivityNative" >/dev/null 2>&1
          ;;
        stop)
          su -c "am force-stop $CAM_PKG" >/dev/null 2>&1
          ;;
        start)
          # Silent background snapshots are handled by bgcam on port 8088.
          # Zero UI disruption on screen.
          ;;
        gemini|assistant)
          # Open Gemini Voice Assistant Floaty overlay
          su -c "input keyevent 231" >/dev/null 2>&1
          ;;
        gemini_app)
          # Launch full Gemini app
          su -c "am start -n com.google.android.apps.bard/.shellapp.BardEntryPointActivity" >/dev/null 2>&1
          ;;
        wallpanel|dismiss)
          # Return to WallPanel
          su -c "input keyevent 4 || am start -n xyz.wallpanel.app/.ui.activities.BrowserActivityNative" >/dev/null 2>&1
          ;;
      esac
    done
  sleep 5
done
