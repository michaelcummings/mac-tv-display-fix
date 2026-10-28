#!/bin/bash
# fix-tv-display.sh — fix an external monitor that macOS treats as a TV and leaves blank.
#
# Symptom: the monitor is connected and gets a signal, but stays black and never shows
# up as a display. macOS 15 decided the monitor is a TV, the "When connected to TV"
# setting is "Ask What to Show", the prompt never appears, and Control Center covers
# the screen with a blank shield window. macOS then saves that state in its display
# layouts (the display is marked IndependentOutput) and reapplies it on every connect
# and restart, so changing the setting alone does not help.
#
# Fix: set "When connected to TV" to "Use as Extended Display" and delete the saved
# layouts that mark a display IndependentOutput, then restart. Uses only tools that
# ship with macOS (defaults, plutil, log). Everything is backed up first.
#
# Usage:
#   ./fix-tv-display.sh                 check only, changes nothing
#   ./fix-tv-display.sh --apply         back up, fix, then restart the Mac yourself
#   ./fix-tv-display.sh --restore DIR   put back the settings saved in backup folder DIR
#
# Tested on macOS 15.7.3 (Apple Silicon) with an InnoView 23.8" 4K monitor.

set -euo pipefail

DOMAIN="com.apple.windowserver.displays"
SYSTEM_DOMAIN="/Library/Preferences/$DOMAIN"
# Value macOS 15.7.3 stores when you pick "Use as Extended Display"; 0 is "Ask What to Show".
EXTENDED_POLICY=4

# Test hook: point at a folder holding user.plist and system.plist to run against copies
# instead of the live settings. No sudo, no restart advice.
SANDBOX="${FIX_TV_DISPLAY_SANDBOX:-}"

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

export_user() {
  if [ -n "$SANDBOX" ]; then cp "$SANDBOX/user.plist" "$1"; else defaults -currentHost export "$DOMAIN" "$1"; fi
}
export_system() {
  if [ -n "$SANDBOX" ]; then cp "$SANDBOX/system.plist" "$1"; else defaults export "$SYSTEM_DOMAIN" "$1"; fi
}
import_user() {
  if [ -n "$SANDBOX" ]; then cp "$1" "$SANDBOX/user.plist"; else defaults -currentHost import "$DOMAIN" "$1"; fi
}
import_system() {
  if [ -n "$SANDBOX" ]; then cp "$1" "$SANDBOX/system.plist"; else sudo defaults import "$SYSTEM_DOMAIN" "$1"; fi
}

# The user file keeps layouts under DisplaySets, the system file under DisplayAnyUserSets.
sets_key() {
  local key
  for key in DisplaySets DisplayAnyUserSets; do
    if plutil -extract "$key.Configs" raw -o - "$1" >/dev/null 2>&1; then echo "$key"; return; fi
  done
  echo ""
}

# Print "index<TAB>description" for every saved layout with an IndependentOutput display,
# highest index first so callers can delete in that order without shifting the rest.
independent_layouts() {
  local file="$1" key n i m j flag uuid wide high hz
  key=$(sets_key "$file")
  [ -n "$key" ] || return 0
  n=$(plutil -extract "$key.Configs" raw -o - "$file")
  for ((i = n - 1; i >= 0; i--)); do
    m=$(plutil -extract "$key.Configs.$i.DisplayConfig" raw -o - "$file" 2>/dev/null) || continue
    for ((j = 0; j < m; j++)); do
      flag=$(plutil -extract "$key.Configs.$i.DisplayConfig.$j.IndependentOutput" raw -o - "$file" 2>/dev/null) || continue
      [ "$flag" = "true" ] || continue
      uuid=$(plutil -extract "$key.Configs.$i.DisplayConfig.$j.UUID" raw -o - "$file" 2>/dev/null || echo "?")
      wide=$(plutil -extract "$key.Configs.$i.DisplayConfig.$j.CurrentInfo.Wide" raw -o - "$file" 2>/dev/null || echo "?")
      high=$(plutil -extract "$key.Configs.$i.DisplayConfig.$j.CurrentInfo.High" raw -o - "$file" 2>/dev/null || echo "?")
      hz=$(plutil -extract "$key.Configs.$i.DisplayConfig.$j.CurrentInfo.Hz" raw -o - "$file" 2>/dev/null || echo "?")
      printf '%s\tlayout %s: display %s (%sx%s @ %sHz) marked IndependentOutput\n' "$i" "$i" "$uuid" "${wide%.*}" "${high%.*}" "${hz%.*}"
      break
    done
  done
}

strip_layouts() {
  local file="$1" key idx
  key=$(sets_key "$file")
  [ -n "$key" ] || return 0
  independent_layouts "$file" | cut -f1 | while read -r idx; do
    plutil -remove "$key.Configs.$idx" "$file"
  done
}

tv_policy() {
  plutil -extract TVConnectPolicy raw -o - "$1" 2>/dev/null || echo "unset"
}

