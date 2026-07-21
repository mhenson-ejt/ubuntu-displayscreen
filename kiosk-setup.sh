#!/bin/bash
#===============================================================================
# Dahua NVR Camera Kiosk - One-line installer
#
# Sets up an Ubuntu Server machine (tested: Intel NUC5i5RYH, Ubuntu 24.04) to
# boot straight into fullscreen mpv display of RTSP streams from a Dahua NVR.
#
# Usage (interactive):
#   curl -fsSL https://YOUR_HOST/kiosk-setup.sh | sudo bash
#   or:  sudo bash kiosk-setup.sh
#
# Usage (non-interactive, e.g. for scripted rollout):
#   sudo NVR_IP=192.168.1.108 NVR_USER=viewer NVR_PASS='secret' \
#        LAYOUT=2h CHANNELS="1 2" KIOSK_USER=viewer bash kiosk-setup.sh
#
# Env vars / prompts:
#   KIOSK_USER  - local user that autologins and runs the display (default: viewer)
#   NVR_IP      - IP address of the Dahua NVR
#   NVR_PORT    - RTSP port (default: 554)
#   NVR_USER    - NVR username with live-view rights
#   NVR_PASS    - NVR password (special characters are auto URL-encoded)
#   LAYOUT      - 1 | 2h | 2v | 4  (single / 2 side-by-side / 2 stacked / 2x2 grid)
#   CHANNELS    - space-separated NVR channel numbers, e.g. "1 2 3 4"
#   SUBTYPE     - 0 main stream, 1 substream (default: 1; forced 1 for grids)
#   ROTATE      - none | left | right  (monitor rotation, default: none)
#   ROTATE_OUT  - X output name for rotation, e.g. HDMI-1 (auto-detected if blank)
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

#--- Gather configuration ------------------------------------------------------
KIOSK_USER=${KIOSK_USER:-}
ask KIOSK_USER "Kiosk user (will autologin on tty1)" "viewer"
id "$KIOSK_USER" &>/dev/null || die "User '$KIOSK_USER' does not exist. Create it first: sudo adduser $KIOSK_USER"
KIOSK_HOME=$(getent passwd "$KIOSK_USER" | cut -d: -f6)

NVR_IP=${NVR_IP:-};     ask NVR_IP   "Dahua NVR IP address"
NVR_PORT=${NVR_PORT:-}; ask NVR_PORT "NVR RTSP port" "554"
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

