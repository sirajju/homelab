# Homelab

Living notes for everything running on the home network. Written for
future-me — short, concrete, current.

## Topology

```
                             ┌──────────────────┐
                             │   Internet / ISP │
                             └────────┬─────────┘
                                      │  PPPoE on VLAN 1001
                                      ▼
                     ┌─────────────────────────────────┐
         192.168.1.1 │  Genexis Platinum 4410          │
                     │  dnsmasq, udhcpd, web admin :80 │  ← Kerala Vision ONT
                     │  /captcha/leases  (no auth!)    │
                     └─────────────────────────────────┘
                                      │  LAN /24
                       ┌──────────────┼──────────────┐
                       ▼              ▼              ▼
             .16  Laptop       .230  H55 server   .2–.10  phones + IoT
             (Ubuntu, dev)     (Ubuntu, services)  (randomized MAC)
```

- Router config, creds, lease endpoint → [network.md](./network.md).
- Both my laptop (.16) and the server (.230) also have Tailscale
  (`100.x.y.z`); the server is the exit node for a few remote devices.

## What's running

| Where | What | How it runs | Notes |
|---|---|---|---|
| **192.168.1.230** | wa-bot | `wabot.service` (user systemd) | WhatsApp bot, Go + whatsmeow. See [wabot.md](./wabot.md). Also runs the intercom bridge (`:8766`). |
| **192.168.1.230** | wifi-presence | `presence.service` (user systemd) | LAN presence tracker, Go. Hostnames now land from `/captcha/leases`. See [wifi-presence.md](./wifi-presence.md). |
| **192.168.1.230** | Mosquitto | `mosquitto.service` (system) | MQTT broker, `:1883` on `0.0.0.0`. Users: `wabot`, `wallphone`, `ha`. Password file **must** be owned by the `mosquitto` service user. |
| **192.168.1.230** | AdGuard Home | binary daemon | DNS filtering, upstream = router. Was on `.7`, moved to `.230`. |
| **192.168.1.230** | Tailscale | `tailscaled` | DNS hijack **disabled** (`--accept-dns=false`) — broke wa-bot last time. |
| **192.168.1.230** | MongoDB | system service | Only used by wa-bot for one legacy feature (planned to drop). |
| **192.168.1.16** | Development | — | Laptop. Has `gh` CLI logged in (used for pushes). Go SDK at `~/sdk/go`. |

## Code repositories

| Repo | Path (laptop) | Path (server) | Branch state |
|---|---|---|---|
| wa-bot | `~/whatsapp-bot-with-ai` | `~/whatsapp-bot-with-ai` (no `.git`) | `main` = `41a859a`, one ahead of origin. Push pending. |
| wifi-presence | `~/wifi-presence` | `~/wifi-presence/{,data,}` (no `.git`) | `main` = `d8168ee`, synced with origin. |

Deployment is **rsync from laptop → server**, binary built locally with
`CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build`. Server has no Go toolchain
on PATH (but one exists at `~/toolchains/go/bin/go` — used by picoclaw).

## What's planned / in progress

- [wall-phone-plan.md](./wall-phone-plan.md) — rooted Redmi Note 10 as a wall
  assistant.
  - ✅ **Phase 1** — Mosquitto up on `.230:1883`, LAN-reachable.
  - ✅ **Phase 2** — wabot intercom bridge live. Voice note from owner →
    cached + HTTP-served at `:8766` + MQTT-published to `intercom/play`.
  - ✅ **Phase 3** — Termux subscriber on the wall phone (`~/intercom.sh`,
    boot hook at `~/.termux/boot/intercom` with a `sleep 15 +
    termux-volume` warm-up for the Termux:API IPC bridge). Verified
    across reboots 2026-11-18: WhatsApp voice note plays on the
    speaker with no user interaction. Tasker was skipped — the free
    MQTT-plugin landscape was grim and Termux was leaner.
  - ⏳ **Phase 4** — Home Assistant Core on `.230` for dashboard +
    camera + mobile companion. Low-RAM config pinned in the plan file.

## Known gotchas (things that broke before)

- **Tailscale DNS hijack kills wa-bot.** `/etc/resolv.conf` on `.230`
  gets `100.100.100.100`, MagicDNS upstream fails, whatsmeow pairing
  dies with `server misbehaving`. Fix: `sudo tailscale set
  --accept-dns=false && sudo tailscale down && sudo tailscale up`.
  Persists across reboots. Full write-up in
  [`~/.claude/projects/-home-sirajju/memory/wa-bot-project.md`](../..).

- **Two "initial scaffold" commits with different SHAs.** Both wa-bot and
  wifi-presence had orphan local `main` branches that didn't share an
  ancestor with `origin/main`. Fix: `git fetch origin && git reset --hard
  origin/main` on the local; cherry-pick any feature commits on top.
  Happens when `gh repo create --push` or `--amend` rewrites the initial.

- **Phantom DB from wrong CWD.** Running `./presence` from `$HOME` creates
  `~/data/presence.db` because the config's default is the relative path
  `./data/presence.db`. The systemd unit's `WorkingDirectory=%h/wifi-presence`
  is what makes it resolve to the real DB. Always run the binary the same
  way systemd does, or set `PRESENCE_DB` to an absolute path.

- **Deployed binary ≠ source dir.** On `.230`, the systemd unit's
  `ExecStart=%h/.local/bin/presence` but I kept installing to
  `~/wifi-presence/presence`. The service silently ran an older build.
  Always install to the ExecStart path; the server dirs don't have `.git`
  so there's no "git status" to warn you.

## Operational cheatsheet

```sh
# SSH to the server
ssh sirajju@192.168.1.230

# wa-bot
wabot status | logs -f | restart | deploy       # CLI shortcut (see wabot.md)

# wifi-presence
systemctl --user {status,restart,logs} presence
curl http://127.0.0.1:8765/api/status | jq '.home[] | {hostname, mac, last_ip}'

# router
curl http://192.168.1.1/captcha/leases          # live DHCP leases, no auth

# publish the whole repo from laptop
cd ~/whatsapp-bot-with-ai && git push origin main
cd ~/wifi-presence         && git push origin main
```

## Files in this directory

- `README.md` — this file.
- `network.md` — IPs, router, DNS, DHCP, how the pieces resolve each other.
- `wabot.md` — bot features, commands, deployment, env vars.
- `wifi-presence.md` — how presence detection + hostname resolution work.
- `wall-phone-plan.md` — unbuilt: the voice assistant + CCTV + intercom design.
