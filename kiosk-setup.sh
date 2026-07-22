#!/bin/bash
#===============================================================================
# Dahua NVR Camera Kiosk - One-line installer
#
# Sets up an Ubuntu Server machine (tested: Intel NUC5i5RYH, Ubuntu 24.04) to
# boot straight into a fullscreen mpv display of RTSP streams from a Dahua NVR.
#
# Two modes:
#
#   MANAGED (recommended) - the screen registers with a central display
#   manager and takes all configuration (layout, NVR details, SSH keys) from
#   it. Remote restart/reboot from the manager UI. Only needs two inputs:
#     curl -fsSL https://YOUR_HOST/kiosk-setup.sh | \
#       sudo MANAGER_URL=http://10.0.40.5:5000 ENROLL_TOKEN=xxxx bash
#
#   STANDALONE - classic self-contained install, all settings prompted here:
#     sudo STANDALONE=1 NVR_IP=192.168.1.108 NVR_USER=viewer NVR_PASS='secret' \
#          LAYOUT=2h CHANNELS="1 2" bash kiosk-setup.sh
#
# Env vars / prompts:
#   KIOSK_USER  - local user that runs the display (default: viewer)
#   MANAGER_URL - display manager base URL -> managed mode
#   ENROLL_TOKEN- enrollment token from the manager's Settings page
#   STANDALONE  - set to 1 to force standalone mode
#   SCRIPT_BASE_URL - where to fetch agent/* support files (default: this
#                 repo's raw GitHub URL; a local checkout is used if present)
#   WIFI_SSID   - optional: WiFi network to configure at install time (needed
#                 for screens that will run WiFi-only; wired stays preferred
#                 whenever a cable is connected). In managed mode the manager's
#                 fleet-wide WiFi setting overwrites this on the first sync.
#   WIFI_PASS   - WiFi password (omit for an open network)
#
# Standalone-only env vars / prompts:
#   NVR_IP      - IP address of the Dahua NVR
#   NVR_PORT    - RTSP port (default: 554)
#   NVR_USER    - NVR username with live-view rights
#   NVR_PASS    - NVR password (special characters are auto URL-encoded)
#   LAYOUT      - 1 | 2h | 2v | 4  (single / 2 side-by-side / 2 stacked / 2x2)
#   CHANNELS    - space-separated NVR channel numbers, e.g. "1 2 3 4"
#   SUBTYPE     - 0 main stream, 1 substream (default: 1; forced 1 for grids)
#   ROTATE      - none | left | right  (monitor rotation, default: none)
#   ROTATE_OUT  - X output name for rotation, e.g. HDMI-1 (auto-detected)
#   SSH_KEYS_URL- URL of a public-key list refreshed hourly
#                 (default: this repo's ssh-keys.txt)
#===============================================================================
set -euo pipefail

