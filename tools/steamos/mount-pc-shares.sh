#!/bin/bash
# Mount the PC's shared folders on a SteamOS device (Steam Deck, ROG Ally ...)
# so emulators and game launchers can use them like local folders.
#
#   ./mount-pc-shares.sh            set up (asks for passwords once) and mount
#   ./mount-pc-shares.sh status     show what is mounted
#   ./mount-pc-shares.sh remove     undo everything
#
# Each share appears under ~/PC/<name>. It mounts on first access and is
# skipped quietly when the PC is off, so it never slows down booting.
# Needs a sudo password for the "deck" user (set one with: passwd).
# Survives SteamOS updates (only /etc and your home folder are changed).

PC="192.168.1.103"

# name | port | login (windows = your Microsoft account, linux = the Samba
#                      user shown by Double Commander when you share a Linux partition)
SHARES=(
  "O-HyperSpin|445|windows"
  "L-PS2|445|windows"
  "Wii-NTSC-U|445|windows"
  "CoinOPS|445|windows"
  "Batocera-924G|4450|linux"
)

BASE="$HOME/PC"
CRED_DIR="$HOME/.config/pc-shares"
UNIT_TAG="pc-shares"
set -u

say() { printf '\033[1m%s\033[0m\n' "$*"; }

unit_name() {  # mount path -> systemd unit name
  systemd-escape -p --suffix="$2" "$1"
}

ask_credentials() {
  mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"
  if [ ! -f "$CRED_DIR/windows.cred" ]; then
    say "Windows shares: sign in with your Microsoft account"
    read -rp "  Microsoft account email: " email
    read -rsp "  Microsoft account password: " pw; echo
    printf 'username=%s\npassword=%s\ndomain=MicrosoftAccount\n' "$email" "$pw" > "$CRED_DIR/windows.cred"
  fi
  if [ ! -f "$CRED_DIR/linux.cred" ]; then
    say "Linux (Batocera) share: user 'games' (password shown by Double Commander when sharing)"
    read -rsp "  Password for 'games': " pw; echo
    printf 'username=games\npassword=%s\n' "$pw" > "$CRED_DIR/linux.cred"
  fi
  chmod 600 "$CRED_DIR"/*.cred
}

install() {
  command -v mount.cifs >/dev/null || { echo "mount.cifs is missing on this system (package cifs-utils)."; exit 1; }
  say "Administrator (sudo) password needed to add the mounts:"
  sudo -v || exit 1
  ask_credentials
  for entry in "${SHARES[@]}"; do
    IFS='|' read -r name port login <<< "$entry"
    dir="$BASE/$name"
    mkdir -p "$dir"
    mnt=$(unit_name "$dir" mount)
    auto=$(unit_name "$dir" automount)
    sudo tee "/etc/systemd/system/$mnt" > /dev/null <<EOF
# $UNIT_TAG
[Unit]
Description=PC share $name
After=network-online.target
Wants=network-online.target

[Mount]
What=//$PC/$name
Where=$dir
Type=cifs
Options=credentials=$CRED_DIR/$login.cred,port=$port,uid=$(id -u),gid=$(id -g),iocharset=utf8,vers=3.0,nofail,_netdev,soft,echo_interval=10
TimeoutSec=15
EOF
    sudo tee "/etc/systemd/system/$auto" > /dev/null <<EOF
# $UNIT_TAG
[Unit]
Description=PC share $name (mounted on first use)

[Automount]
Where=$dir
TimeoutIdleSec=600

[Install]
WantedBy=multi-user.target
EOF
  done
  sudo systemctl daemon-reload
  for entry in "${SHARES[@]}"; do
    IFS='|' read -r name port login <<< "$entry"
    sudo systemctl enable --now "$(unit_name "$BASE/$name" automount)" >/dev/null 2>&1
  done
  status
}

status() {
  say "PC shares (in $BASE):"
  for entry in "${SHARES[@]}"; do
    IFS='|' read -r name port login <<< "$entry"
    if timeout 20 ls "$BASE/$name" > /dev/null 2>&1; then
      printf '  %-16s OK   (%s items)\n' "$name" "$(ls "$BASE/$name" | wc -l)"
    else
      printf '  %-16s not reachable (PC off? not shared right now? wrong password?)\n' "$name"
    fi
  done
}

remove() {
  sudo -v || exit 1
  for entry in "${SHARES[@]}"; do
    IFS='|' read -r name port login <<< "$entry"
    dir="$BASE/$name"
    sudo systemctl disable --now "$(unit_name "$dir" automount)" >/dev/null 2>&1
    sudo systemctl stop "$(unit_name "$dir" mount)" >/dev/null 2>&1
    sudo rm -f "/etc/systemd/system/$(unit_name "$dir" automount)" "/etc/systemd/system/$(unit_name "$dir" mount)"
    rmdir "$dir" 2>/dev/null
  done
  sudo systemctl daemon-reload
  rm -rf "$CRED_DIR"
  rmdir "$BASE" 2>/dev/null
  say "Removed."
}

case "${1:-install}" in
  install) install ;;
  status)  status ;;
  remove)  remove ;;
  *) echo "usage: $0 [install|status|remove]"; exit 1 ;;
esac
