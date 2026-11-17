# Wall-phone plan (unbuilt)

A rooted Redmi Note 10 sticks to the wall and becomes a home assistant.
Not built yet — just captured here so we don't re-design it next session.

Decisions made:
- **Voice**: Google Assistant for v1 (cloud-ok). Keep Rhasspy as a later
  swap-in if we want to escape Google.
- **Hub**: Home Assistant Core (Python venv install, no Docker,
  stripped-down config) on `.230`.
- **Intercom**: WhatsApp voice note → wabot → MQTT → phone auto-plays.
  Reuses our existing WhatsApp pipeline instead of adding Mumble/Zello.
- **CCTV**: IP Webcam Android app → HA ingests the MJPEG stream.

Keep the RAM budget tight. Everything cross-cutting talks over MQTT;
wabot does the heavy lift in Go (not HA automations).

## Target architecture

```
          WhatsApp voice note (from office/anywhere)
                        │
                        ▼
   ┌─── wabot on .230 (existing + new intercom module) ───┐
   │  * detects voice note from OWNER                     │
   │  * downloads via whatsmeow MediaDownload             │
   │  * saves audio/<uuid>.opus, HTTP-serves on :8766     │
   │  * publishes { "url": "..." } to mqtt intercom/play  │
   │  * TTL-cleans files after 10 minutes                 │
   └──────────────────────────────────────────────────────┘
                        │ MQTT
                        ▼
   ┌─── Redmi Note 10 on the wall ─────────────────┐
   │  Tasker: MQTT sub intercom/play → GET → play  │
   │  IP Webcam: MJPEG stream on :8080             │
   │  Fully Kiosk Browser: HA dashboard fullscreen │
   │  Google Assistant: "open YouTube", alarms     │
   │  Tasker + AutoVoice: custom intents           │
   └───────────────────────────────────────────────┘
                        ▲
                        │ HA Companion app on personal phones
                        │ Camera card + state visible remotely
   ┌─── HA Core on .230 (~130 MB, trimmed) ───┐
   │  mjpeg camera (from wall-phone IP Webcam)│
   │  mobile_app notifications                │
   │  mqtt bus                                │
   │  rest sensor → wifi-presence /api/status │
   │  Minimal Lovelace: camera, who's home    │
   └──────────────────────────────────────────┘
```

## Memory budget

Current server usage: wabot ~22 MB, wifi-presence ~14 MB, AdGuard ~40 MB,
Tailscale ~25 MB, Mongo ~55 MB. Free: ~59 MB of ~4 GB with buffers.

Adding:
- Mosquitto: ~3 MB
- HA Core stripped: ~130 MB (vs ~380 MB vanilla)
- wabot intercom code: ~5 MB (same process)

Total extra: ~138 MB. Fits with swap. **Add a 2 GB swapfile before
installing HA.** `/etc/fstab` entry for persistence.

## RAM savings that actually matter

In HA's `configuration.yaml`:
- **No `default_config:`.** Explicit opt-ins only. Below.
- **Trim recorder.** `purge_keep_days: 2`, `commit_interval: 30`,
  exclude `sensor` / `updater` / `sun` / anything chatty.
- **Disable Analytics / Cloud / Updater.**
- No HACS, no themes, no custom-cards.
- Write automations as Go programs talking to MQTT, not as HA scripts.
  A Go daemon that does a `mqtt_publish` on condition X is ~5 MB; the
  same logic as an HA automation loads the whole blueprint subsystem.

Starter `configuration.yaml`:
```yaml
homeassistant:
  time_zone: Asia/Kolkata
  unit_system: metric
http:
  server_port: 8123
  cors_allowed_origins:
    - http://192.168.1.230:8123
frontend:
mobile_app:
mqtt:
  broker: 127.0.0.1
  username: ha
  password: !secret mqtt_password
camera:
  - platform: mjpeg
    name: Wall phone
    mjpeg_url: http://192.168.1.X:8080/video
    still_image_url: http://192.168.1.X:8080/shot.jpg
rest:
  - resource: http://127.0.0.1:8765/api/status
    scan_interval: 60
    sensor:
      - name: "Home count"
        value_template: "{{ value_json.counts.home }}"
recorder:
  purge_keep_days: 2
  commit_interval: 30
  exclude:
    domains: [sensor, updater, sun]
```

## Build sequence (in the order it should happen)

### Phase 0 — prep the phone (physical, 30 min)

1. Magnetic wall mount + 90° USB-C cable (keeps the phone flat, cable
   routed down the wall). Phone must be plugged in permanently — camera
   + Wi-Fi + screen-on will drain a battery in a few hours.
2. **Settings:** disable all gesture nav, enable "Stay awake while
   charging" in Developer Options, Battery → "No restriction" for
   Tasker / IP Webcam / Chrome / Fully Kiosk.
3. **Install:**
   - Fully Kiosk Browser (~₹900 lifetime). The wall-mount dashboard.
   - IP Webcam (free). RTSP/MJPEG server.
   - Tasker (~₹300). The automation brain.
   - AutoVoice (~₹200). Voice command triggers for Tasker.
   - MQTT Client built into Tasker 6.3+ — no separate app needed.
4. **Give Tasker root.** Unlocks screen-on, volume force, keep-alive.

Total hardware/software spend: ~₹2000 upfront.

### Phase 1 — MQTT on `.230` (15 min)