log()  { echo -e "\e[1;32m[kiosk]\e[0m $*"; }
warn() { echo -e "\e[1;33m[kiosk]\e[0m $*"; }
die()  { echo -e "\e[1;31m[kiosk]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"

# When piped via curl, stdin is the script itself - read prompts from the terminal
TTY=/dev/tty
[[ -e $TTY && -r $TTY ]] || TTY=/dev/stdin

ask() { # ask VAR "Prompt" "default"
  local var=$1 prompt=$2 def=${3:-}
  if [[ -z "${!var:-}" ]]; then
    local input=""
    if [[ -n $def ]]; then
      read -rp "$prompt [$def]: " input < "$TTY"
      printf -v "$var" '%s' "${input:-$def}"
    else
      while [[ -z $input ]]; do read -rp "$prompt: " input < "$TTY"; done
      printf -v "$var" '%s' "$input"
    fi
  fi
}

SCRIPT_BASE_URL=${SCRIPT_BASE_URL:-https://raw.githubusercontent.com/mhenson-ejt/ubuntu-displayscreen/main}
SCRIPT_BASE_URL=${SCRIPT_BASE_URL%/}
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "")

fetch_file() { # fetch_file <repo-relative-path> <dest> <mode>
  local rel=$1 dest=$2 mode=$3
  if [[ -n $SCRIPT_DIR && -f $SCRIPT_DIR/$rel ]]; then
    install -m "$mode" "$SCRIPT_DIR/$rel" "$dest"
  else
    local tmp; tmp=$(mktemp)
    curl -fsSL "$SCRIPT_BASE_URL/$rel" -o "$tmp" || die "Failed to download $SCRIPT_BASE_URL/$rel"
    install -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
  fi
}

#--- Mode selection ------------------------------------------------------------
STANDALONE=${STANDALONE:-}
MANAGER_URL=${MANAGER_URL:-}
if [[ -z $STANDALONE && -z $MANAGER_URL ]]; then
  echo "Install modes:"
  echo "  managed    - central display manager drives this screen (recommended)"
  echo "  standalone - all settings configured here, on this box"
  read -rp "Manager URL (e.g. http://10.0.40.5:5000; leave blank for standalone): " MANAGER_URL < "$TTY"
fi
if [[ -n $STANDALONE || -z $MANAGER_URL ]]; then MODE=standalone; else MODE=managed; fi
log "Install mode: $MODE"

#--- Gather common configuration -----------------------------------------------
KIOSK_USER=${KIOSK_USER:-}
ask KIOSK_USER "Kiosk user (runs the display)" "viewer"
id "$KIOSK_USER" &>/dev/null || die "User '$KIOSK_USER' does not exist. Create it first: sudo adduser $KIOSK_USER"
KIOSK_HOME=$(getent passwd "$KIOSK_USER" | cut -d: -f6)

if [[ $MODE == managed ]]; then
  MANAGER_URL=${MANAGER_URL%/}
  ENROLL_TOKEN=${ENROLL_TOKEN:-}
  ask ENROLL_TOKEN "Enrollment token (manager Settings page)"
fi

if [[ $MODE == standalone ]]; then
  NVR_IP=${NVR_IP:-};     ask NVR_IP   "Dahua NVR IP address"
  NVR_PORT=${NVR_PORT:-}; ask NVR_PORT "NVR RTSP port" "554"
  [[ $NVR_PORT =~ ^[0-9]+$ ]] || die "NVR_PORT must be numeric"
  NVR_USER=${NVR_USER:-}; ask NVR_USER "NVR username (live-view rights)" "viewer"
  if [[ -z "${NVR_PASS:-}" ]]; then
    read -rsp "NVR password: " NVR_PASS < "$TTY"; echo
    [[ -n $NVR_PASS ]] || die "Password cannot be empty."
  fi

  LAYOUT=${LAYOUT:-}
  if [[ -z $LAYOUT ]]; then
    echo "Layouts:  1 = single camera fullscreen"
    echo "          2h = 2 cameras side-by-side (landscape monitor)"
    echo "          2v = 2 cameras stacked (portrait monitor)"
    echo "          4  = 2x2 grid"
    ask LAYOUT "Layout" "4"
  fi
  case $LAYOUT in 1|2h|2v|4) ;; *) die "LAYOUT must be one of: 1 2h 2v 4" ;; esac

  case $LAYOUT in
    1) NEED=1 ;;
    2h|2v) NEED=2 ;;
    4) NEED=4 ;;
  esac
  CHANNELS=${CHANNELS:-}
  ask CHANNELS "NVR channel numbers, space-separated ($NEED needed)" "$(seq -s' ' 1 $NEED)"
  read -ra CH <<< "$CHANNELS"
  [[ ${#CH[@]} -eq $NEED ]] || die "Layout '$LAYOUT' needs exactly $NEED channels, got ${#CH[@]}."
  for c in "${CH[@]}"; do [[ $c =~ ^[0-9]+$ ]] || die "Channel '$c' is not a number."; done

  SUBTYPE=${SUBTYPE:-1}
  if [[ $LAYOUT != 1 && $SUBTYPE != 1 ]]; then
    warn "Grid layouts should use substreams; forcing SUBTYPE=1."
    SUBTYPE=1
  fi

  ROTATE=${ROTATE:-}
  if [[ $LAYOUT == 2v ]]; then ask ROTATE "Rotate monitor (left/right/none)" "right"
  else ask ROTATE "Rotate monitor (left/right/none)" "none"; fi
  case $ROTATE in none|left|right) ;; *) die "ROTATE must be none, left or right" ;; esac
  ROTATE_OUT=${ROTATE_OUT:-}
fi

#--- Install packages ----------------------------------------------------------
log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  xorg xinit x11-xserver-utils xserver-xorg-legacy mpv i965-va-driver vainfo \
  openssh-server curl ca-certificates jq wpasupplicant

#--- Groups & X wrapper --------------------------------------------------------
log "Configuring user groups and X permissions..."
usermod -aG render,video "$KIOSK_USER"

cat > /etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

#--- Remove legacy autologin setup (pre-manager installs) ----------------------
if [[ -f /etc/systemd/system/getty@tty1.service.d/autologin.conf ]]; then
  log "Removing legacy tty1 autologin (replaced by kiosk-display.service)..."
  rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
  rmdir --ignore-fail-on-non-empty /etc/systemd/system/getty@tty1.service.d
fi
PROFILE="$KIOSK_HOME/.bash_profile"
if [[ -f $PROFILE ]] && grep -q "# kiosk-autostart" "$PROFILE"; then
  log "Removing legacy startx hook from .bash_profile..."
  sed -i '/# kiosk-autostart/,/^fi$/d' "$PROFILE"
fi

#--- /etc/kiosk base -----------------------------------------------------------
mkdir -p /etc/kiosk
cat > /etc/kiosk/kiosk.conf <<EOF
KIOSK_USER=$KIOSK_USER
KIOSK_HOME=$KIOSK_HOME
EOF

log "Installing display loop and display service..."
# cams.sh re-reads /etc/kiosk/config.json on every mpv respawn, so config
# changes only need mpv killed - no X restart. Contains no secrets itself,
# but only root and the kiosk user get to run it.
fetch_file agent/kiosk-cams /etc/kiosk/cams.sh 750
chown "root:$KIOSK_USER" /etc/kiosk/cams.sh
fetch_file agent/kiosk-display.service /etc/systemd/system/kiosk-display.service 644
sed -i "s/@KIOSK_USER@/$KIOSK_USER/" /etc/systemd/system/kiosk-display.service

# Upgrade hygiene: the generated-cams.sh approach is gone
rm -f /usr/local/sbin/kiosk-render-cams
if [[ -f /etc/kiosk/config.json ]]; then
  chown "root:$KIOSK_USER" /etc/kiosk/config.json
  chmod 640 /etc/kiosk/config.json
fi

#--- WiFi (both modes) ----------------------------------------------------------
# kiosk-apply-wifi keeps WiFi permanently configured at a worse route metric
# than wired, so wired is used whenever a cable is connected and WiFi covers
# everything else (including WiFi-only screens). In managed mode the agent
# re-applies whatever the manager distributes; WIFI_SSID here just gets a
# WiFi-only screen onto the network for its first sync.
log "Installing WiFi helper..."
fetch_file agent/kiosk-apply-wifi /usr/local/sbin/kiosk-apply-wifi 755

if [[ -n ${WIFI_SSID:-} ]]; then
  log "Configuring WiFi (\"$WIFI_SSID\")..."
  /usr/local/sbin/kiosk-apply-wifi "$WIFI_SSID" "${WIFI_PASS:-}" \
    || warn "WiFi configuration failed - continuing (wired still works; fix and re-run kiosk-apply-wifi)"
fi

#--- SSH key updater (both modes) ----------------------------------------------
# Managed mode: the agent calls it with a key file fetched from the manager.
# Standalone mode: an hourly timer calls it with no args -> fetches from URL.
SSH_KEYS_URL=${SSH_KEYS_URL:-$SCRIPT_BASE_URL/ssh-keys.txt}
[[ $MODE == managed ]] && UPDATER_URL="" || UPDATER_URL=$SSH_KEYS_URL

log "Installing SSH key updater..."
cat > /usr/local/sbin/kiosk-update-ssh-keys <<EOF
#!/bin/bash
# Generated by kiosk-setup.sh - rewrites the managed block in the kiosk
# user's authorized_keys. Keys outside the markers are left alone.
# Usage: kiosk-update-ssh-keys [keyfile]   (no arg: fetch from \$URL)
# If the source yields no valid keys, authorized_keys is left unchanged.
set -euo pipefail
URL="$UPDATER_URL"
KEY_USER="$KIOSK_USER"
AK_DIR="$KIOSK_HOME/.ssh"
EOF
cat >> /usr/local/sbin/kiosk-update-ssh-keys <<'EOF'
AK="$AK_DIR/authorized_keys"
BEGIN="# >>> kiosk-managed-keys (do not edit between markers) >>>"
END="# <<< kiosk-managed-keys <<<"

TMP=$(mktemp)
trap 'rm -f "$TMP" "$TMP.keys" "$TMP.new"' EXIT

if [[ -n ${1:-} ]]; then
  cp "$1" "$TMP"
elif [[ -n $URL ]]; then
  curl -fsSL --max-time 30 "$URL" -o "$TMP"
else
  echo "kiosk-update-ssh-keys: no key file argument and no URL configured" >&2
  exit 1
fi

grep -E '^(ssh|ecdsa|sk)-[A-Za-z0-9@.-]+ [A-Za-z0-9+/=]+' "$TMP" > "$TMP.keys" || true
if [[ ! -s "$TMP.keys" ]]; then
  echo "kiosk-update-ssh-keys: no valid keys in source - authorized_keys left unchanged" >&2
  exit 1
fi

install -d -m 700 -o "$KEY_USER" -g "$KEY_USER" "$AK_DIR"
touch "$AK"
awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$AK" > "$TMP.new"
{ echo "$BEGIN"; cat "$TMP.keys"; echo "$END"; } >> "$TMP.new"
install -m 600 -o "$KEY_USER" -g "$KEY_USER" "$TMP.new" "$AK"
echo "kiosk-update-ssh-keys: installed $(wc -l < "$TMP.keys") key(s) for $KEY_USER"
EOF
chmod 755 /usr/local/sbin/kiosk-update-ssh-keys

#===============================================================================
if [[ $MODE == managed ]]; then
  #--- Managed mode ------------------------------------------------------------
  log "Configuring managed mode (manager: $MANAGER_URL)..."

  cat > /etc/kiosk/agent.env <<EOF
MANAGER_URL=$MANAGER_URL
ENROLL_TOKEN=$ENROLL_TOKEN
EOF
  chmod 600 /etc/kiosk/agent.env

  fetch_file agent/kiosk-agent /usr/local/sbin/kiosk-agent 755
  fetch_file agent/kiosk-trigger /usr/local/sbin/kiosk-trigger 755
  fetch_file agent/kiosk-agent.service /etc/systemd/system/kiosk-agent.service 644

  # Instant sync: the manager SSHes in as $KIOSK_USER and may run exactly one
  # command as root - the sync trigger. Validated before install so a bad rule
  # can never break sudo.
  # (cams.sh waits for config.json by itself, so no placeholder is needed.)
  log "Installing sudoers rule for instant sync..."
  TMPS=$(mktemp)
  cat > "$TMPS" <<EOF
Defaults!/usr/local/sbin/kiosk-trigger env_keep += "SSH_ORIGINAL_COMMAND"
$KIOSK_USER ALL=(root) NOPASSWD: /usr/local/sbin/kiosk-trigger
EOF
  visudo -cf "$TMPS" >/dev/null || die "Generated sudoers rule failed validation"
  install -m 440 -o root -g root "$TMPS" /etc/sudoers.d/kiosk-trigger
  rm -f "$TMPS"

  # Upgrade hygiene: earlier agent versions put the manager key in root's
  # authorized_keys; it now lives with the kiosk user. Remove the old block
  # and force the agent to re-apply the key on its next poll.
  if [[ -f /root/.ssh/authorized_keys ]] && grep -q "kiosk-manager-key" /root/.ssh/authorized_keys; then
    sed -i '/# >>> kiosk-manager-key/,/# <<< kiosk-manager-key/d' /root/.ssh/authorized_keys
  fi
  rm -f /etc/kiosk/applied-managerkey-version

  # The manager supersedes the GitHub-hosted key list timer
  systemctl disable --now kiosk-ssh-keys.timer 2>/dev/null || true
  rm -f /etc/systemd/system/kiosk-ssh-keys.service /etc/systemd/system/kiosk-ssh-keys.timer

  systemctl daemon-reload
  systemctl disable getty@tty1.service 2>/dev/null || true
  systemctl enable kiosk-agent kiosk-display
  # restart (not enable --now): on upgrade re-runs the services are already
  # running old code and must pick up the freshly installed files
  systemctl restart kiosk-agent kiosk-display

  log "Waiting for registration with the manager (up to 60s)..."
  REGISTERED=""
  for _ in $(seq 1 30); do
    if grep -q '^API_TOKEN=' /etc/kiosk/agent.env 2>/dev/null; then REGISTERED=1; break; fi
    sleep 2
  done
  if [[ -n $REGISTERED ]]; then
    log "Registered with the manager as '$(hostname)'."
  else
    warn "Not registered yet - check: journalctl -u kiosk-agent -f  (wrong enroll token? manager unreachable?)"
  fi
else
  #--- Standalone mode ---------------------------------------------------------
  log "Writing /etc/kiosk/config.json ..."
  case $LAYOUT in
    1)  GRID_COLS=1; GRID_ROWS=1 ;;
    2h) GRID_COLS=2; GRID_ROWS=1 ;;
    2v) GRID_COLS=1; GRID_ROWS=2 ;;
    4)  GRID_COLS=2; GRID_ROWS=2 ;;
  esac
  TILES_JSON=$(
    i=0
    for c in "${CH[@]}"; do
      jq -n --argjson pos "$i" --arg ip "$NVR_IP" --argjson port "$NVR_PORT" \
            --arg user "$NVR_USER" --arg pass "$NVR_PASS" --argjson ch "$c" \
            '{pos: $pos, ip: $ip, port: $port, user: $user, pass: $pass, channel: $ch}'
      i=$((i + 1))
    done | jq -cs .
  )
  jq -n --argjson cols "$GRID_COLS" --argjson rows "$GRID_ROWS" \
        --argjson subtype "$SUBTYPE" --arg rotate "$ROTATE" --arg rout "${ROTATE_OUT:-}" \
        --argjson tiles "$TILES_JSON" \
        '{version: 0, gridCols: $cols, gridRows: $rows, subtype: $subtype, rotate: $rotate,
          rotateOutput: (if $rout == "" then null else $rout end), tiles: $tiles}' \
        > /etc/kiosk/config.json
  chown "root:$KIOSK_USER" /etc/kiosk/config.json
  chmod 640 /etc/kiosk/config.json

  # Hourly SSH key refresh from the repo's ssh-keys.txt
  log "Installing SSH key refresh timer (source: $SSH_KEYS_URL)..."
  cat > /etc/systemd/system/kiosk-ssh-keys.service <<'EOF'
