# Changelog

## 1.0.0 — 2026-10-12

First release. The UniFi Network Application 10.6.106 (linuxserver.io's image)
with MongoDB in Container Manager — MongoDB 8.0 on processors with AVX, 4.4 on
those without (many Synology Celerons), 7.0 on Linux kernels MongoDB 8.0
refuses to start on. UniFi's first-run wizard is done for
you: your administrator is made at the first start with the password shown
once, the country and time zone are set, autobackups are on, and UniFi is told
the address your devices should inform to. A community package, not made by
Ubiquiti or Synology.

The DSM window adds:
- **Devices:** every adopted access point, switch and gateway with its model,
  state, firmware (and whether an update is waiting) and clients, read by a
  read-only UniFi account the package makes; a DSM notification when one has
  been offline for 10 minutes, and when a new one waits to be adopted.
- **Adopt:** the inform address with a copy button, `set-inform` and the
  `unifi` name explained, the devices waiting, the inform host, and the ports
  (inform, STUN, discovery, the guest portal) — each checked against what this
  Synology already uses.
- **Backups:** UniFi's own autobackups, copied daily into the shared folder
  for Hyper Backup and File Station, beside the package's backups — a MongoDB
  dump and UniFi's data folder, taken with UniFi paused for a moment so the two
  match — with restore.
- **Memory:** Java's heap and MongoDB's cache, with suggestions for this NAS's
  memory and what each uses now.
- **Updates:** UniFi stays at a tested release; the window finds newer ones and
  moves to them after a backup.

Also included: HTTPS with DSM's certificate, a new password for any UniFi
administrator, a redacted support report and removal.