check() {
  local tmp user_file sys_file policy found=0
  tmp=$(mktemp -d)
  user_file="$tmp/user.plist"; sys_file="$tmp/system.plist"
  export_user "$user_file"
  export_system "$sys_file" 2>/dev/null || warn "could not read $SYSTEM_DOMAIN"

  say "macOS $(sw_vers -productVersion)"
  if [ -z "$SANDBOX" ]; then
    say ""
    say "Displays macOS is using right now:"
    system_profiler SPDisplaysDataType 2>/dev/null | awk '/Displays:/{on=1; next} on && /^        [^ ].*:$/{sub(/^ +/, "  "); print}'
    local shields
    shields=$(/usr/bin/log show --last 1h --style compact \
      --predicate 'subsystem == "com.apple.controlcenter" AND category == "offlineDisplays"' 2>/dev/null \
      | grep -c 'Creating shield window' || true)
    say ""
    say "Control Center blanked a display (shield window) $shields time(s) in the last hour."
  fi

  policy=$(tv_policy "$user_file")
  say ""
  case "$policy" in
    "$EXTENDED_POLICY") say "\"When connected to TV\": Use as Extended Display (TVConnectPolicy $policy). OK." ;;
    0)                  say "\"When connected to TV\": Ask What to Show (TVConnectPolicy 0). This triggers the bug."; found=1 ;;
    *)                  say "\"When connected to TV\": TVConnectPolicy $policy (not Use as Extended Display)."; found=1 ;;
  esac

  say ""
  say "Saved layouts holding a display as IndependentOutput (the blank-screen state):"
  local lines
  lines=$(independent_layouts "$user_file" | cut -f2)
  if [ -n "$lines" ]; then say "  your settings:"; say "$lines" | sed 's/^/    /'; found=1; fi
  if [ -f "$sys_file" ]; then
    lines=$(independent_layouts "$sys_file" | cut -f2)
    if [ -n "$lines" ]; then say "  system settings:"; say "$lines" | sed 's/^/    /'; found=1; fi
  fi
  [ "$found" = 1 ] || say "  none"

  rm -rf "$tmp"
  say ""
  if [ "$found" = 1 ]; then
    say "Run again with --apply to fix this."
  else
    say "Nothing to fix here. If a monitor is still blank, check the cable (it must carry video)."
  fi
}

apply() {
  local backup user_file sys_file need_sys=0
  backup="$HOME/Desktop/display-settings-backup-$(date +%Y%m%d-%H%M%S)"
  [ -n "$SANDBOX" ] && backup="$SANDBOX/backup"
  mkdir -p "$backup"
  export_user "$backup/user.plist"
  export_system "$backup/system.plist" || die "could not read $SYSTEM_DOMAIN"
  say "Backed up current settings to $backup"

  user_file="$backup/user-fixed.plist"; sys_file="$backup/system-fixed.plist"
  cp "$backup/user.plist" "$user_file"; cp "$backup/system.plist" "$sys_file"

  strip_layouts "$user_file"
  plutil -replace TVConnectPolicy -integer "$EXTENDED_POLICY" "$user_file"
  import_user "$user_file"
  say "Your settings: \"When connected to TV\" set to Use as Extended Display; IndependentOutput layouts removed."

  if [ -n "$(independent_layouts "$sys_file")" ]; then need_sys=1; fi
  if [ "$need_sys" = 1 ]; then
    strip_layouts "$sys_file"
    say "The system-wide copy also has IndependentOutput layouts. Your admin password is needed to fix it."
    import_system "$sys_file" || die "system settings not changed; rerun to try again"
    say "System settings: IndependentOutput layouts removed."
  fi

  # Confirm the changes stuck.
  export_user "$backup/user-after.plist"
  [ "$(tv_policy "$backup/user-after.plist")" = "$EXTENDED_POLICY" ] || die "TV policy did not save"
  [ -z "$(independent_layouts "$backup/user-after.plist")" ] || die "layouts were not removed from your settings"

  say ""
  if [ -z "$SANDBOX" ]; then
    say "Done. Now restart the Mac (Apple menu > Restart) with the monitor plugged in."
    say "Don't unplug or plug in any display before restarting: macOS rewrites these settings when displays change."
    say "To undo: $0 --restore \"$backup\""
  else
    say "Done (sandbox)."
  fi
}

restore() {
  local dir="$1"
  [ -f "$dir/user.plist" ] && [ -f "$dir/system.plist" ] || die "$dir does not contain user.plist and system.plist"
  import_user "$dir/user.plist"
  import_system "$dir/system.plist"
  say "Restored settings from $dir. Restart the Mac for them to take effect."
}

case "${1:-}" in
  ""|--check) check ;;
  --apply)    apply ;;
  --restore)  [ -n "${2:-}" ] || die "usage: $0 --restore BACKUP_DIR"; restore "$2" ;;
  -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)          die "unknown option $1 (try --help)" ;;
esac
