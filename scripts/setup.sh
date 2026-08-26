#!/usr/bin/env bash
# OmarchWeb — one-shot setup backend.
#
# Installs and configures the web stack this control panel manages:
#   - php-fpm            (PHP-FPM service)
#   - mariadb            (database server)
#   - nginx              (web server used for virtual hosts)
#   - postgresql         (database server, optional)
#   - redis              (in-memory store, optional)
#   - mailpit            (SMTP catcher + web UI, optional, AUR)
#   - composer + Laravel installer (dev tooling, best-effort)
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

# Build an AUR package as the current user, then install the local archive
# through pkexec (polkit password dialog). Plain `yay -S` cannot prompt for
# sudo from the bar panel (no TTY), so it used to "succeed" without installing.
install_aur() {
  local pkg="$1"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/yay/$pkg"
  local built=""

  [ -n "$pkg" ] || { echo "ERROR: missing AUR package name" >&2; return 1; }
  if ! command -v yay >/dev/null 2>&1; then
    echo "ERROR: yay is required to install AUR package '$pkg'" >&2
    return 1
  fi

  find_built() {
    find "$cache" -maxdepth 1 -type f \
      \( -name "${pkg}-*.pkg.tar.zst" -o -name "${pkg}-*.pkg.tar.xz" \) \
      ! -name '*-debug-*' -printf '%T@\t%p\n' 2>/dev/null \
      | sort -nr \
      | head -1 \
      | cut -f2-
  }

  built="$(find_built || true)"
  if [ -z "$built" ]; then
    echo "Building AUR package '$pkg'..."
    # yay will fail when it reaches `sudo pacman -U` (no TTY). The package is
    # usually still built in ~/.cache/yay — we install that via pkexec next.
    yay -S --noconfirm --needed \
      --answerclean None --answerdiff None --answeredit None \
      "$pkg" >/dev/null 2>&1 || true
    built="$(find_built || true)"
  fi

  if [ -z "$built" ]; then
    echo "Fetching and building '$pkg' with makepkg..."
    mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/yay"
    (
      cd "${XDG_CACHE_HOME:-$HOME/.cache}/yay" || exit 1
      if [ ! -d "$pkg" ]; then
        yay -G --noconfirm "$pkg" || exit 1
      fi
      cd "$pkg" || exit 1
      makepkg -sf --noconfirm
    ) || {
      echo "ERROR: failed to build AUR package '$pkg'" >&2
      return 1
    }
    built="$(find_built || true)"
  fi

  [ -n "$built" ] && [ -f "$built" ] || {
    echo "ERROR: no built package found for '$pkg' under $cache" >&2
    return 1
  }

  echo "Installing $(basename "$built") (password prompt)..."
  omarchweb_elevate pacman-u "$built"
}

enable_svc() {
  omarchweb_elevate systemctl enable --now "$1" \
    || omarchweb_elevate systemctl start "$1"
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
      if pkg_installed mailpit || pkg_installed mailpit-bin; then
        :
      else
        # Prefer the prebuilt AUR package (no Go toolchain / make deps).
        install_aur mailpit-bin || return 1
      fi
      ;;
    *) echo "unknown service: $svc" >&2; return 1 ;;
  esac
  enable_svc "$svc"
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
    mailpit)    remove_pkg mailpit-bin mailpit ;;
  esac

  echo "OK: $svc uninstalled"
}

print_status() {
  echo "php-fpm     unit: $([ -f /usr/lib/systemd/system/php-fpm.service ] && echo yes || echo no)"
  echo "mariadb     unit: $([ -f /usr/lib/systemd/system/mariadb.service ] && echo yes || echo no)"
  echo "nginx       unit: $([ -f /usr/lib/systemd/system/nginx.service ] && echo yes || echo no)"
  echo "postgresql  unit: $([ -f /usr/lib/systemd/system/postgresql.service ] && echo yes || echo no)"
  echo "redis       unit: $([ -f /usr/lib/systemd/system/redis.service ] && echo yes || echo no)"
  echo "mailpit     unit: $([ -f /usr/lib/systemd/system/mailpit.service ] && echo yes || echo no)"
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

      # Best-effort Laravel installer via Composer (skips if network fails).
      if command -v composer >/dev/null 2>&1 && ! command -v laravel >/dev/null 2>&1; then
        omarchweb_elevate install-dir /usr/local/bin
        COMPOSER_ALLOW_SUPERUSER=1 composer global require laravel/installer 2>/dev/null || true
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
