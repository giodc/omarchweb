#!/usr/bin/env bash
# OmarchWeb — virtual host management backend (Nginx).
#
# Generates an nginx server block for a PHP, Laravel, WordPress, or Node
# project and enables it via sites-available/sites-enabled. PHP/Laravel
# vhosts get a project folder; WordPress vhosts download the latest
# release.
#
# Conventions (all tunable via env):
#   OMARCHWEB_WEB_ROOT   base dir for projects           (default: ~/Web)
#   OMARCHWEB_NGINX_DIR  nginx config dir                (default: /etc/nginx)
#   OMARCHWEB_PORT       listen port for vhosts          (default: 80)
#   OMARCHWEB_FPM_SOCK   php-fpm socket                  (default: unix:/run/php-fpm/php-fpm.sock)
#
# The privileged parts (writing nginx configs, /etc/hosts, reloading nginx)
# run through root.sh via passwordless sudo when available, otherwise pkexec
# so the desktop polkit agent can prompt. The panel has no TTY, so `sudo`
# cannot ask for a password itself. Names are validated to a safe set.

set -u
# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WEB_ROOT="${OMARCHWEB_WEB_ROOT:-$HOME/Web}"
NGINX_DIR="${OMARCHWEB_NGINX_DIR:-/etc/nginx}"
PORT="${OMARCHWEB_PORT:-80}"
FPM_SOCK="${OMARCHWEB_FPM_SOCK:-unix:/run/php-fpm/php-fpm.sock}"
WP_URL="${OMARCHWEB_WP_URL:-https://wordpress.org/latest.tar.gz}"
AVAIL="$NGINX_DIR/sites-available"
ENABLED="$NGINX_DIR/sites-enabled"

name_ok() {
  case "$1" in
    *[!A-Za-z0-9_.-]*|''|.*) return 1 ;;
    *) return 0 ;;
  esac
}

host_ok() {
  case "$1" in
    *[!A-Za-z0-9.-]*|''|.*|*-|.*.*) return 1 ;;
    *) return 0 ;;
  esac
}

# Collapse ~/Web and $HOME/~/Web (path settings sometimes prepend HOME onto ~/).
normalize_root() {
  local r="$1"
  local broken="$HOME/~/"
  case "$r" in
    "$broken"*) r="$HOME/${r#"$broken"}" ;;
    "~/"*) r="$HOME/${r#~/}" ;;
    "~") r="$HOME" ;;
  esac
  printf '%s\n' "$r"
}

WEB_ROOT="$(normalize_root "$WEB_ROOT")"

ensure_dirs() {
  mkdir -p "$WEB_ROOT"
}

# list: print name|type|host|root for each enabled/available vhost
list_vhosts() {
  local files
  files=$(ls "$AVAIL" 2>/dev/null)
  [ -z "$files" ] && return 0
  for f in $files; do
    [ -f "$AVAIL/$f" ] || continue
    local host type root
    host=$(sed -n 's/.*server_name[[:space:]]*\([^;]*\);.*/\1/p' "$AVAIL/$f" | tr -d ' ' | head -1)
    root=$(sed -n 's/.*root[[:space:]]*\([^;]*\);.*/\1/p' "$AVAIL/$f" | tr -d ' ' | head -1)
    type=$(sed -n 's/^# type[[:space:]]*//p' "$AVAIL/$f" | head -1 | tr -d ' ')
    if [ -z "$type" ]; then
      if [ -f "$root/wp-load.php" ]; then
        type="wordpress"
      elif grep -q 'fastcgi_pass' "$AVAIL/$f"; then
        type="php"
      elif grep -q 'proxy_pass' "$AVAIL/$f"; then
        type="node"
      else
        type="static"
      fi
    fi
    printf '%s|%s|%s|%s\n' "$f" "$type" "$host" "$root"
  done
}

