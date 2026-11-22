#!/data/data/com.termux/files/usr/bin/bash
export PATH="/data/data/com.termux/files/usr/bin:/system/bin:$PATH"
# Homelab Broadband & Power Outage Watchdog
# Monitors home Wi-Fi (wlan0) vs public internet.
# If Wi-Fi internet drops, alerts owner via BSNL cellular SMS.

OWNER_PHONE="7593980565"
LOG="/data/data/com.termux/files/home/watchdog.log"
STATE="up"
DOWN_SINCE=0
FAIL_COUNT=0

termux-wake-lock
trap "termux-wake-unlock; exit" INT TERM

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Watchdog started. Monitoring wlan0..." >> "$LOG"

while true; do
  # Ping public DNS via wlan0 specifically
  if su -c "/system/bin/ping -c 1 -W 3 -I wlan0 1.1.1.1 >/dev/null 2>&1"; then
    FAIL_COUNT=0
    if [ "$STATE" = "down" ]; then
      NOW=$(date +%s)
      DOWNTIME=$(( (NOW - DOWN_SINCE) / 60 ))
      MSG="✅ [Homelab Alert] Home Wi-Fi internet RESTORED at $(date +%H:%M)! Downtime: ${DOWNTIME}m."
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $MSG" >> "$LOG"
      termux-sms-send -n "$OWNER_PHONE" "$MSG" >/dev/null 2>&1 || true
      STATE="up"
    fi
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    # Require 2 consecutive failures (60s) to avoid transient jitter
    if [ $FAIL_COUNT -ge 2 ] && [ "$STATE" = "up" ]; then
      STATE="down"
      DOWN_SINCE=$(date +%s)
      
      # Determine if router or fiber is down
      if su -c "/system/bin/ping -c 1 -W 2 -I wlan0 192.168.1.1 >/dev/null 2>&1"; then
        REASON="Fiber / ISP disconnected (Router reachable)"
      else
        REASON="Router / Power lost (Gateway unreachable)"
      fi
      
      MSG="🚨 [Homelab Alert] Home Wi-Fi internet is DOWN at $(date +%H:%M)! $REASON. Wall phone monitoring over Cellular."
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $MSG" >> "$LOG"
      termux-sms-send -n "$OWNER_PHONE" "$MSG" >/dev/null 2>&1 || true
    fi
  fi
  sleep 30
done
