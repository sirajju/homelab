# Network

## Subnet

- LAN: `192.168.1.0/24`, gateway `192.168.1.1`.
- DHCP range (from router web UI): `192.168.1.2 – 192.168.1.253`.
- Lease time: 1 day (web UI default).

## Fixed addresses (reserved on the router)

| IP | Host | Role |
|---|---|---|
| `192.168.1.1`   | Genexis P4410 | Router, DNS (dnsmasq), DHCP (udhcpd), web admin |
| `192.168.1.230` | H55 server (Ubuntu) | wa-bot, wifi-presence, AdGuard, Tailscale |
| `192.168.1.16`  | Laptop (Ubuntu) | Development, `gh` auth, Go SDK |

`.230` reservation was set via the router admin UI's **Address Reservation**
page. The server's MAC is pinned so it never drifts.

## DNS

- Router runs dnsmasq but does **not** expose it on `192.168.1.1:53`
  publicly — direct `dig @192.168.1.1` times out. Reverse-DNS probes for
  LAN hostnames therefore fail; the lease scrape at
  `http://192.168.1.1/captcha/leases` is the only way to get names from
  the router.
- AdGuard Home on `.230` is the household resolver. DHCP option 6 (DNS
  server) on the router was set to `192.168.1.7` originally; needs
  updating to `.230` when AdGuard is confirmed listening there.
- Tailscale on `.230` has `--accept-dns=false` — mandatory. Re-enabling
  breaks `web.whatsapp.com` resolution and wabot crash-loops.

## Router — Genexis Platinum 4410 (Kerala Vision)

- Firmware: P4410-V2-1.38.
- Admin web UI: `http://192.168.1.1/` (basic auth → form).
- Web admin creds: `admin / BC62D2CFC058` (recovered from firmware dump —
  see router-jailbreak memory note).
- Telnet / SSH: **both closed** in current firmware. Previously open,
  with creds `admin / GeNe20@Xis!0987#` — may still work if ISP re-enables.

### The `/captcha/leases` endpoint — gold

Plain-text, no authentication required. Returns the live DHCP lease
table, one row per device:

```
96:4A:90:3D:0A:8B 192.168.1.2 127362 Siru-s-A13
00:08:22:16:EE:FB 192.168.1.3 127044 android-68dc4e1425ad0752
```

Columns: `MAC IP remaining-TTL-seconds hostname`.

Caveat: this is in-RAM on the router. **Reboot wipes it.** wifi-presence
keeps a persistent copy using sticky UPSERTs so the hostnames survive
reboots (see [wifi-presence.md](./wifi-presence.md)).

## Tailscale

- Tailnet DNS/MagicDNS disabled on `.230` (see gotcha in README).
- Exit node capability enabled on `.230` for roaming devices.
- Laptop (`.16`) also on the tailnet; useful for reaching `.230` from
  outside home without port-forwarding.
- Private IPv6 ULAs: `fd7a:115c:a1e0::/48` (Tailscale) — ignore unless
  debugging.

## Troubleshooting checklist

If services on `.230` suddenly can't resolve names:
1. `cat /etc/resolv.conf` — should NOT only contain `100.100.100.100`.
2. If Tailscale hijacked it: `sudo tailscale set --accept-dns=false &&
   sudo tailscale down && sudo tailscale up`.
3. `getent hosts web.whatsapp.com` should resolve to a real IP.

If clients lose internet:
1. `dig @192.168.1.230 example.com` from a client — must answer (AdGuard).
2. If AdGuard is down → DHCP's advertised DNS has no fallback; router
   doesn't proxy DNS. Clients need to be told a different resolver or
   AdGuard brought back up.
