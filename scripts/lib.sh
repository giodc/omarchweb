# OmarchWeb — shared helpers (sourced by the other scripts).
#
# Privilege: these backends are launched from the bar panel, which has no TTY,
# so `sudo` cannot prompt. Try passwordless sudo first; otherwise pkexec so
# Omarchy's polkit agent can show its password dialog.

omarchweb_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
omarchweb_root="$omarchweb_scripts/root.sh"

omarchweb_elevate() {
  if [ ! -x "$omarchweb_root" ]; then
    echo "ERROR: missing helper $omarchweb_root" >&2
    return 127
  fi
  if [ "$(id -u)" -eq 0 ]; then
    "$omarchweb_root" "$@"
    return $?
  fi
  # -n: never prompt. If this works, the caller already has NOPASSWD/cached sudo.
  if sudo -n true >/dev/null 2>&1; then
    sudo -n "$omarchweb_root" "$@"
    return $?
  fi
  if command -v pkexec >/dev/null 2>&1; then
    # pkexec talks to polkit, which is what drives the Omarchy password dialog.
    # `sudo` cannot prompt from this GUI process (and `sudo -n` never tries).
    pkexec /usr/bin/bash "$omarchweb_root" "$@"
    return $?
  fi
  echo "ERROR: root privileges required (no polkit/pkexec, and sudo cannot prompt without a TTY)" >&2
  return 1
}