#--- URL-encode the password ---------------------------------------------------
urlencode() {
  local s=$1 out="" c
  for (( i=0; i<${#s}; i++ )); do
    c=${s:$i:1}
    case $c in [a-zA-Z0-9.~_-]) out+=$c ;; *) printf -v hex '%%%02X' "'$c"; out+=$hex ;; esac
  done
  echo "$out"
}
NVR_PASS_ENC=$(urlencode "$NVR_PASS")

#--- Install packages ----------------------------------------------------------
log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  xorg xinit x11-xserver-utils xserver-xorg-legacy mpv i965-va-driver vainfo

#--- Groups & X wrapper --------------------------------------------------------
log "Configuring user groups and X permissions..."
usermod -aG render,video "$KIOSK_USER"

cat > /etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

#--- Autologin on tty1 ---------------------------------------------------------
log "Configuring autologin for '$KIOSK_USER' on tty1..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF
systemctl daemon-reload

#--- Generate cams.sh ----------------------------------------------------------
log "Writing $KIOSK_HOME/cams.sh ..."

ROTATE_LINE="# no rotation"
if [[ $ROTATE != none ]]; then
  if [[ -n $ROTATE_OUT ]]; then
    ROTATE_LINE="xrandr --output $ROTATE_OUT --rotate $ROTATE"
  else
    # Auto-detect the first connected output at runtime
    ROTATE_LINE='OUT=$(xrandr | awk '"'"'/ connected/{print $1; exit}'"'"'); xrandr --output "$OUT" --rotate '"$ROTATE"
  fi
fi

URLBASE="rtsp://${NVR_USER}:${NVR_PASS_ENC}@${NVR_IP}:${NVR_PORT}/cam/realmonitor"

MPV_COMMON='--fs --no-osc --no-input-default-bindings --really-quiet \
      --hwdec=auto --profile=low-latency --rtsp-transport=tcp'

case $LAYOUT in
  1)
    MPV_CMD="mpv $MPV_COMMON \\
      \"\${URL}?channel=${CH[0]}&subtype=${SUBTYPE}\""
    ;;
  2h)
    MPV_CMD="mpv $MPV_COMMON \\
      --lavfi-complex=\"[vid1][vid2]hstack[vo]\" \\
      --external-file=\"\${URL}?channel=${CH[1]}&subtype=${SUBTYPE}\" \\
      \"\${URL}?channel=${CH[0]}&subtype=${SUBTYPE}\""
    ;;
  2v)
    MPV_CMD="mpv $MPV_COMMON \\
      --lavfi-complex=\"[vid1][vid2]vstack[vo]\" \\
      --external-file=\"\${URL}?channel=${CH[1]}&subtype=${SUBTYPE}\" \\
      \"\${URL}?channel=${CH[0]}&subtype=${SUBTYPE}\""
    ;;
  4)
    MPV_CMD="mpv $MPV_COMMON \\
      --lavfi-complex=\"[vid1][vid2]hstack[top];[vid3][vid4]hstack[bottom];[top][bottom]vstack[vo]\" \\
      --external-file=\"\${URL}?channel=${CH[1]}&subtype=${SUBTYPE}\" \\
      --external-file=\"\${URL}?channel=${CH[2]}&subtype=${SUBTYPE}\" \\
      --external-file=\"\${URL}?channel=${CH[3]}&subtype=${SUBTYPE}\" \\
      \"\${URL}?channel=${CH[0]}&subtype=${SUBTYPE}\""
    ;;
esac

cat > "$KIOSK_HOME/cams.sh" <<EOF
#!/bin/bash
# Generated by kiosk-setup.sh on $(date -Iseconds)
export LIBVA_DRIVER_NAME=i965

xset s off
xset -dpms
xset s noblank

$ROTATE_LINE

URL="$URLBASE"

while true; do
  $MPV_CMD
  sleep 3
done
EOF
chmod 755 "$KIOSK_HOME/cams.sh"
chown "$KIOSK_USER:" "$KIOSK_HOME/cams.sh"

#--- .bash_profile hook --------------------------------------------------------
log "Adding startx hook to $KIOSK_HOME/.bash_profile ..."
PROFILE="$KIOSK_HOME/.bash_profile"
MARK="# kiosk-autostart"
touch "$PROFILE"; chown "$KIOSK_USER:" "$PROFILE"
if ! grep -q "$MARK" "$PROFILE"; then
  cat >> "$PROFILE" <<EOF

$MARK
if [[ -z \$DISPLAY && \$(tty) == /dev/tty1 ]]; then
  exec startx $KIOSK_HOME/cams.sh -- -nocursor
fi
EOF
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
echo "  Layout   : $LAYOUT   Channels: ${CH[*]}   Subtype: $SUBTYPE"
echo "  NVR      : $NVR_IP:$NVR_PORT (user: $NVR_USER)"
echo "  Rotation : $ROTATE"
echo "  Script   : $KIOSK_HOME/cams.sh"
echo
echo "Reminders:"
echo "  - BIOS: set 'After Power Failure' = Power On (F2 at boot)"
echo "  - NVR : substreams set to H.264, identical resolutions across channels"
echo
read -rp "Reboot now to start the kiosk? [y/N]: " R < "$TTY" || R=n
[[ ${R,,} == y ]] && reboot || log "Run 'sudo reboot' when ready."