[Unit]
Description=Refresh kiosk SSH authorized keys from the shared key list
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kiosk-update-ssh-keys
EOF

  cat > /etc/systemd/system/kiosk-ssh-keys.timer <<'EOF'
[Unit]
Description=Hourly refresh of kiosk SSH authorized keys

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl disable getty@tty1.service 2>/dev/null || true
  systemctl enable kiosk-ssh-keys.timer kiosk-display
  # restart (not enable --now): upgrade re-runs must load freshly installed files
  systemctl restart kiosk-ssh-keys.timer kiosk-display

  /usr/local/sbin/kiosk-update-ssh-keys \
    || warn "Initial SSH key import failed - check $SSH_KEYS_URL (timer retries hourly)."
fi

#--- Verify VAAPI (informational only) -----------------------------------------
if LIBVA_DRIVER_NAME=i965 vainfo --display drm --device /dev/dri/renderD128 2>/dev/null | grep -q VAProfileH264; then
  log "VAAPI H.264 hardware decode: OK"
else
  warn "Could not confirm VAAPI H.264 decode - check 'vainfo --display drm --device /dev/dri/renderD128' manually."
fi

#--- Done ----------------------------------------------------------------------
log "Setup complete."
echo
if [[ $MODE == managed ]]; then
  echo "  Mode     : managed by $MANAGER_URL"
  echo "  Configure layout/NVR/SSH keys for this screen in the manager UI."
  echo "  Display  : systemctl status kiosk-display   Agent: journalctl -u kiosk-agent -f"
else
  echo "  Mode     : standalone"
  echo "  Layout   : $LAYOUT   Channels: ${CH[*]}   Subtype: $SUBTYPE"
  echo "  NVR      : $NVR_IP:$NVR_PORT (user: $NVR_USER)"
  echo "  Rotation : $ROTATE"
  echo "  SSH keys : $SSH_KEYS_URL (refreshed hourly)"
  echo "  Config   : /etc/kiosk/config.json (edit + 'pkill mpv' to apply)"
fi
echo
echo "Reminders:"
echo "  - BIOS: set 'After Power Failure' = Power On (F2 at boot)"
echo "  - NVR : substreams set to H.264, identical resolutions across channels"
echo
read -rp "Reboot now (recommended for a clean first start)? [y/N]: " R < "$TTY" || R=n
[[ ${R,,} == y ]] && reboot || log "Run 'sudo reboot' when ready."
