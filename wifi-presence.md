# wifi-presence

Standalone Go daemon that tracks who is on the LAN by MAC, labels them,
and exposes a local HTTP API. Pure Go, no cgo, no root, ~14 MB RSS.

- **Repo:** [github.com/sirajju/wifi-presence](https://github.com/sirajju/wifi-presence)
- **Dev checkout:** `~/wifi-presence` on laptop `.16` (`main` = `d8168ee`, synced)
- **Server copy:** `~/wifi-presence/` on `.230` (no `.git`)
- **Binary:** `~/.local/bin/presence` on `.230`  ← **must install here**, not
  `~/wifi-presence/presence`, because the systemd unit's ExecStart points
  to `~/.local/bin/presence`.
- **DB:** `~/wifi-presence/data/presence.db` (SQLite WAL, sticky writes)
- **User systemd unit:** `presence.service`
- **API:** `http://127.0.0.1:8765` (localhost only — proxied to wabot via
  `PRESENCE_API_URL`; expose externally via Tailscale if needed)

## How discovery works

1. **TCP-connect sweep** of `192.168.1.0/24` on port 80, 48 goroutines,
   150 ms dial timeout. Whether the dial succeeds is irrelevant — the
   kernel has to resolve the MAC via ARP to even try, which populates
   `/proc/net/arp` as a side effect.
2. **Read `/proc/net/arp`** after a 400 ms settle delay. Filter to the
   chosen interface, skip incomplete and self rows, produce `Sighting`s:
   `{MAC, IP, Vendor (OUI lookup), Hostname (filled next), TS}`.
3. **Resolve hostname** per sighting (see next section).
4. **UpsertSighting** into SQLite with *sticky* vendor & hostname.
5. **State machine** debounces HOME ⇆ AWAY using two windows:
   - HOME if `now - last_seen ≤ PRESENCE_HOME_WINDOW` (default 90 s).
   - AWAY if `now - last_seen ≥ PRESENCE_AWAY_WINDOW` (default 5 m).
   - In between: keep previous state (prevents phone-sleep flapping).

Default poll interval: 30 s. Configurable via `PRESENCE_POLL_INTERVAL`.

## How hostnames work (feature shipped `d8168ee`)

Three sources, tried per-sighting in priority order. First non-empty wins.

1. **Router DHCP lease table** — `fetchRouterLeases(ctx)` GETs
   `PRESENCE_ROUTER_LEASES_URL` (default
   `http://192.168.1.1/captcha/leases`). The Genexis P4410 returns plain
   text, no auth needed:
   ```
   96:4A:90:3D:0A:8B 192.168.1.2 127362 Siru-s-A13
   ```
   Parsed into a `MAC → hostname` map.
   **This covers ~95% of devices** because phones send a hostname in
   DHCP option 12 when they request a lease.
2. **NetBIOS NBSTAT probe** on `udp:137` with a 400 ms timeout. Catches
   Windows / Samba / some Android. Fails silently on phones.
3. **System reverse DNS** — `net.LookupAddr(ip)`. Catches whatever the
   LAN DNS happens to have PTR for. Usually nothing on this network.

### Sticky writes (survives router reboot)

The router's lease table is in RAM. On reboot it's empty until devices
rejoin and send fresh DHCP requests. That used to wipe the user's view.
The DB is the permanent record; the SQL guards against overwriting a
known-good value with an empty reading:

```sql
UPDATE devices SET
  last_seen = ?,
  last_ip   = ?,
  vendor    = CASE WHEN vendor   = '' AND ? <> '' THEN ? ELSE vendor   END,
  hostname  = CASE WHEN hostname = '' AND ? <> '' THEN ? ELSE hostname END
WHERE mac = ?
```

In plain English: *only fill vendor / hostname when we don't have one
and this scan has one. Otherwise keep what's there.* So a device that
appears once with a hostname is remembered forever, even if later scans
(or router reboots) return nothing.

### Hostname display priority (wabot `!home`)

`label → hostname → owner → vendor (unless "Randomized") → MAC`

Labels are human-set via `!label <mac> <name> [owner]` and take
precedence over everything else. The MAC is the fallback of last resort.

## API

| Method | Path | Returns |
|---|---|---|
| GET | `/healthz` | `{"status":"ok"}` |
| GET | `/api/status` | `{"home": [...], "away": [...]}` live view |
| GET | `/api/devices` | `[...]` every known device (incl. offline) |
| GET | `/api/events?since=<rfc3339>` | arrive/depart/new_device events |
| POST | `/api/label` | `{mac, label, owner?}` — set a friendly name |

`/api/status` sample (now includes `hostname`):
```json
{
  "home": [
    {"mac":"96:4a:90:3d:0a:8b","hostname":"Siru-s-A13",
     "label":"","owner":"","vendor":"Randomized","last_ip":"192.168.1.2",
     "last_seen":"2026-11-17T15:11:12Z"},
    ...
  ]
}
```

Event kinds: `arrived`, `departed`, `new_device`, `house_empty`,
`house_occupied`. wabot's optional alerter polls `/api/events?since=`
and DMs the first owner. Currently **off** (`PRESENCE_ALERTS=off`).

## Config (`~/wifi-presence/.env` on `.230`)

```
PRESENCE_LISTEN=127.0.0.1:8765
PRESENCE_INTERFACE=auto             # falls back from iface lookup
PRESENCE_SUBNET=auto                # clamps to /24 if /22 or /16 detected
PRESENCE_DB=./data/presence.db      # relative to WorkingDirectory
PRESENCE_POLL_INTERVAL=30s
PRESENCE_HOME_WINDOW=90s
PRESENCE_AWAY_WINDOW=5m
PRESENCE_EVENT_RETENTION_DAYS=30
PRESENCE_LOG_LEVEL=info
PRESENCE_ROUTER_LEASES_URL=http://192.168.1.1/captcha/leases
```

## Build + deploy

Server has no system Go. Build on the laptop, scp, swap:

```sh
cd ~/wifi-presence
PATH="$HOME/sdk/go/bin:$PATH" \
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags='-s -w' -o /tmp/presence-new ./cmd/presence
scp /tmp/presence-new sirajju@192.168.1.230:/tmp/presence-new
ssh sirajju@192.168.1.230 '
  systemctl --user stop presence &&
  install -m 755 /tmp/presence-new ~/.local/bin/presence &&
  systemctl --user start presence
'
```

Note the install path: **`~/.local/bin/presence`** (not
`~/wifi-presence/presence` — that one is leftover and can be deleted).

## Schema

```sql
CREATE TABLE devices (
    mac        TEXT PRIMARY KEY,
    label      TEXT NOT NULL DEFAULT '',
    owner      TEXT NOT NULL DEFAULT '',
    vendor     TEXT NOT NULL DEFAULT '',
    hostname   TEXT NOT NULL DEFAULT '',
    last_ip    TEXT NOT NULL DEFAULT '',
    first_seen INTEGER NOT NULL,
    last_seen  INTEGER NOT NULL
);
CREATE INDEX devices_last_seen ON devices(last_seen);

CREATE TABLE events (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    ts      INTEGER NOT NULL,
    mac     TEXT NOT NULL,
    kind    TEXT NOT NULL,       -- 'arrived'|'departed'|'new_device'|'house_empty'|'house_occupied'
    payload TEXT NOT NULL DEFAULT ''
);
CREATE INDEX events_ts ON events(ts);
```

Migration note: the `hostname` column was added via idempotent
`ALTER TABLE devices ADD COLUMN hostname TEXT NOT NULL DEFAULT ''` on
first boot of the new binary. The migration swallows "duplicate column
name" errors so it's safe to re-run.
