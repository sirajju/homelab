# wa-bot

Self-hosted WhatsApp bot. Go + [`whatsmeow`](https://github.com/tulir/whatsmeow)
+ `modernc.org/sqlite` + `rs/zerolog`. No cgo, static binary, no Docker.

- **Repo:** [github.com/sirajju/whatsapp-bot-with-ai](https://github.com/sirajju/whatsapp-bot-with-ai)
- **Dev checkout:** `~/whatsapp-bot-with-ai` on laptop `.16`
- **Server copy:** `~/whatsapp-bot-with-ai` on `.230` (no `.git` — rsynced)
- **Binary:** `~/whatsapp-bot-with-ai/bin/wabot` (18 MB static, linux/amd64)
- **User systemd unit:** `wabot.service`
- **Log:** `~/whatsapp-bot-with-ai/wabot.log`

## Deployment

The server has no system Go on PATH. Build locally, rsync, swap binary:

```sh
# On the laptop
cd ~/whatsapp-bot-with-ai
PATH="$HOME/sdk/go/bin:$PATH" \
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags='-s -w' -o /tmp/wabot-new ./cmd/wabot
scp /tmp/wabot-new sirajju@192.168.1.230:/tmp/wabot-new
ssh sirajju@192.168.1.230 '
  systemctl --user stop wabot &&
  install -m 755 /tmp/wabot-new ~/whatsapp-bot-with-ai/bin/wabot &&
  systemctl --user start wabot
'
```

The CLI wrapper `wabot` on `.230` (`~/.local/bin/wabot`) has convenience
subcommands that do all of the above:

```
wabot status | start | stop | restart | enable | disable
wabot logs [-f] [-n N]   # application log
wabot journal [-f]       # systemd journal
wabot build              # build binary (needs Go)
wabot deploy             # build + restart
wabot run                # foreground run — debug only
wabot ps                 # pid, cpu/mem, open sockets
wabot env | path         # inspect config paths
```

## Config (`~/whatsapp-bot-with-ai/.env`)

| Var | Purpose |
|---|---|
| `PREFIX=!` | Command prefix |
| `OWNERS=917XXXXXXXXX` | CSV of owner phone numbers (JID User part) |
| `LOGIN_MODE=pairing` + `PAIR_PHONE=…` | Headless pairing login |
| `SESSION_DIR=./session` | Where whatsmeow stores its sqlite session |
| `GROUP_TRIGGER_MENTION_ONLY=on` | Only respond in groups when @mentioned |
| `ANTHROPIC_API_KEY=…` | AI provider (also supports OpenAI, Gemini, Groq, Ollama) |
| `AI_PREFERRED=anthropic` | Which AI backend to prefer |
| `PRESENCE_API_URL=http://127.0.0.1:8765` | wifi-presence base URL |
| `PRESENCE_ALERTS=off` | Owner DM alerts on arrive/depart. **off** by current preference |
| `INTERCOM_ENABLED=on` | Wall-phone intercom. When on, owner voice notes auto-forward via MQTT |
| `INTERCOM_MQTT_BROKER=tcp://127.0.0.1:1883` | Local Mosquitto |
| `INTERCOM_MQTT_USER / _PASSWORD` | wabot's MQTT creds |
| `INTERCOM_MQTT_TOPIC=intercom/play` | Topic the phone subscribes to |
| `INTERCOM_HTTP_LISTEN=0.0.0.0:8766` | Where audio clips are served |
| `INTERCOM_PUBLIC_URL=http://192.168.1.230:8766` | What we tell the phone to fetch from |
| `INTERCOM_CACHE_DIR=/tmp/wabot-intercom` | Where downloaded clips live for TTL minutes |
| `CCTV_URL=http://192.168.1.231:8080/shot.jpg` | Snapshot endpoint on the wall phone |
| `CCTV_USER / CCTV_PASSWORD` | IP Webcam credentials (used for both auth header and inline URL embed) |
| `CCTV_CONTROL_TOPIC=cctv/control` | MQTT topic the phone subscribes to for wake/sleep |
| `CCTV_START_TIMEOUT=20s` | How long to wait for the camera to come up after publishing `start` |
| `CCTV_AUTO_STOP=on` | Auto-publish `stop` after a snapshot is grabbed |
| `CCTV_STREAM_URL` | MJPEG endpoint (default: `CCTV_URL` with `/shot.jpg` → `/video`) |
| `CCTV_STREAM_URL_EXT` | Optional external MJPEG URL (phone's Tailscale IP) |
| `CCTV_LIVE_DEFAULT=120s` | Default duration for `!cctv on` |
| `CCTV_LIVE_MAX=600s` | Cap for `!cctv on <N>` |
| `STARTUP_NOTIFY=on` | DM first owner on every process start |
| `MONITOR_ENABLED=on` | System health monitor — DMs owner on threshold crossings |
| `MONITOR_INTERVAL=60s` | How often to probe system metrics |
| `MONITOR_MEM_PCT=15` | Alert when available RAM < this % of total |
| `MONITOR_DISK_PCT=10` | Alert when free disk on `/` < this % |
| `MONITOR_LOAD_MULT=2.0` | Alert when 1-min load > ncpu × this |
| `MONITOR_TEMP_C=75` | Alert when CPU temp (°C) > this |
| `MONITOR_COOLDOWN=30m` | Minimum gap between repeat alerts |
| `INTERCOM_TLS_CERT` | PEM cert file. When set with `INTERCOM_TLS_KEY`, the intercom HTTP server runs HTTPS instead of HTTP (needed so browsers hand out mic permission to the kiosk mic page). |
| `INTERCOM_TLS_KEY` | PEM key file (pair with the cert above). |

## Commands

Owner-only commands are now **hidden from non-owners in `!menu`** and
grouped under a separator for owners. The marker is a help-string prefix
`owner:` — if a command is owner-gated at the handler, make its help
string start with `owner:` and the menu does the right thing automatically.

### Normal
- `!ai [prompt]` — Ask the AI. Default persona is friendly WhatsApp assistant.
- `!persona <name>` — Swap AI persona per chat.
- `!clearai` — Reset AI history for this chat.
- `!expense` — Shared expense tracker. See `!expense help`.
- `!home` / `!devices` — LAN presence (owner-only). Shows hostnames.
- `!ping`, `!menu`, `!quote`, `!qr`, `!8ball`, `!joke`, `!calc`, …

### Owner-only
- `!send <phone> <text>` — DM any phone from the bot number.
- `!broadcast <text>` — DM all contacts (rate-limited).
- `!label <mac> <name> [owner]` — Rename a device in wifi-presence.
- `!cctv` / `!cam` / `!snap` — One-shot snapshot from the wall-phone camera. Wakes the camera on-demand via MQTT, grabs the shot, shuts it off.
- `!cctv on [seconds]` — Wake the camera for N seconds (default 120, cap 600), DM back the MJPEG URL(s). Auto-shuts on timer or on `!cctv off`. Great for live viewing without the camera idling.
- `!cctv off` — Cancel the live timer + stop the camera immediately.
- `!block <phone>` / `!unblock <phone>` — Blocklist.
- `!restart`, `!sh <cmd>`, `!shutdown`.

### Dashboard-side features (HTTP endpoints)

- **`POST /voice-from-home`** on the intercom HTTP server. Receives a
  browser-recorded audio blob (MediaRecorder; `audio/webm;codecs=opus`
  by default), ffmpeg-transcodes to ogg/opus at 48 kHz mono with
  `-application voip`, ffprobe-stamps the duration, uploads via
  whatsmeow, and sends to `Owners[0]` as a WhatsApp PTT voice note.
  CORS set to `*` so the mic page can POST from the HA origin.
  Served over HTTPS when `INTERCOM_TLS_CERT`/`INTERCOM_TLS_KEY` are
  set (we use the Tailscale cert — see wall-phone-plan.md § 4.14).
- **`GET /mic` and `GET /mic.html`** serve an embedded voice-recorder
  HTML page. Not used by the wall phone (the dashboard button points
  at HA's `/local/mic.html` instead, same origin as the dashboard
  keeps the WebView happy), but handy for testing in a bare browser.

### Background jobs (not commands — things wabot does on its own)

- **Startup DM** — On every process start, one DM to the first owner:
  `🟢 wabot up on <host> at <time>`. Fires once per process (reconnects
  don't spam). Disable with `STARTUP_NOTIFY=off`.
- **System health monitor** — Ticks every `MONITOR_INTERVAL` (default
  60s) and probes memory / disk / CPU load / CPU temp on `.230`. DMs the
  first owner on threshold crossings and again on recovery. Thresholds
  tunable via `MONITOR_MEM_PCT`, `MONITOR_DISK_PCT`, `MONITOR_LOAD_MULT`,
  `MONITOR_TEMP_C`, `MONITOR_COOLDOWN`. Disable with `MONITOR_ENABLED=off`.
  See `internal/monitor/monitor.go`.
- **Intercom** — Owner voice notes in DM → MQTT `intercom/play` → wall
  phone speaker. Config: `INTERCOM_*`. See wall-phone-plan.md.
- **CCTV control** — Shares MQTT with intercom (`cctv/control` topic).
  Phone-side `~/cam-control.sh` listens and runs `am start/am force-stop`.
  Config: `CCTV_*`.

## Skills (user-extensible)

Executable scripts under `~/whatsapp-bot-with-ai/skills/` are exposed as
`!skill <name> [args]`. Each one runs as its own process, gets env
`WABOT_SENDER`, `WABOT_CHAT`, `WABOT_OWNER`, `WABOT_GROUP`, `WABOT_ARGS`,
and its stdout becomes the chat reply. Output is now sent **without**
code-block wrapping so `*bold*` / `_italic_` render on WhatsApp.

Current skills:
- `expense` (Python) — the shared expense tracker. Full doc in
  `~/whatsapp-bot-with-ai/skills/expense`.

To add a new skill:
```sh
cd ~/whatsapp-bot-with-ai/skills
cat > weather <<'PY'
#!/usr/bin/env python3
# desc: get the weather
import sys, requests
...
PY
chmod +x weather
# No restart needed; !skill list picks it up on next call.
```

## AI tool-calling

The bot's AI layer can call tools it registers in
`internal/aitools/registry.go`. Live count: **24 tools**. Categories:
- Expense (add/pay/list/split/settle/credit/sync + bulk).
- Presence (home status, device labelling via wifi-presence).
- Reminders (set/list).
- Web (search, fetch).
- Weather.

When the AI is used (either `!ai` or auto-reply in DMs when `AI_MODE=on`),
it may call these tools transparently. Add a new tool: define it in
`internal/aitools/<name>.go`, register in `RegisterAll()`, rebuild.

## Known behaviours worth remembering

- **Session file** (`~/whatsapp-bot-with-ai/session/*.db`) is the
  whatsmeow pairing token. Delete it to force re-pair. **Do NOT
  rsync it between machines** — WhatsApp invalidates the session.
- **Auto-restart on WhatsApp websocket failure** — if the bot wedges
  (WebSocket silently dies), the service keeps running but stops
  responding. Watch the log: `"keepalive"` lines every ~30s; if they
  stop for > 2 min, `wabot restart`.
- **Owner detection** uses both the main sender JID and the SenderAlt
  LID — the `fix(router)` commit (`f62e854`) added that.

## Intercom module (new)

`internal/intercom/intercom.go` — wabot ↔ MQTT bridge for the wall-phone
project. See [wall-phone-plan.md](./wall-phone-plan.md) for the whole
flow. Short summary:

- Hook registered FIRST in main.go's router hook chain.
- Only owner DMs trigger it; group messages and non-audio messages are
  ignored.
- Caption can be empty (any voice note), `!say`, or `!intercom`.
- Downloads via whatsmeow `cli.Download`, writes `<uuid>.opus` under
  `INTERCOM_CACHE_DIR`, HTTP-serves on `INTERCOM_HTTP_LISTEN`, publishes
  a JSON envelope to `INTERCOM_MQTT_TOPIC`.
- Reacts 📣 to the WA message so the owner sees acknowledgement.
- Stop() tears down HTTP + MQTT cleanly on signal.

Dep added: `github.com/eclipse/paho.mqtt.golang v1.5.1`.

Router behaviour change: previously `router.Dispatch` returned early on
empty text, so media-only messages never reached any hook. The empty
check now runs AFTER the hook loop, letting passive media hooks (like
intercom) see those events. Hooks that only care about text already
handle the empty case (checked: welcome, blocklist, antilink).

## Recently merged

Roughly in order (see `git log origin/main --oneline` for the real list):

- `588afb8` (pending push) — chore(intercom): nest default cache dir
  under `/tmp/wabot/` to avoid colliding with staging scp targets.
- `b74b1e5` (pending push) — feat(intercom): WhatsApp voice note from
  owner → MQTT → wall-phone audio URL.
- `41a859a` (pending push) — menu owner-filter + grouping, hostname in
  presence alerts.
- `c463a0b` — merge PR #1: presence skill (`!home`, `!devices`, `!label`,
  owner alerter).
- `7caaa42` — expense: list-all default, group description sync, bold fix.
- `8262271` — expense: credit expenses + settle + bulk add via AI.
- `1845c54` — expense: split members separate from items + AI tools.
- `54bdea4` — expense: initial shared expense tracker.
- `f4c9c15` — WhatsApp-aware AI, auto-welcome DM, owner `!send`, installer.
