#!/data/data/com.termux/files/usr/bin/bash
# Battery Guard for Wall Phone (24/7 plugged-in protection)
# Keeps battery level between 70% and 80% to protect the battery from swelling.

LOG="$HOME/battery-guard.log"
NODE="/sys/class/power_supply/battery/charging_enabled"
CAP_NODE="/sys/class/power_supply/battery/capacity"

termux-wake-lock
trap 'termux-wake-unlock; exit' INT TERM

echo "[$(date '+%Y-%m-%d %H:%M:%S')] battery-guard daemon started" >> "$LOG"

while true; do
  cap=$(su -c "cat $CAP_NODE" 2>/dev/null)
  state=$(su -c "cat $NODE" 2>/dev/null)

  if [ -n "$cap" ] && [ -n "$state" ]; then
    if [ "$cap" -ge 80 ] && [ "$state" -eq 1 ]; then
      su -c "echo 0 > $NODE"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Battery ${cap}% >= 80%: charging disabled" >> "$LOG"
    elif [ "$cap" -le 70 ] && [ "$state" -eq 0 ]; then
      su -c "echo 1 > $NODE"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Battery ${cap}% <= 70%: charging enabled" >> "$LOG"
    else
      # Periodic health log every check
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Battery ${cap}% (charging=${state})" >> "$LOG"
    fi
  fi

  sleep 120
done
