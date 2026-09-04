#!/usr/bin/env bash
# OmarchWeb — service control backend.
#
# Manages the web stack services (PHP-FPM, MariaDB, Nginx) as systemd units.
# Each service may be installed as either a system unit (managed with sudo)
# or a --user unit (managed directly). The script auto-detects which kind of
# unit is present and falls back to reporting "not installed" when the unit
# does not exist at all.
#
# Usage:
#   services.sh status [service...]   print one "name kind state sub autostart" line
#   services.sh start|stop|restart <service>
#   services.sh enable|disable <service>   turn boot autostart on or off
#   services.sh installed <service>   exit 0 if the unit file exists
#   services.sh setup                 run the one-shot setup (install deps)
#
# A service is one of: php-fpm, mariadb, nginx, postgresql, redis, mailpit

set -u

SERVICES="${OMARCHWEB_SERVICES:-php-fpm mariadb nginx postgresql redis mailpit}"

# Elevate for a system unit. Passwordless sudo if available, otherwise pkexec
# so the desktop polkit agent can prompt (this script has no TTY).
# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

run_system() {
  omarchweb_elevate systemctl "$@"
}

unit_kind() {
  local svc="$1"
  if systemctl --quiet is-enabled "$svc" 2>/dev/null || \
     systemctl --quiet is-active "$svc" 2>/dev/null || \
     [ -f "/etc/systemd/system/$svc.service" ] || \
     [ -f "/usr/lib/systemd/system/$svc.service" ]; then
    echo "system"
  elif systemctl --user --quiet list-unit-files "$svc" 2>/dev/null | grep -q .; then
    echo "user"
  else
    echo "none"
  fi
}

# systemctl is-active prints inactive/failed and exits non-zero — never use
# `|| echo unknown` or the status line gains a newline and breaks parsing.
unit_active_state() {
  local scope="$1" svc="$2" state=""
  if [ "$scope" = "user" ]; then
    state="$(systemctl --user is-active "$svc" 2>/dev/null || true)"
  else
    state="$(systemctl is-active "$svc" 2>/dev/null || true)"
  fi
  state="${state%%$'\n'*}"
  case "$state" in
    active|inactive|failed|activating|deactivating|reloading|maintenance) printf '%s\n' "$state" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

# Arch ships redis.service as an alias of valkey.service, and is-enabled
# answers "alias" when asked through the alias name. Resolve to the unit
# systemd actually tracks before asking about autostart.
canonical_unit() {
  local scope="$1" svc="$2" id=""
  if [ "$scope" = "user" ]; then
    id="$(systemctl --user show -p Id --value "$svc" 2>/dev/null || true)"
  else
    id="$(systemctl show -p Id --value "$svc" 2>/dev/null || true)"
  fi
  id="${id%%$'\n'*}"
  [ -n "$id" ] || id="$svc"
  printf '%s\n' "$id"
}

# Whether the unit starts at boot. Collapsed to enabled/disabled/static so the
# panel can show a toggle only where flipping it means something.
unit_enabled_state() {
  local scope="$1" svc="$2" state="" unit
  unit="$(canonical_unit "$scope" "$svc")"
  if [ "$scope" = "user" ]; then
    state="$(systemctl --user is-enabled "$unit" 2>/dev/null || true)"
  else
    state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  fi
  state="${state%%$'\n'*}"
  case "$state" in
    enabled|enabled-runtime|linked|linked-runtime|generated) printf 'enabled\n' ;;
    disabled|masked|masked-runtime) printf 'disabled\n' ;;
    static|indirect|transient) printf 'static\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# Fields: name kind active-state sub-state autostart. SubState is emitted as
# "-" when empty so the trailing autostart field stays positional.
status_line() {
  local svc="$1"
  local kind
  kind="$(unit_kind "$svc")"
  local state="not-installed"
  local sub=""
  local enabled="unknown"

  case "$kind" in
    system)
      state="$(unit_active_state system "$svc")"
      sub="$(systemctl show -p SubState --value "$svc" 2>/dev/null || true)"
      enabled="$(unit_enabled_state system "$svc")"
      ;;
    user)
      state="$(unit_active_state user "$svc")"
      sub="$(systemctl --user show -p SubState --value "$svc" 2>/dev/null || true)"
      enabled="$(unit_enabled_state user "$svc")"
      ;;
  esac

  printf '%s %s %s %s %s\n' "$svc" "$kind" "$state" "${sub:--}" "$enabled"
}

do_action() {
  local action="$1"
  local svc="$2"
  local kind
  kind="$(unit_kind "$svc")"

  if [ "$kind" = "none" ]; then
    printf 'ERROR: service %s is not installed (no systemd unit found)\n' "$svc" >&2
    return 2
  fi

  # Fresh Arch installs leave PGDATA uninitialized; ensure the cluster exists
  # before systemctl start (same path as setup.sh install).
  if [ "$svc" = "postgresql" ] && { [ "$action" = "start" ] || [ "$action" = "restart" ]; }; then
    omarchweb_elevate init-postgres || return 1
  fi

  if [ "$kind" = "user" ]; then
    systemctl --user "$action" "$svc"
    return $?
  fi

  run_system "$action" "$svc"
  return $?
}

case "${1:-}" in
  status)
    if [ "$#" -gt 1 ]; then
      shift
      for s in "$@"; do status_line "$s"; done
    else
      for s in $SERVICES; do status_line "$s"; done
    fi
    ;;
  start|stop|restart)
    [ "$#" -lt 2 ] && { echo "usage: services.sh $1 <service>" >&2; exit 1; }
    do_action "$1" "$2"
    ;;
  enable|disable)
    # Autostart only: start/stop stay runtime-only so a service can be
    # stopped for this session without losing its boot configuration.
    [ "$#" -lt 2 ] && { echo "usage: services.sh $1 <service>" >&2; exit 1; }
    do_action "$1" "$2"
    ;;
  installed)
    [ "$#" -lt 2 ] && { echo "usage: services.sh installed <service>" >&2; exit 1; }
    [ "$(unit_kind "$2")" != "none" ]
    ;;
  *)
    echo "unknown action: ${1:-}" >&2
    echo "usage: services.sh status [service...] | start|stop|restart <service> | enable|disable <service> | installed <service>" >&2
    exit 1
    ;;
esac
