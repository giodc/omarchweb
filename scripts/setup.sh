#!/usr/bin/env bash
# OmarchWeb — one-shot setup backend.
#
# Installs and configures the web stack this control panel manages:
#   - php-fpm            (PHP-FPM service)
#   - mariadb            (database server)
#   - nginx              (web server used for virtual hosts)
#   - postgresql         (database server, optional)
#   - redis              (in-memory store, optional)
#   - mailpit            (SMTP catcher + web UI, optional, pinned GitHub release)
#   - composer + Laravel installer (dev tooling, pinned version, user install)
#
# The heavy package install needs root and can take a while. Passwordless
# sudo is used when available; otherwise pkexec so the desktop polkit agent
# can prompt. It is idempotent: already-installed packages are skipped.
#
# Usage:
#   setup.sh install [<service>]   install the whole stack or a single service
#   setup.sh uninstall <service>   stop/disable and remove packages for a service
#   setup.sh status                print which parts are installed

set -u
# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

pkg_installed() {
  pacman -Q "$1" >/dev/null 2>&1
}

install_pkg() {
  omarchweb_elevate pacman -S --needed --noconfirm "$@"
}

# Build/install path for Mailpit: download a pinned GitHub release as the
# user, verify the digest on the open file descriptor, then pass those bytes
# to the privileged helper on stdin (no pathname).
install_mailpit_release() {
  local asset sha url tmp rc=0
  case "$(uname -m)" in
    x86_64) asset="mailpit-linux-amd64.tar.gz"; sha="$OMARCHWEB_MAILPIT_SHA256_AMD64" ;;
    aarch64) asset="mailpit-linux-arm64.tar.gz"; sha="$OMARCHWEB_MAILPIT_SHA256_ARM64" ;;
    *) echo "ERROR: unsupported architecture $(uname -m) for mailpit" >&2; return 1 ;;
  esac
  url="https://github.com/axllent/mailpit/releases/download/v${OMARCHWEB_MAILPIT_VERSION}/${asset}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/omarchweb-mailpit.XXXXXX")" || return 1
  echo "Downloading Mailpit $OMARCHWEB_MAILPIT_VERSION..."
  if ! omarchweb_fetch_verified "$url" "$tmp/$asset" "$sha" "$OMARCHWEB_MAILPIT_MAX_BYTES"; then
    rm -rf "$tmp"
    return 1
  fi
  omarchweb_open_pinned "$tmp/$asset" "$sha" || { rm -rf "$tmp"; return 1; }
  echo "Installing Mailpit (password prompt)..."
  omarchweb_elevate install-mailpit <&"$OMARCHWEB_PINNED_FD" || rc=$?
  exec {OMARCHWEB_PINNED_FD}<&-
  rm -rf "$tmp"
  return $rc
}

# Start the service for this session but leave boot autostart off. Installing
# a dev stack should not silently add services to every boot; the panel's
# per-service "Boot" toggle opts in.
start_svc() {
  omarchweb_elevate systemctl start "$1"
}

disable_svc() {
  omarchweb_elevate systemctl disable --now "$1" 2>/dev/null \
    || omarchweb_elevate systemctl stop "$1" 2>/dev/null \
    || true
}

remove_pkg() {
  local -a installed=()
  local p
  for p in "$@"; do
    pkg_installed "$p" && installed+=("$p")
  done
  [ "${#installed[@]}" -gt 0 ] || return 0
  omarchweb_elevate pacman-r "${installed[@]}"
}

init_mariadb() {
  omarchweb_elevate init-mariadb
}

init_postgres() {
  omarchweb_elevate init-postgres
}

install_service() {
  local svc="$1"
  case "$svc" in
    php-fpm)    install_pkg php php-fpm; omarchweb_elevate php-ext mysqli ;;
    mariadb)    install_pkg mariadb; init_mariadb ;;
    nginx)      install_pkg nginx ;;
    postgresql) install_pkg postgresql; init_postgres ;;
    redis)      install_pkg redis ;;
    mailpit)
      if pkg_installed mailpit || pkg_installed mailpit-bin || [ -x "$OMARCHWEB_MAILPIT_BIN" ]; then
        :
      else
        install_mailpit_release || return 1
      fi
      ;;
    *) echo "unknown service: $svc" >&2; return 1 ;;
  esac
  start_svc "$svc"
}

uninstall_service() {
  local svc="$1"
  case "$svc" in
    php-fpm|mariadb|nginx|postgresql|redis|mailpit) ;;
    *) echo "unknown service: $svc" >&2; return 1 ;;
  esac

  disable_svc "$svc"

  case "$svc" in
    php-fpm)    remove_pkg php-fpm ;;
    mariadb)    remove_pkg mariadb ;;
    nginx)      remove_pkg nginx ;;
    postgresql) remove_pkg postgresql ;;
    redis)      remove_pkg redis ;;
    mailpit)
      omarchweb_elevate remove-mailpit || true
      remove_pkg mailpit-bin mailpit
      ;;
  esac

  echo "OK: $svc uninstalled"
}

print_status() {
  echo "php-fpm     unit: $([ -f /usr/lib/systemd/system/php-fpm.service ] && echo yes || echo no)"
  echo "mariadb     unit: $([ -f /usr/lib/systemd/system/mariadb.service ] && echo yes || echo no)"
  echo "nginx       unit: $([ -f /usr/lib/systemd/system/nginx.service ] && echo yes || echo no)"
  echo "postgresql  unit: $([ -f /usr/lib/systemd/system/postgresql.service ] && echo yes || echo no)"
  echo "redis       unit: $([ -f /usr/lib/systemd/system/redis.service ] && echo yes || echo no)"
  echo "mailpit     unit: $([ -f /usr/lib/systemd/system/mailpit.service ] || [ -f /etc/systemd/system/mailpit.service ] && echo yes || echo no)"
  echo "composer    bin: $(command -v composer >/dev/null 2>&1 && echo yes || echo no)"
}

case "${1:-}" in
  install)
    if [ "$#" -gt 1 ]; then
      install_service "$2" || exit $?
      echo "OK: $2 installed"
    else
      install_service php-fpm || exit $?
      install_service mariadb || exit $?
      install_service nginx || exit $?
      install_pkg composer php-pgsql php-sqlite || exit $?
      omarchweb_elevate php-ext mysqli || exit $?

      # Grant the invoking user passwordless database access (idempotent).
      "$(dirname "$0")/db.sh" grant 2>/dev/null || true

      # Best-effort Laravel installer via Composer (pinned; user-level, not root).
      if command -v composer >/dev/null 2>&1 && ! command -v laravel >/dev/null 2>&1; then
        composer global require --no-interaction --prefer-dist \
          "laravel/installer:${OMARCHWEB_LARAVEL_INSTALLER_VERSION}" 2>/dev/null || true
      fi
      echo "OK: setup complete. See OmarchWeb panel to start services."
    fi
    ;;
  uninstall)
    [ "$#" -ge 2 ] || { echo "usage: setup.sh uninstall <service>" >&2; exit 1; }
    uninstall_service "$2" || exit $?
    ;;
  status) print_status ;;
  *)
    echo "unknown action: ${1:-}" >&2
    echo "usage: setup.sh install [<service>] | uninstall <service> | status" >&2
    exit 1
    ;;
esac