render_block() {
  local name="$1" type="$2" host="$3" root="$4" proxy_port="$5"
  local kind="${6:-$type}"
  cat <<EOF
# managed by OmarchWeb
# type $kind
server {
    listen $PORT;
    server_name $host;

    root $root;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

EOF
  if [ "$type" = "php" ]; then
    cat <<EOF
    location ~ \.php$ {
        fastcgi_pass $FPM_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
EOF
  elif [ "$type" = "node" ]; then
    cat <<EOF
    location / {
        proxy_pass http://127.0.0.1:$proxy_port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
EOF
  fi
  echo "}"
}

install_wordpress() {
  local dest="$1"
  mkdir -p "$dest" || return 1
  if [ -f "$dest/wp-load.php" ]; then
    echo "INFO: WordPress already present in $dest"
    return 0
  fi

  local fetch=""
  if command -v curl >/dev/null 2>&1; then
    fetch="curl"
  elif command -v wget >/dev/null 2>&1; then
    fetch="wget"
  else
    echo "ERROR: curl or wget is required to download WordPress" >&2
    return 1
  fi

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/omarchweb-wp.XXXXXX")" || return 1
  echo "Downloading latest WordPress..."
  if [ "$fetch" = "curl" ]; then
    if ! curl -fL --retry 2 --connect-timeout 20 -o "$tmp/wordpress.tar.gz" "$WP_URL"; then
      echo "ERROR: failed to download WordPress" >&2
      rm -rf "$tmp"
      return 1
    fi
  else
    if ! wget -q -O "$tmp/wordpress.tar.gz" "$WP_URL"; then
      echo "ERROR: failed to download WordPress" >&2
      rm -rf "$tmp"
      return 1
    fi
  fi

  if ! tar -xzf "$tmp/wordpress.tar.gz" -C "$tmp" || [ ! -d "$tmp/wordpress" ]; then
    echo "ERROR: failed to extract WordPress" >&2
    rm -rf "$tmp"
    return 1
  fi
  if ! cp -a "$tmp/wordpress/." "$dest/"; then
    echo "ERROR: failed to copy WordPress into $dest" >&2
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  echo "OK: WordPress extracted to $dest"
  if id http >/dev/null 2>&1 && command -v setfacl >/dev/null 2>&1; then
    setfacl -R -m u:http:rwX "$dest" 2>/dev/null || true
    setfacl -R -d -m u:http:rwX "$dest" 2>/dev/null || true
  fi
}

add_vhost() {
  # add <name> <type> [host] [root] [proxy_port]
  local name="$1" type="$2"
  local host="${3:-}"
  local root="${4:-}"
  local proxy_port="${5:-}"

  name_ok "$name" || { echo "ERROR: invalid vhost name '$name'" >&2; return 1; }
  [ "$type" = "php" ] || [ "$type" = "node" ] || [ "$type" = "laravel" ] || [ "$type" = "wordpress" ] || {
    echo "ERROR: unknown type '$type' (php|laravel|wordpress|node)" >&2; return 1; }
  [ -z "$host" ] && host="${name}.test"
  host_ok "$host" || { echo "ERROR: invalid host '$host'" >&2; return 1; }

  ensure_dirs

  if [ -f "$AVAIL/$name" ]; then
    echo "ERROR: vhost '$name' already exists" >&2
    return 1
  fi

  local kind="$type"
  local nginx_type="$type"

  if [ "$kind" = "laravel" ]; then
    nginx_type="php"
    [ -z "$root" ] && root="$WEB_ROOT/$name/public"
  elif [ "$kind" = "wordpress" ]; then
    nginx_type="php"
    [ -z "$root" ] && root="$WEB_ROOT/$name"
  elif [ -z "$root" ]; then
    root="$WEB_ROOT/$name"
  fi
  root="$(normalize_root "$root")"
  WEB_ROOT="$(normalize_root "$WEB_ROOT")"

  if [ "$kind" = "wordpress" ]; then
    omarchweb_elevate php-ext mysqli || return 1
    install_wordpress "$root" || return 1
  elif [ "$nginx_type" = "php" ]; then
    mkdir -p "$root"
    if [ ! -f "$root/index.php" ]; then
      printf '%s\n' '<?php phpinfo(); ?>' > "$root/index.php"
    fi
  fi

  local tmp="/tmp/omarchweb-$name.conf"
  render_block "$name" "$nginx_type" "$host" "$root" "$proxy_port" "$kind" > "$tmp"

  # One privileged call so polkit asks for a password at most once.
  if ! omarchweb_elevate vhost-install "$name" "$tmp" "$host"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"

  echo "OK: enabled vhost '$name' ($kind) at $host -> $root"
}

remove_vhost() {
  local name="$1"
  name_ok "$name" || { echo "ERROR: invalid vhost name '$name'" >&2; return 1; }
  omarchweb_elevate vhost-remove "$name" || return 1
  echo "OK: removed vhost '$name'"
}

case "${1:-}" in
  list) list_vhosts ;;
  add)
    shift
    add_vhost "$@"
    ;;
  tune)
    omarchweb_elevate nginx-tune "$HOME"
    ;;
  remove)
    [ "$#" -lt 2 ] && { echo "usage: vhost.sh remove <name>" >&2; exit 1; }
    remove_vhost "$2"
    ;;
  *)
    echo "unknown action: ${1:-}" >&2
    echo "usage: vhost.sh list | add <name> <php|laravel|wordpress|node> [host] [root] [proxy_port] | remove <name> | tune" >&2
    exit 1
    ;;
esac
