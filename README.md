# ubuntu-displayscreen

Turns an Ubuntu Server box into a fullscreen camera-wall kiosk: it boots
straight into an mpv display of RTSP streams from a Dahua NVR, laid out in a
grid. Tested on Intel NUC5i5RYH with Ubuntu Server 24.04.

Two ways to run it:

- **Managed** (recommended) — the screen registers with a central display
  manager and takes all of its configuration from there: camera grid, NVR
  details, SSH keys, WiFi, remote restart/reboot. Installing needs just two
  values from the manager's Settings page.
- **Standalone** — everything is configured on the box itself at install time.

## Install

Create the kiosk user first if it doesn't exist (`sudo adduser viewer`), then:

### Managed

```bash
curl -fsSL https://raw.githubusercontent.com/mhenson-ejt/ubuntu-displayscreen/main/kiosk-setup.sh \
  | sudo MANAGER_URL=https://your-manager.example.com ENROLL_TOKEN=xxxx bash
```

The manager's Settings page shows this exact command with both values filled
in. After install, the screen appears on the manager's Screens page as "needs
configuration" — set its grid there and video starts seconds after saving.

### Standalone

```bash
sudo STANDALONE=1 NVR_IP=192.168.1.108 NVR_USER=viewer NVR_PASS='secret' \
     LAYOUT=4 CHANNELS="1 2 3 4" bash kiosk-setup.sh
```

Anything not supplied as an environment variable is prompted for.

## Options

All options are environment variables; every one is optional unless marked.
Interactive prompts cover whatever you leave out.

### Both modes

| Variable | Default | Meaning |
|---|---|---|
| `KIOSK_USER` | `viewer` | Existing local user that runs the display |
| `MANAGER_URL` | — | Manager base URL. Setting it selects **managed** mode |
| `ENROLL_TOKEN` | — | Enrollment token from the manager's Settings page (**required** in managed mode) |
| `STANDALONE` | — | Set to `1` to force standalone mode |
| `WIFI_SSID` | — | WiFi network to configure at install time (see [WiFi](#wifi)) |
| `WIFI_PASS` | — | WiFi password; omit for an open network |
| `SCRIPT_BASE_URL` | this repo's raw URL | Where `agent/*` support files are fetched from (a local checkout next to the script is used automatically if present) |

### Standalone only

| Variable | Default | Meaning |
|---|---|---|
| `NVR_IP` | — | Dahua NVR IP address |
| `NVR_PORT` | `554` | NVR RTSP port |
| `NVR_USER` | `viewer` | NVR username with live-view rights |
| `NVR_PASS` | — | NVR password (special characters are URL-encoded automatically) |
| `LAYOUT` | `4` | `1` single \| `2h` side-by-side \| `2v` stacked \| `4` 2×2 grid |
| `CHANNELS` | `1..n` | Space-separated NVR channel numbers, one per tile |
| `SUBTYPE` | `1` | `0` main stream, `1` substream (grids are forced to `1`) |
| `ROTATE` | `none` | Monitor rotation: `none` \| `left` \| `right` |
| `ROTATE_OUT` | auto | X output name for rotation, e.g. `HDMI-1` |
| `SSH_KEYS_URL` | this repo's `ssh-keys.txt` | Public-key list refreshed hourly |

In managed mode the layout/NVR/SSH-key equivalents of the standalone options
are all controlled from the manager UI instead.

## WiFi

WiFi is configured permanently at a worse route metric than wired, so the
cable is used whenever it's connected and traffic moves to WiFi the moment
it's not — no failover logic, and WiFi-only screens simply run on WiFi.

- **Managed mode**: set the fleet-wide SSID/password on the manager's Settings
  page — every screen picks it up on its next sync. `WIFI_SSID`/`WIFI_PASS` at
  install time are only needed for a screen that must reach the manager over
  WiFi *before* its first sync; the manager's setting takes over afterwards.
- **Standalone / by hand**: `sudo kiosk-apply-wifi "SSID" "password"`
  (`--clear` to remove).

## Upgrading

Re-run the same install command. The script is idempotent: it refreshes the
agent and support files, migrates state from older layouts, and restarts the
services with the new code. Managed screens keep their enrollment.

## Verify / troubleshoot

```bash
journalctl -u kiosk-agent -f      # managed: registration + sync heartbeats
systemctl status kiosk-display    # the X/mpv display service
```

Hardware reminders: set BIOS "After Power Failure" to Power On, and configure
the NVR substreams as H.264 with identical resolutions across channels.

For every step the installer performs, written out by hand (useful for
debugging a broken box), see [docs/manual-install.md](docs/manual-install.md).
