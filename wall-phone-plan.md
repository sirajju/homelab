# Wall-phone plan

A rooted Redmi Note 10 (crDroid) sticks to the wall and becomes a home
assistant.

**Progress:** Phases 1 + 2 + 3 + 4 + 5 done. Intercom (voice note from
anywhere → wall-phone speaker), on-demand CCTV (`!cctv` → snapshot,
`!cctv on N` → MJPEG for N seconds) and HA Core on `.230` (Home + Admin
dashboards, arrival/departure Companion push, system-health card on
Admin) all live. **Remaining:** the wall-phone kiosk front-end —
Fully Kiosk ruled out because of license + HA chrome leaking through;
leaning toward a static HTML page served from HA's `www/`. See 4.12.

Instead of Tasker + an MQTT plugin (the free Play Store landscape was
grim and the user wasn't buying a paywalled plugin for day one), we
ended up using **Termux + mosquitto_sub** as the subscriber. Zero cost,
more flexible, works headless at boot.

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

### Phase 1 — MQTT on `.230` ✅ DONE 2026-11-17

```sh
sudo apt install -y mosquitto mosquitto-clients
sudo mosquitto_passwd -c /etc/mosquitto/passwd wabot
sudo mosquitto_passwd    /etc/mosquitto/passwd wallphone
sudo mosquitto_passwd    /etc/mosquitto/passwd ha

# MUST own the passwd file as the mosquitto service user, otherwise
# mosquitto crashes with status 13 on start. `mosquitto_passwd -c` under
# sudo creates it as root:root 600 — the service user can't read that.
sudo chown mosquitto:mosquitto /etc/mosquitto/passwd
sudo chmod 640 /etc/mosquitto/passwd
sudo chown mosquitto:mosquitto /var/log/mosquitto  # fixes "unable to open log file" warning

cat <<'EOF' | sudo tee /etc/mosquitto/conf.d/auth.conf
listener 1883 0.0.0.0
allow_anonymous false
password_file /etc/mosquitto/passwd
EOF
sudo systemctl enable --now mosquitto
```

Smoke-tested from .230: `mosquitto_sub -h 127.0.0.1 -u wabot -P <pw>
-t 'intercom/#' -v` picks up the JSON when a voice note is forwarded.

Gotchas captured so we don't repeat them:
- **`exit-code 13 / Unable to open pwfile`** = passwd not readable by
  the `mosquitto` service user. See the chown line above.
- **`exit-code 13 / Start request repeated too quickly`** = systemd
  backoff after N failed starts. Run
  `sudo systemctl reset-failed mosquitto` before trying again.
- Current listener is bound to `0.0.0.0:1883`. The wall phone can reach
  it directly on the LAN.

### Phase 2 — wabot intercom bridge ✅ DONE 2026-11-17

Commits `b74b1e5` + `588afb8` on `main` of
[sirajju/whatsapp-bot-with-ai](https://github.com/sirajju/whatsapp-bot-with-ai).

New package `internal/intercom/intercom.go`:
- HTTP server on `0.0.0.0:8766` (LAN-reachable) serves cached audio by
  UUID. Served only when the UUID is in the in-memory registered map,
  not as a generic file server.
- MQTT client (`eclipse/paho.mqtt.golang` v1.5.1) publishes
  `{"url":...,"seconds":...,"sender":...,"id":...,"ts":...}` to
  `intercom/play` with QoS 1 on receipt.
- TTL janitor deletes cached files + removes entries from the map every
  5 min (half the default TTL of 10 min).
- On delivery, reacts 📣 to the WhatsApp message so the owner sees
  acknowledgement without a reply.

Router change in `internal/router/router.go`: Dispatch previously
bailed on empty text, so media-only messages never reached any hook.
Moved the `text == ""` check after the hook loop so passive media hooks
can run.

`.env` on `.230`:
```
INTERCOM_ENABLED=on
INTERCOM_MQTT_BROKER=tcp://127.0.0.1:1883   # wabot is same-host; phone uses .230:1883
INTERCOM_MQTT_USER=wabot
INTERCOM_MQTT_PASSWORD=<secret, in .env only>
INTERCOM_MQTT_TOPIC=intercom/play
INTERCOM_HTTP_LISTEN=0.0.0.0:8766
INTERCOM_PUBLIC_URL=http://192.168.1.230:8766
INTERCOM_CACHE_DIR=/tmp/wabot-intercom
```

Owner gate: identical to router.buildEnv's — both `Sender.User` and
`SenderAlt.User` are checked. Group messages are ignored on purpose;
this is a 1:1 pipe.

Verification run 2026-11-17T15:59:54:
- Voice note from owner 917593980565.
- Downloaded 4310 bytes, 1 sec.
- Cached at `/tmp/wabot-intercom/d09f926da805e467.opus`.
- HTTP `GET http://192.168.1.230:8766/audio/d09f926da805e467.opus`
  returns 200, Content-Type `audio/ogg`.
- MQTT JSON published to `intercom/play`.

Gotcha captured: the intercom cache dir default collided with my
staging scp target. Fixed in `588afb8` — default is now
`/tmp/wabot/intercom`. Deployments that already set
`INTERCOM_CACHE_DIR` are unaffected.

### Phase 3 — subscriber on the phone ✅ DONE 2026-11-18

Uses **Termux + mosquitto_sub + termux-media-player** instead of
Tasker. Lives at `~/intercom.sh` on the phone, auto-starts from
`~/.termux/boot/intercom`.

Install, phone-side (SSH in from the laptop after `pkg install
openssh && passwd && sshd` to make all of this paste-able):

```sh
pkg install -y mosquitto jq curl termux-api termux-services which
```

The script (`~/intercom.sh`):

```bash
#!/data/data/com.termux/files/usr/bin/bash
BROKER=192.168.1.230
USER=wallphone
PASSWORD=<set-via-sed>
TOPIC=intercom/play

termux-wake-lock
trap 'termux-wake-unlock; exit' INT TERM

while true; do
  mosquitto_sub -h "$BROKER" -u "$USER" -P "$PASSWORD" -t "$TOPIC" 2>&1 \
  | while read -r line; do
      url=$(echo "$line" | jq -r '.url' 2>/dev/null)
      [ -z "$url" ] || [ "$url" = "null" ] && continue
      f="$HOME/clip-$(date +%s).opus"
      echo "[$(date +%H:%M:%S)] playing $url"
      if curl -s --max-time 15 -o "$f" "$url"; then
        termux-media-player play "$f"
        sleep "$(($(echo "$line" | jq -r '.seconds // 10') + 3))"
        rm -f "$f"
      fi
    done
  sleep 5  # reconnect loop
done
```

Boot hook (`~/.termux/boot/intercom`):

```bash
#!/data/data/com.termux/files/usr/bin/bash
# Keep Termux's foreground service alive post-boot.
termux-wake-lock
# Give Termux:API's background service time to initialize after boot.
sleep 15
# Prime the IPC bridge so the first media-player call doesn't hang.
termux-volume music >/dev/null 2>&1 || true
# Start intercom. Log goes to $HOME, not /sdcard — /sdcard isn't writable
# until termux-setup-storage runs AND the permission is granted.
exec ~/intercom.sh > ~/intercom.log 2>&1
```

The `sleep 15` + `termux-volume` warm-up is load-bearing. Without it the
boot hook fires and `intercom.sh` runs, but `termux-media-player` hangs
silently on the first few voice notes because the Termux:API background
IPC bridge isn't warm yet. Symptom was "works after you open Termux
manually" — opening the main app woke the bridge.

Gotchas captured so we don't repeat them:

- **Termux package is `mosquitto`**, not `mosquitto-clients`. The
  Debian-style split doesn't exist here.
- **Termux has no `which` by default.** `pkg install which` or just
  use `command -v`.
- **Termux cannot write to `/tmp`** — the sandbox excludes it. Use
  `$HOME` or `$TMPDIR` (`/data/data/com.termux/files/usr/tmp`).
- **Termux-API CLI tools hang silently** if the Termux:API **APK** isn't
  installed or hasn't been opened once from the launcher. The CLI pkg
  (`termux-api`) only installs wrappers; the APK is a separate F-Droid
  install and must be launched manually once so Android registers its
  IPC. Same for Termux:Boot — the boot script won't fire without the
  APK installed and opened.
- **`termux-volume` with no args reads** the current levels and prints
  JSON. `termux-volume music 12` writes. We got confused when the read
  form appeared to "hang" — turns out the Termux:API APK wasn't
  installed; `termux-media-player` was silently hanging for the same
  reason.
- **Don't swallow stderr** with `>/dev/null 2>&1` during dev — the
  initial intercom.sh had this and errors from `termux-media-player`
  (the APK-missing ones) were invisible. Keep it visible until you've
  seen a successful playback at least once.
- **Termux:Boot fires its receiver but the script "doesn't work" on
  the first voice note after reboot** = Termux:API IPC bridge cold.
  Solved by the `sleep 15 && termux-volume music >/dev/null` warm-up
  at the top of the boot hook (above). Without that step the boot
  script runs, Termux:Boot is doing its job correctly, but every
  Termux:API-dependent call (`termux-media-player`, `termux-volume`,
  `termux-notification`) hangs until the main Termux process is
  opened manually.
- **`cmd deviceidle whitelist +…` and `am broadcast` via `su -c` fail
  on crDroid with KernelSU** with "Failed transaction (2147483646)"
  — it's a KernelSU IPC quirk. Not a problem: real `BOOT_COMPLETED`
  delivery goes through init, not `am`, so Termux:Boot still fires
  at real boot even though we can't fake-broadcast for testing.
  Debug by restarting the boot hook directly (`~/.termux/boot/intercom`)
  instead of simulating a boot.

Other voice triggers (not done, can be added later):
- "manorama" → launch browser to the live URL.
- "cctv" → HA dashboard → camera view.
- Google Assistant already handles "open youtube", alarms, reminders.

### Phase 5 — On-demand CCTV ✅ DONE 2026-11-18

User asked for the camera **not** to run idle. The flow now: `!cctv`
tells the phone to start IP Webcam, polls until it responds, grabs a
snapshot, tells the phone to stop IP Webcam. Shares the same MQTT
broker as intercom; no second connection.

Phone side (`~/cam-control.sh`):

```bash
#!/data/data/com.termux/files/usr/bin/bash
BROKER=192.168.1.230
USER=wallphone
PASSWORD=<same as intercom>
TOPIC=cctv/control
CAM_PKG=com.pas.webcam

termux-wake-lock
trap 'termux-wake-unlock; exit' INT TERM

while true; do
  mosquitto_sub -h "$BROKER" -u "$USER" -P "$PASSWORD" -t "$TOPIC" 2>&1 \
  | while read -r line; do
      action=$(echo "$line" | jq -r '.action' 2>/dev/null)
      case "$action" in
        start) su -c "am start -n $CAM_PKG/.Rolling" >/dev/null 2>&1 ;;
        stop)  su -c "am force-stop $CAM_PKG" >/dev/null 2>&1 ;;
      esac
    done
  sleep 5
done
```

Boot hook (`~/.termux/boot/02-cam-control`):

```bash
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock
sleep 15
exec ~/cam-control.sh > ~/cam-control.log 2>&1
```

Server side: wabot exposes a `Bridge.Publish(topic, payload)` method on
the intercom module so the `!cctv` command can reuse the broker
connection. `internal/commands/cctv.go` publishes `{"action":"start"}`,
HEAD-polls `CCTV_URL` every 500ms until it returns 2xx (or
`CCTV_START_TIMEOUT` elapses, default 20s), grabs the snapshot, uploads
it via whatsmeow's image-upload helper, then publishes
`{"action":"stop"}`.

New env on `.230`:

```
CCTV_URL=http://192.168.1.231:8080/shot.jpg
CCTV_USER=...
CCTV_PASSWORD=...
CCTV_TIMEOUT=15s
CCTV_CONTROL_TOPIC=cctv/control
CCTV_START_TIMEOUT=20s
CCTV_AUTO_STOP=on
```

The old `~/.termux/boot/00-cctv` (start IP Webcam at boot) was deleted;
with on-demand control it's counter-productive. The phone boots cold
and only wakes the camera when `!cctv` arrives.

### Phase 4 — HA Core on `.230` ✅ DONE 2026-11-21

**Purpose:** a dashboard the wall phone can display full-screen, Mobile
Companion push notifications to your personal phone (from anywhere, via
Google FCM — doesn't depend on HA being internet-reachable), and a
growing integration ecosystem to expand into later.

**Prerequisites verified:** `.230` has 3.4 GB RAM / 2.8 GB available /
3.7 GB swap configured / 43 GB free disk / Python 3.14.4. **The earlier
"server has only 59 MB free" note in memory was wrong — that was the
*router*'s 58 MB of RAM, not the server.**

Python 3.14 isn't officially targeted by HA Core (they target 3.12/3.13)
but 2026.11.2 installed clean on 2026-11-21 with no wheel issues. If a
future HA release breaks on 3.14, install Python 3.13 via deadsnakes
PPA and point the venv at it.

#### 4.1 Install HA Core (root required)

```sh
# 1. System prereqs
sudo apt update
sudo apt install -y \
  python3-dev python3-venv python3-pip \
  libffi-dev libssl-dev libjpeg-dev zlib1g-dev \
  autoconf build-essential libopenjp2-7 libturbojpeg0-dev \
  tzdata ffmpeg

# 2. Service user — note -d sets HOME to /srv/homeassistant
sudo useradd -rm -d /srv/homeassistant -s /bin/bash homeassistant
sudo mkdir -p /srv/homeassistant
sudo chown homeassistant:homeassistant /srv/homeassistant

# 3. Venv + pip install homeassistant (3–5 min; builds wheels)
sudo -u homeassistant -H bash -c '
  cd /srv/homeassistant
  python3 -m venv .
  source bin/activate
  pip install --upgrade pip wheel
  pip install homeassistant
'

# 4. Sanity check
sudo -u homeassistant -H /srv/homeassistant/bin/hass --version
```

#### 4.2 Generate the config dir

```sh
sudo -u homeassistant -H /srv/homeassistant/bin/hass \
  --script ensure_config -c /srv/homeassistant/.homeassistant
```

**Gotcha:** the config dir is `/srv/homeassistant/.homeassistant`, NOT
`/home/homeassistant/.homeassistant`. `useradd -d /srv/homeassistant`
set HOME under `/srv/`; if you pass the `/home/...` path to
`ensure_config` it tries to mkdir inside `/home/` which the
homeassistant user can't write to.

#### 4.3 `configuration.yaml` at `/srv/homeassistant/.homeassistant/configuration.yaml`

```yaml
homeassistant:
  name: Home
  time_zone: Asia/Kolkata
  unit_system: metric
  internal_url: http://192.168.1.230:8123
  external_url: http://100.99.232.45:8123

default_config:

http:
  server_port: 8123
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - 100.64.0.0/10   # Tailscale tailnet range

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

rest:
  - resource: http://127.0.0.1:8765/api/status
    scan_interval: 60
    sensor:
      - name: "Home Count"
        value_template: "{{ value_json.counts.home }}"
      - name: "Away Count"
        value_template: "{{ value_json.counts.away }}"

recorder:
  purge_keep_days: 2
  commit_interval: 30
  exclude:
    domains: [updater, sun]
```

Touch the include files so HA doesn't nag:

```sh
sudo -u homeassistant touch /srv/homeassistant/.homeassistant/automations.yaml
sudo -u homeassistant touch /srv/homeassistant/.homeassistant/scripts.yaml
sudo -u homeassistant touch /srv/homeassistant/.homeassistant/scenes.yaml
```

**Gotcha — you cannot edit URLs via the UI once YAML has a `homeassistant:`
key.** Error: *"You cannot change these settings in the UI, as you have
config stored in configuration.yaml under the homeassistant key."*
Edit the YAML directly and restart.

**Gotcha — `hass --script check_config` fails from sudo -S.** uv (pip's
successor) tries to write to `$HOME/uv.toml`, which inherits the
*caller's* HOME under `sudo -S`, not homeassistant's. Error is
cosmetic — the live service works fine because systemd sets `HOME=`
via `User=`. Just don't rely on `check_config` as a pre-start gate.

#### 4.4 Systemd unit at `/etc/systemd/system/home-assistant.service`

```ini
[Unit]
Description=Home Assistant
After=network-online.target

[Service]
Type=simple
User=homeassistant
WorkingDirectory=/srv/homeassistant/.homeassistant
ExecStart=/srv/homeassistant/bin/hass -c /srv/homeassistant/.homeassistant
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now home-assistant
```

First boot takes ~60–120 seconds. `systemctl is-active home-assistant`
→ `active` when ready. `ss -tlnp | grep 8123` shows `0.0.0.0:8123` and
`[::]:8123`.

#### 4.5 Onboarding (browser)

- Open **http://192.168.1.230:8123** (laptop, same LAN).
- Create admin account (this is HA's account, separate from `.230`'s
  Linux login).
- Set location (or skip; Met.no needs coords, we add that later).
- Device discovery — skip whatever you don't recognise.
- Land on **Overview** dashboard.
- **Turn on Advanced Mode:** click your profile initial (bottom-left
  sidebar) → scroll to **Advanced Mode** → on. Unlocks Developer Tools
  and the full settings surface.

**Gotcha — Nabu Casa Cloud trial.** The onboarding flow has a
"Remote access" toggle that silently enrols you in a 1-month paid
cloud trial (~$6.50/mo). You don't need it — Tailscale does the same
job for free. Turn it off in **Settings → Home Assistant Cloud →
Remote control: off** (or Sign out to end the trial entirely).

#### 4.6 Mosquitto user for HA

Create the `ha` MQTT user and tell HA about it:

```sh
sudo mosquitto_passwd -b /etc/mosquitto/passwd ha <password>
sudo systemctl restart mosquitto
```

In HA: **Settings → Devices & Services → + Add Integration → MQTT**:
- Broker: `127.0.0.1`
- Port: `1883`
- Username: `ha`
- Password: *(the one you just set)*

HA subscribes to the broker. Confirm by publishing from HA
("Configure" on the MQTT card → publish `test/hello` → `hi from ha`)
and subscribing from the server
(`mosquitto_sub -u wabot -P ... -t 'test/#' -v`) — the message should
show up.

#### 4.7 Mobile Companion app (personal phone)

- Play Store → install **Home Assistant** (official, Open Home Foundation).
- Open → **Enter address manually** → `http://192.168.1.230:8123`
  (don't auto-discover; it tends to pick the wrong URL).
- Log in with your HA admin account.
- Permissions:
  - **Notifications** — mandatory; the whole point.
  - **Battery → Unrestricted** (Android Settings → Apps → Home
    Assistant → Battery). Without this Android drops the FCM
    connection after a day or two.
  - **Location** — optional, enables GPS-based arrive/leave triggers.
- HA auto-creates `mobile_app.<your_device>` + `device_tracker.<phone>`
  + usually a `person.<you>` entity.

#### 4.8 Tailscale on personal phone (for off-LAN use)

- Play Store → install **Tailscale** → sign in with the same account
  you used to set up Tailscale on `.230`.
- Toggle VPN **on**.
- Android Settings → Apps → Tailscale → **Battery: Unrestricted**
  (otherwise the VPN dies in the background and off-LAN HA breaks).

Mobile Companion auto-switches between `internal_url` (home Wi-Fi) and
`external_url` (Tailscale) based on which responds.

#### 4.9 Generic Camera integration (IP Webcam → HA)

**Settings → Devices & Services → + Add Integration → Generic Camera:**

| Field | Value |
|---|---|
| Still Image URL | `http://192.168.1.231:8080/shot.jpg` |
| Stream Source URL | `rtsp://192.168.1.231:8080/h264_pcm.sdp` (or leave blank) |
| Username / Password | IP Webcam creds |
| Authentication | Basic |
| Verify SSL | off |
| Frame rate | 2 (gentler on wall phone) |

**Gotcha — the wall phone's camera is off-demand.** The `!cctv` command
wakes IP Webcam, grabs the snap, kills it. So when HA's Generic Camera
tries to validate the URL during add-integration, the camera is dead
and HA rejects it. Fix: fire `!cctv on 30` on WhatsApp *first* so the
camera is awake, *then* hit Submit on HA's form within those 30
seconds.

**Gotcha — stream URL often 404s.** IP Webcam's RTSP endpoints depend
on the "Audio format" chosen inside IP Webcam. `/h264_ulaw.sdp` only
works if audio is G.711 μ-law. Try `/h264_pcm.sdp` or `/h264_aac.sdp`.
For on-demand operation the stream URL is irrelevant anyway; snapshot
is enough.

#### 4.10 Met.no weather (no API key)

**Settings → Devices & Services → + Add Integration → Met.no**:
- Name: `Home`
- Lat/Lng auto-fill from HA's home coords (Google Maps right-click →
  copy coords if wrong).

Creates `weather.home`. If Met.no doesn't cover your region well,
**Open-Meteo** works the same way with no key.

#### 4.11 Two dashboards: Home (wall phone) and Admin (office)

We ended up splitting into two dashboards instead of one "Wall" because
the wall phone shouldn't expose camera feeds or system internals to
whoever walks by — the family-facing screen stays simple, the admin
screen has the full toolbox.

**Home dashboard** (`/dashboard-home` → fed to Fully Kiosk):
- Settings → Dashboards → Add → Title: `Home`, URL path: `home`,
  Icon: `mdi:home`. Show in sidebar: on.
- Big clock Markdown card (same template as before: `# {{ now().strftime('%H:%M') }}`).
- Intercom button (one-tap `mqtt.publish` on `intercom/play` with a
  pre-canned "voice note is waiting" audio URL — placeholder script
  `script.intercom_from_me`).
- Assistant launcher button (opens Manorama News / YouTube — Fully Kiosk
  URL action).
- "Call me" button (`mqtt.publish` → `household/ping` → wabot DMs the
  first owner: `📞 Someone at home is calling you`). See household
  module in wabot.md.

**Admin dashboard** (`/dashboard-admin` → office use, Tailscale):
- Title: `Admin`, URL path: `admin`, Icon: `mdi:shield-crown`.
- **Live camera** — Picture Entity → `camera.wall_phone` (tap-action:
  more-info). Only live when `!cctv on` has been fired.
- **LAN devices** — Markdown card:
  ```
  ## LAN devices (home right now)
  {% set home = state_attr('sensor.lan_devices', 'home') or [] %}
  {% set away = state_attr('sensor.lan_devices', 'away') or [] %}
  {% for d in home %}
  - **{{ d.label or d.hostname or d.mac }}** — {{ d.last_ip }} — {{ d.vendor }}
  {% endfor %}
  {% if home | count == 0 %}_nobody home_{% endif %}
  _{{ home | count }} home • {{ away | count }} away_
  ```
  (The `or []` fallback matters — before the REST sensor's first fetch,
  the attributes are `None` and `| count` raises `TypeError`.)
- **Server health** — Entities card:
  ```yaml
  type: entities
  title: Server health (.230)
  show_header_toggle: false
  entities:
    - entity: sensor.system_monitor_processor_use
      name: CPU
    - entity: sensor.system_monitor_load_1_min
      name: Load (1m)
    - entity: sensor.system_monitor_memory_usage
      name: RAM used
    - entity: sensor.system_monitor_disk_usage
      name: Disk /
    - entity: sensor.system_monitor_processor_temperature
      name: CPU temp
    - entity: sensor.system_monitor_uptime
      name: Uptime
  ```
  In HA 2026.11 the System Monitor entities are prefixed
  `system_monitor_` and **most are auto-disabled** by the integration.
  Enable them via Settings → Devices → System Monitor → check the
  entities you want. Or edit `.storage/core.entity_registry` and clear
  `disabled_by` for the IDs you need (stop HA first, then restart).
- **CCTV wake / sleep** — Horizontal stack of two Button cards firing
  `script.cctv_wake_60s` and `script.cctv_sleep`
  (both are `mqtt.publish` to `cctv/control`).

URLs to feed into things:
- Fully Kiosk on the wall phone: `http://192.168.1.230:8123/dashboard-home/0`
- Office browser (Tailscale): `http://100.99.232.45:8123/dashboard-admin/0`

#### 4.12 Wall-phone kiosk ✅ 2026-11-21

Fully Kiosk Browser is ruled out — ₹900 paywall, and even with the
license HA's sidebar + title bar leak through. HACS is also dead:
**HA 2026.11 deletes `custom_components/hacs/` on every startup by
directory name** (verified: identical contents named `hacs_renamed/`
survived, `hacs/` always wiped — no log entry, silent). That takes the
`kiosk-mode` HACS plugin off the table too.

Replacement that actually works — pure HA config, no third-party
plugin store:

1. **`www/kiosk-chrome.js`** — ~90-line JS module that walks every
   HA shadow root and injects CSS hiding `app-header`, `ha-sidebar`,
   `ha-top-app-bar-fixed`, view tabs, edit pencil, kebab, hamburger,
   and the dashboard title bar. Gated on URL param `?kiosk=1` so the
   same dashboard still edits normally when loaded without the flag.
   Uses a `MutationObserver` so view swaps pick the styles up fast.

2. **Register it in `configuration.yaml`**:
   ```yaml
   frontend:
     extra_module_url:
       - /local/kiosk-chrome.js
   ```
   HA restart required once. Later edits to the JS only need a
   browser hard-refresh (`Ctrl+Shift+R`) — HA serves `/local/*` with
   `max-age=2678400`, so the browser caches it for a month otherwise.

3. **WallPanel** (free, open source, Thanksmister) in place of Fully
   Kiosk on the wall phone. Dashboard URL set to
   `http://192.168.1.230:8123/dashboard-wall/0?kiosk=1`. Session login
   persists; full-screen, screen-on, hide-system-bars all in-app.

Same editable HA dashboard, no HA chrome on the wall. Drop `?kiosk=1`
from the URL to get the edit UI back.

#### 4.13 Arrival / departure notification ✅ 2026-11-21

Done as two YAML automations (one for arrive, one for leave) in
`/srv/homeassistant/.homeassistant/automations.yaml` — cleaner than a
single if/else and shows up as two toggles in the UI:

```yaml
- id: arrival_sirajju
  alias: "Arrival — Sirajju"
  mode: single
  triggers:
    - trigger: state
      entity_id: person.sirajju
      to: home
  actions:
    - action: notify.mobile_app_i2219
      data:
        title: "Welcome home"
        message: "You just arrived at home ({{ now().strftime('%H:%M') }})"
        data: { tag: presence-arrive, channel: Presence }

- id: departure_sirajju
  alias: "Departure — Sirajju"
  mode: single
  triggers:
    - trigger: state
      entity_id: person.sirajju
      from: home
  actions:
    - action: notify.mobile_app_i2219
      data:
        title: "Left home"
        message: "You just left home ({{ now().strftime('%H:%M') }})"
        data: { tag: presence-leave, channel: Presence }
```

After editing: Developer Tools → YAML → **Reload Automations** (or hit
the "Reload" dot on Settings → Automations). No full HA restart.

Test via Developer Tools → States → set `person.sirajju` to
`not_home` then `home` (temporary override — reverts once the
Companion app reports real state).

#### 4.14 Gotchas captured all in one place

- **"59 MB free" was router RAM, not server.** Server has 2.8 GB
  available. Ignore any old note suggesting otherwise.
- **Config dir is `/srv/homeassistant/.homeassistant`** because
  `useradd -d` sets HOME to `/srv/`. Don't pass `/home/homeassistant/...`.
- **UI refuses to edit homeassistant: keys when YAML owns them.**
  Edit YAML directly.
- **`check_config` from `sudo -S` fails on `uv.toml` perms.** Only an
  issue when running it ad-hoc from a non-homeassistant user; the live
  service is fine.
- **Nabu Casa trial auto-starts from the onboarding "Remote access"
  toggle.** Disable in Cloud settings to avoid being billed.
- **Generic Camera add fails because IP Webcam is off** — wake with
  `!cctv on 30` first.
- **IP Webcam RTSP URL depends on Audio format setting.** `/h264_pcm.sdp`
  tends to work best. For on-demand use, stream is irrelevant.
- **Companion drops FCM push after a day** when Android battery
  optimization kills it. Set Companion to Unrestricted battery.

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