```sh
sudo apt install -y mosquitto mosquitto-clients
sudo mosquitto_passwd -c /etc/mosquitto/passwd wabot
sudo mosquitto_passwd    /etc/mosquitto/passwd wallphone
sudo mosquitto_passwd    /etc/mosquitto/passwd ha

cat <<'EOF' | sudo tee /etc/mosquitto/conf.d/auth.conf
listener 1883 0.0.0.0
allow_anonymous false
password_file /etc/mosquitto/passwd
EOF
sudo systemctl enable --now mosquitto
```

Smoke test: `mosquitto_sub -u wallphone -P … -t 'test/#'` on phone side
while `mosquitto_pub -u wabot -P … -t 'test/x' -m 'hi'` on server side.

### Phase 2 — wabot intercom bridge (~150 lines of Go)

New file `internal/intercom/intercom.go`:
- Tiny HTTP server on `127.0.0.1:8766` that serves cached audio by UUID
  with a 10-minute TTL cleanup goroutine.
- MQTT client (`eclipse/paho.mqtt.golang`) that publishes URL + duration
  to `intercom/play` on receipt.

Hook into the message handler in `internal/router/router.go`:
- When `env.Msg.GetAudioMessage() != nil` **and** `env.IsOwner` **and**
  (caption is empty OR `!say`), run the pipeline. Else fall through to
  existing handlers.

New `.env` vars:
```
INTERCOM_ENABLED=on
INTERCOM_PUBLIC_URL=http://192.168.1.230:8766
MQTT_BROKER=tcp://127.0.0.1:1883
MQTT_USER=wabot
MQTT_PASSWORD=...
```

### Phase 3 — Tasker on the phone (~20 min)

Profile: **MQTT Subscription → `intercom/play`** (QoS 1).

Task on message:
1. `Variables → Variable Set %url = %mqtt_message` (JSON parse → `.url`).
2. `Net → HTTP Request GET %url → /sdcard/intercom/%TIMES.opus`.
3. `Media → Media Volume = 10` (force audible).
4. `Media → Media Play /sdcard/intercom/%TIMES.opus`.
5. `Task → Wait Until → %MEDIASTATUS ≠ Playing` (or fixed wait).
6. `File → Delete /sdcard/intercom/%TIMES.opus`.

Also add voice profiles (AutoVoice):
- "manorama" → launch browser to the live URL, or Deep Link to the
  YouTube app with channel ID.
- "cctv" → Open HA dashboard → camera view.
- Google Assistant handles "open youtube", alarms, reminders natively.

### Phase 4 — HA Core on `.230` (~90 min)

```sh
sudo apt install -y python3-dev python3-venv libffi-dev libssl-dev \
  libjpeg-dev zlib1g-dev autoconf build-essential libopenjp2-7 \
  libturbojpeg0-dev tzdata ffmpeg

sudo useradd -rm homeassistant -G dialout,gpio,i2c
sudo mkdir /srv/homeassistant
sudo chown homeassistant:homeassistant /srv/homeassistant
sudo -u homeassistant -H bash
cd /srv/homeassistant
python3 -m venv .
source bin/activate
pip install wheel
pip install homeassistant
hass    # first run creates ~/.homeassistant/
```

User systemd unit at `~homeassistant/.config/systemd/user/home-assistant.service`
(or system-wide at `/etc/systemd/system/home-assistant@homeassistant.service`
with `linger` enabled):
```
[Unit]
Description=Home Assistant
After=network-online.target

[Service]
Type=simple
User=homeassistant
WorkingDirectory=/srv/homeassistant
ExecStart=/srv/homeassistant/bin/hass -c /home/homeassistant/.homeassistant
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

First boot takes ~2 minutes (wheel caching). After that, ~30 s warm boot.

Then `configuration.yaml` as above. HA UI at `http://192.168.1.230:8123`,
Fully Kiosk on the wall points there.

### Phase 5 — polish

- "Who's home" dashboard card via `rest:` sensor → wifi-presence
  `/api/status`. Shows `Siru-s-A13`, `moto-g57-power`, etc. by hostname.
- Office-side intercom: a tiny PWA that records 10 s audio and POSTs it
  to wabot's HTTP API (owner token), reusing the same MQTT pipeline but
  skipping WhatsApp. Faster than typing.
- Night routine: at 23:00, Fully Kiosk dims screen; alarms in Google
  Assistant light up the display at wake time.
- Use Tasker's `Autosync` to pull calendar events / reminders into
  spoken announcements.

## Risks / open questions

- **Battery health on perma-charge.** Modern phones throttle charging
  at ~80% to protect the battery. Redmi Note 10's firmware should
  handle this; monitor for swelling if it's charging 24/7.
- **IP Webcam audio.** Enabling audio streaming doubles the stream
  cost. Keep CCTV video-only unless we need two-way.
- **WhatsApp voice-note auto-play UX.** If the owner sends 10 voice
  notes in a minute, the phone may queue them awkwardly. Add a simple
  rate-limit in the intercom module (max 1 playing at a time; replace
  old if new within 10 s).
- **Google Assistant on rooted phone.** Some rooted builds flag Play
  Protect and Assistant refuses to listen. Test early; worst case, we
  swap to Rhasspy.

## Not doing in v1

- Two-way intercom (would need a Mumble server + always-on mic).
- Face recognition / person detection (Frigate wants a lot more RAM +
  ideally a Coral TPU).
- Local-only STT (Rhasspy deferred).
- Voice reply from the wall-phone (just display + play, don't listen
  for commands at the wall — use Google Assistant's own listener).
