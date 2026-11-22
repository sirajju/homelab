#!/data/data/com.termux/files/usr/bin/bash
export HOME="/data/data/com.termux/files/home"
export PATH="/data/data/com.termux/files/usr/bin:/system/bin:$PATH"
BROKER=192.168.1.230
USER=wallphone
PASSWORD=siraju24@
TOPIC=intercom/play

termux-wake-lock
trap 'termux-wake-unlock; exit' INT TERM

while true; do
  mosquitto_sub -h "$BROKER" -u "$USER" -P "$PASSWORD" -t "$TOPIC" 2>&1 \
  | while read -r line; do
      speak=$(echo "$line" | jq -r '.speak // .text // empty' 2>/dev/null)
      if [ -n "$speak" ]; then
        echo "[$(date +%H:%M:%S)] speaking: $speak"
        termux-volume music 15 >/dev/null 2>&1 || true
        termux-tts-speak "$speak"
        continue
      fi

      url=$(echo "$line" | jq -r '.url' 2>/dev/null)
      if [ -z "$url" ] || [ "$url" = "null" ]; then
        echo "[$(date +%H:%M:%S)] skip: $line" >&2
        continue
      fi
      f="$HOME/clip-$(date +%s).ogg"
      echo "[$(date +%H:%M:%S)] playing $url"
      if curl -k -s --max-time 15 --resolve "sirajju.tail7dc29c.ts.net:8766:192.168.1.230" -o "$f" "$url"; then
        termux-volume music 15 >/dev/null 2>&1 || true
        termux-media-player play "$f"
        secs=$(echo "$line" | jq -r '.seconds // 10' 2>/dev/null)
        [ -z "$secs" ] && secs=10
        sleep "$((secs + 2))"
        rm -f "$f"
      else
        echo "download failed" >&2
      fi
    done
  echo "[$(date +%H:%M:%S)] mosquitto_sub exited, reconnect in 5s" >&2
  sleep 5
done
