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
        start|cctv_start)
          # Start IP Webcam with launch wait, then immediately restore WallPanel to foreground
          su -c "am start -W -n $CAM_PKG/.Rolling --activity-no-animation && am start -n xyz.wallpanel.app/.ui.activities.BrowserActivityNative --activity-no-animation" >/dev/null 2>&1
          ;;
        stop|cctv_stop)
          su -c "am force-stop $CAM_PKG && am start -n xyz.wallpanel.app/.ui.activities.BrowserActivityNative --activity-no-animation" >/dev/null 2>&1
          ;;
        gemini|assistant)
          # Open Gemini Voice Assistant Floaty overlay
          su -c "input keyevent 231" >/dev/null 2>&1
          ;;
        gemini_live)
          # Open Gemini Floaty and tap Gemini Live button
          su -c "input keyevent 231 && sleep 0.3 && input tap 860 2202" >/dev/null 2>&1
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
