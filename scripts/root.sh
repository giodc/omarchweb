#!/usr/bin/bash
# OmarchWeb — privileged helper.
#
# Installed as a root-owned snapshot at /usr/local/libexec/omarchweb/root.sh
# and invoked via sudo or pkexec (see lib.sh). Validates every argument;
# do not add a generic "run this command" path.

set -eu

if [ "$(id -u)" -eq 0 ]; then
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
  export PATH
  unset CDPATH
  NGINX_DIR=/etc/nginx
else
  NGINX_DIR="${OMARCHWEB_NGINX_DIR:-/etc/nginx}"
fi
AVAIL="$NGINX_DIR/sites-available"
ENABLED="$NGINX_DIR/sites-enabled"

# Pinned Mailpit GitHub release (duplicated from scripts/pins.sh; do not source
# the user-writable checkout from this helper).
MAILPIT_VERSION="1.31.0"
MAILPIT_SHA256_AMD64="076b5ded9a2182842b93e761b9586a1a251445bffe2666f9f22a6dc14470237d"
MAILPIT_SHA256_ARM64="db3e685ed59d58354a29a4e7bfd0497f050af771a41e122aabdb0bd4fb915952"
MAILPIT_MAX_BYTES=16777216
MAILPIT_BIN="/usr/local/bin/mailpit"
MAILPIT_UNIT="/etc/systemd/system/mailpit.service"

name_ok() {
  case "$1" in
    *[!A-Za-z0-9_.-]*|''|.*) return 1 ;;
    *) return 0 ;;
  esac
}

host_ok() {
  case "$1" in
    *[!A-Za-z0-9.-]*|''|.*|*-) return 1 ;;
    *) return 0 ;;
  esac
}

svc_ok() {
  case "$1" in
    php-fpm|mariadb|nginx|postgresql|redis|mailpit) return 0 ;;
    *) return 1 ;;
  esac
}

# Database role names are interpolated into SQL built inside this snapshot,
# so restrict them to characters that cannot terminate an identifier.
db_user_ok() {
  case "$1" in
    *[!A-Za-z0-9_]*|'') return 1 ;;
    root|mysql|postgres|PUBLIC) return 1 ;;
    *) return 0 ;;
  esac
}

caller_home() {
  local uid="${PKEXEC_UID:-${SUDO_UID:-}}"
  if [ -n "$uid" ]; then
    getent passwd "$uid" | cut -d: -f6
    return
  fi
  local user="${SUDO_USER:-}"
  if [ -n "$user" ] && [ "$user" != "root" ]; then
    getent passwd "$user" | cut -d: -f6
    return
  fi
  printf '%s\n' ""
}

# fsync a file or directory. GNU coreutils `sync -d` is fdatasync(2).
fsync_path() {
  sync -d "$1" 2>/dev/null || sync "$1"
}

# Write dest via an O_EXCL same-directory regular file, fsync, then rename.
# With no extra args, content is read from stdin. Otherwise those args are
# the writer (they must not clobber dest; they should read dest and print).
# rename(2) replaces a symlink at dest instead of writing through it.
atomic_replace() {
  local dest="$1"
  local dir tmp
  shift
  dir="$(dirname -- "$dest")"
  mkdir -p "$dir"
  tmp="$(mktemp -p "$dir" -- "$(basename -- "$dest").XXXXXX")" || return 1
  if [ "$#" -gt 0 ]; then
    if ! "$@" > "$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
  else
    if ! cat > "$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
  fi
  if ! chmod 0644 -- "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fsync_path "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  fsync_path "$dir" || true
}

ensure_nginx_layout() {
  mkdir -p "$AVAIL" "$ENABLED"
  local conf="$NGINX_DIR/nginx.conf"
  [ -f "$conf" ] || return 0
  if ! grep -Eq '^[[:space:]]*include[[:space:]]+sites-enabled/\*;' "$conf"; then
    atomic_replace "$conf" sed '/^[[:space:]]*http[[:space:]]*{/a\    include sites-enabled/*;' "$conf" || return 1
  fi
  # Arch's default mime.types is larger than nginx's stock hash; without this
  # reload warns (or eventually fails) with "increase types_hash_max_size".
  if ! grep -Eq '^[[:space:]]*types_hash_max_size' "$conf"; then
    atomic_replace "$conf" awk '
      /^[[:space:]]*http[[:space:]]*\{/ {
        print
        print "    types_hash_max_size 4096;"
        print "    types_hash_bucket_size 128;"
        print "    server_names_hash_max_size 4096;"
        print "    server_names_hash_bucket_size 128;"
        next
      }
      { print }
    ' "$conf" || return 1
  fi
}

# A vhost document root is the one caller-supplied path this helper grants
# ACLs on, so confine it to the calling user's home before touching it.
docroot_ok() {
  local docroot="$1" home="$2"
  [ -n "$docroot" ] || { echo "ERROR: vhost conf has no root directive" >&2; return 1; }
  [ -n "$home" ] || { echo "ERROR: cannot resolve the calling user's home" >&2; return 1; }
  case "$docroot" in
    /*) ;;
    *) echo "ERROR: vhost root must be absolute: $docroot" >&2; return 1 ;;
  esac
  case "$docroot" in
    *..*) echo "ERROR: vhost root must not contain '..': $docroot" >&2; return 1 ;;
  esac
  case "$docroot" in
    "$home"/*) return 0 ;;
    *) echo "ERROR: vhost root must live under $home: $docroot" >&2; return 1 ;;
  esac
}

# Allow nginx/php-fpm (user http) to traverse home and read the project.
# Pass "write" as the second argument for apps that must create files
# (WordPress wp-config.php, uploads, etc).
grant_http_access() {
  local docroot="$1"
  local write="${2:-}"
  [ -n "$docroot" ] && [ -d "$docroot" ] || return 0
  id http >/dev/null 2>&1 || return 0
  if command -v setfacl >/dev/null 2>&1; then
    local parent mode="rX"
    [ "$write" = "write" ] && mode="rwX"
    parent="$(dirname "$docroot")"
    while [ "$parent" != "/" ] && [ -n "$parent" ]; do
      setfacl -m u:http:--x "$parent" 2>/dev/null || true
      parent="$(dirname "$parent")"
    done
    setfacl -R -m "u:http:${mode}" "$docroot" 2>/dev/null || true
    if [ "$write" = "write" ]; then
      setfacl -R -d -m u:http:rwX "$docroot" 2>/dev/null || true
    fi
  fi
}

# Collapse $HOME/~/Web and ~/Web into $HOME/Web in managed vhost files,
# and move any projects created under a literal ~/ directory.
repair_vhost_paths() {
  local home="$1"
  [ -n "$home" ] || return 0
  local f
  for f in "$AVAIL"/*; do
    [ -f "$f" ] || continue
    grep -q 'managed by OmarchWeb' "$f" 2>/dev/null || continue
    atomic_replace "$f" sed \
      -e "s|root ${home}/~/Web/|root ${home}/Web/|g" \
      -e "s|root ~/Web/|root ${home}/Web/|g" \
      "$f" || return 1
  done
  if [ -d "$home/~/Web" ]; then
    mkdir -p "$home/Web"
    local src dest
    for src in "$home/~/Web"/*; do
      [ -e "$src" ] || continue
      dest="$home/Web/$(basename "$src")"
      if [ ! -e "$dest" ]; then
        mv "$src" "$dest"
      fi
    done
  fi
  if [ -d "$home/Web" ]; then
    grant_http_access "$home/Web"
  fi
}

reload_nginx() {
  if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    nginx -t
    systemctl reload nginx
  fi
}

vhost_install() {
  local name="$1" host="$2"
  local body home docroot write=""
  name_ok "$name" || { echo "ERROR: invalid vhost name '$name'" >&2; return 1; }
  host_ok "$host" || { echo "ERROR: invalid host '$host'" >&2; return 1; }
  body="$(cat)" || { echo "ERROR: missing generated vhost conf on stdin" >&2; return 1; }
  [ -n "$body" ] || { echo "ERROR: empty vhost conf" >&2; return 1; }

  # Validate the document root before anything is written, so a rejected
  # conf never leaves a half-enabled vhost behind.
  home="$(caller_home)"
  docroot="$(printf '%s\n' "$body" \
    | sed -n 's/.*root[[:space:]]*\([^;]*\);.*/\1/p' | tr -d ' ' | head -1)"
  docroot_ok "$docroot" "$home" || return 1

  ensure_nginx_layout
  printf '%s\n' "$body" | atomic_replace "$AVAIL/$name"
  ln -sf "$AVAIL/$name" "$ENABLED/$name"
  if ! grep -Eq "(^|[[:space:]])$host([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    printf '%s\n' "127.0.0.1 $host" >> /etc/hosts
  fi
  repair_vhost_paths "$home"
  if grep -q '^# type wordpress' "$AVAIL/$name" 2>/dev/null || [ -f "$docroot/wp-load.php" ]; then
    write="write"
  fi
  grant_http_access "$docroot" "$write"
  reload_nginx
}

vhost_remove() {
  local name="$1"
  name_ok "$name" || { echo "ERROR: invalid vhost name '$name'" >&2; return 1; }
  rm -f "$ENABLED/$name" "$AVAIL/$name"
  reload_nginx
}

# Exactly one allow-listed unit name per call. Extra arguments are refused so
# a unit pathname can never ride along with an accepted service name.
do_systemctl() {
  local action="$1"
  local now=""
  shift
  case "$action" in
    start|stop|restart|reload|is-active) ;;
    enable|disable)
      if [ "${1:-}" = "--now" ]; then
        now="--now"
        shift
      fi
      ;;
    *)
      echo "ERROR: systemctl action '$action' is not allowed" >&2
      return 1
      ;;
  esac
  [ "$#" -eq 1 ] || {
    echo "ERROR: systemctl $action takes exactly one service" >&2
    return 1
  }
  svc_ok "$1" || { echo "ERROR: unknown service '$1'" >&2; return 1; }
  if [ -n "$now" ]; then
    systemctl "$action" "$now" "$1"
  else
    systemctl "$action" "$1"
  fi
}

do_pacman() {
  # Only the flags setup.sh uses, plus a fixed package allow-list.
  local -a pkgs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -S|--needed|--noconfirm) shift ;;
      php|php-fpm|mariadb|nginx|postgresql|redis|composer|php-pgsql|php-sqlite)
        pkgs+=("$1"); shift ;;
      *) echo "ERROR: package '$1' is not allowed" >&2; return 1 ;;
    esac
  done
  [ "${#pkgs[@]}" -gt 0 ] || { echo "ERROR: no packages to install" >&2; return 1; }
  pacman -S --needed --noconfirm "${pkgs[@]}"
}

# Remove packages installed by OmarchWeb services (allow-listed).
do_pacman_r() {
  local -a pkgs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -R|-Rs|-Rns|--noconfirm) shift ;;
      php|php-fpm|mariadb|nginx|postgresql|redis|composer|php-pgsql|php-sqlite|mailpit|mailpit-bin)
        pkgs+=("$1"); shift ;;
      *) echo "ERROR: package '$1' is not allowed" >&2; return 1 ;;
    esac
  done
  [ "${#pkgs[@]}" -gt 0 ] || { echo "ERROR: no packages to remove" >&2; return 1; }
  pacman -R --noconfirm "${pkgs[@]}"
}

mailpit_expected_digest() {
  case "$(uname -m)" in
    x86_64) printf '%s\n' "$MAILPIT_SHA256_AMD64" ;;
    aarch64) printf '%s\n' "$MAILPIT_SHA256_ARM64" ;;
    *) return 1 ;;
  esac
}

# Install Mailpit from a descriptor-bound tarball on stdin. Digest and dest
# paths are baked into this snapshot; no pathname from the caller is used.
do_install_mailpit() {
  local expected tmp got
  expected="$(mailpit_expected_digest)" || {
    echo "ERROR: unsupported architecture $(uname -m) for mailpit" >&2
    return 1
  }
  tmp="$(mktemp -d -p /run omarchweb-mailpit.XXXXXX)" || return 1
  # shellcheck disable=SC2064
  trap 'rm -rf -- "$tmp"' RETURN
  dd bs=65536 count=$((MAILPIT_MAX_BYTES / 65536 + 1)) of="$tmp/mailpit.tar.gz" status=none
  got="$(sha256sum -- "$tmp/mailpit.tar.gz" | awk '{print $1}')"
  if [ "$got" != "$expected" ]; then
    echo "ERROR: mailpit digest mismatch (refusing to install)" >&2
    return 1
  fi
  tar -xzf "$tmp/mailpit.tar.gz" -C "$tmp" --no-same-owner mailpit
  [ -f "$tmp/mailpit" ] || {
    echo "ERROR: mailpit binary missing from verified archive" >&2
    return 1
  }
  chmod 0755 -- "$tmp/mailpit"
  install -D -o root -g root -m 0755 "$tmp/mailpit" "$MAILPIT_BIN"
  atomic_replace "$MAILPIT_UNIT" printf '%s\n' \
    "# managed by OmarchWeb" \
    "[Unit]" \
    "Description=Mailpit SMTP testing (OmarchWeb)" \
    "After=network.target" \
    "" \
    "[Service]" \
    "Type=simple" \
    "DynamicUser=yes" \
    "StateDirectory=mailpit" \
    "ExecStart=$MAILPIT_BIN --database /var/lib/mailpit/mailpit.db --listen 127.0.0.1:8025 --smtp 127.0.0.1:1025" \
    "Restart=on-failure" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target"
  systemctl daemon-reload
  echo "OK: installed mailpit $MAILPIT_VERSION to $MAILPIT_BIN"
}

do_remove_mailpit() {
  if [ -f "$MAILPIT_UNIT" ] && grep -q '^# managed by OmarchWeb' "$MAILPIT_UNIT"; then
    systemctl disable --now mailpit 2>/dev/null || true
    rm -f -- "$MAILPIT_UNIT"
    systemctl daemon-reload
  fi
  if [ -f "$MAILPIT_BIN" ] && [ ! -L "$MAILPIT_BIN" ]; then
    rm -f -- "$MAILPIT_BIN"
  fi
  echo "OK: removed OmarchWeb mailpit"
}

php_ext_ok() {
  case "$1" in
    mysqli|gd|exif|curl|zip|intl|bcmath|iconv|pdo_mysql|pdo_pgsql|pdo_sqlite)
      return 0 ;;
    *) return 1 ;;
  esac
}

enable_php_ext() {
  local conf="/etc/php/conf.d/omarchweb.ini"
  local ext
  [ "$#" -gt 0 ] || { echo "ERROR: no php extensions given" >&2; return 1; }
  mkdir -p /etc/php/conf.d
  if [ ! -f "$conf" ]; then
    printf '%s\n' "; managed by OmarchWeb" > "$conf"
  fi
  for ext in "$@"; do
    php_ext_ok "$ext" || { echo "ERROR: php extension '$ext' is not allowed" >&2; return 1; }
    [ -f "/usr/lib/php/modules/${ext}.so" ] || {
      echo "ERROR: php extension '$ext' is not installed" >&2
      return 1
    }
    if ! grep -Eq "^[[:space:]]*extension=${ext}([[:space:]]|$)" "$conf"; then
      printf 'extension=%s\n' "$ext" >> "$conf"
    fi
  done
  if systemctl is-active --quiet php-fpm 2>/dev/null; then
    systemctl reload php-fpm || systemctl restart php-fpm
  fi
  echo "OK: enabled php extensions: $*"
}

# The only privileged database operations the panel needs: give the calling
# user a local socket/peer account. SQL is built here from a validated role
# name, so no caller-supplied SQL or client option ever reaches root.
grant_mariadb_user() {
  local user="$1"
  db_user_ok "$user" || { echo "ERROR: invalid database user '$user'" >&2; return 1; }
  command -v mariadb >/dev/null 2>&1 || { echo "ERROR: mariadb not installed" >&2; return 1; }
  printf '%s\n' \
    "CREATE USER IF NOT EXISTS '$user'@'localhost' IDENTIFIED VIA unix_socket;" \
    "GRANT ALL PRIVILEGES ON *.* TO '$user'@'localhost' WITH GRANT OPTION;" \
    "FLUSH PRIVILEGES;" \
    | mariadb
  echo "OK: MariaDB socket access granted for '$user'"
}

grant_postgres_role() {
  local user="$1"
  db_user_ok "$user" || { echo "ERROR: invalid database user '$user'" >&2; return 1; }
  command -v psql >/dev/null 2>&1 || { echo "ERROR: postgresql is not installed" >&2; return 1; }
  local sql
  sql="DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$user') THEN
    CREATE ROLE $user WITH LOGIN SUPERUSER CREATEDB CREATEROLE;
  ELSE
    ALTER ROLE $user WITH LOGIN SUPERUSER CREATEDB CREATEROLE;
  END IF;
END \$\$;"
  if command -v runuser >/dev/null 2>&1; then
    printf '%s\n' "$sql" | runuser -u postgres -- psql -d postgres -v ON_ERROR_STOP=1 -q
  else
    printf '%s\n' "$sql" | su -s /usr/bin/bash postgres -c 'exec psql -d postgres -v ON_ERROR_STOP=1 -q'
  fi
  echo "OK: PostgreSQL role granted for '$user'"
}

init_mariadb() {
  if [ -f /usr/lib/systemd/system/mariadb.service ] && \
     [ ! -d /var/lib/mysql/mysql ] && command -v mariadb-install-db >/dev/null 2>&1; then
    mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
  fi
}

init_postgres() {
  if [ -f /usr/lib/systemd/system/postgresql.service ] && \
     [ ! -d /var/lib/postgres/data ]; then
    install -d -o postgres -g postgres /var/lib/postgres/data
    if command -v runuser >/dev/null 2>&1; then
      runuser -u postgres -- initdb -D /var/lib/postgres/data -E UTF8 --locale=C.UTF-8 || true
    else
      su -s /usr/bin/bash postgres -c 'initdb -D /var/lib/postgres/data -E UTF8 --locale=C.UTF-8' || true
    fi
  fi
}

case "${1:-}" in
  nginx-tune)
    [ "$#" -eq 1 ] || { echo "usage: root.sh nginx-tune" >&2; exit 1; }
    # Derived from the authenticated caller, never from an argument: this path
    # is interpolated into sed expressions over /etc/nginx configs.
    home="$(caller_home)"
    ensure_nginx_layout
    repair_vhost_paths "$home"
    reload_nginx
    echo "OK: nginx hash sizes updated and vhost paths repaired"
    ;;
  vhost-install)
    [ "$#" -eq 3 ] || { echo "usage: root.sh vhost-install <name> <host>  (conf on stdin)" >&2; exit 1; }
    vhost_install "$2" "$3"
    ;;
  vhost-remove)
    [ "$#" -eq 2 ] || { echo "usage: root.sh vhost-remove <name>" >&2; exit 1; }
    vhost_remove "$2"
    ;;
  systemctl)
    shift
    [ "$#" -ge 2 ] || { echo "usage: root.sh systemctl <action> <service>" >&2; exit 1; }
    do_systemctl "$@"
    ;;
  pacman)
    shift
    do_pacman "$@"
    ;;
  pacman-r)
    shift
    [ "$#" -ge 1 ] || { echo "usage: root.sh pacman-r <package...>" >&2; exit 1; }
    do_pacman_r "$@"
    ;;
  install-mailpit)
    [ "$#" -eq 1 ] || { echo "usage: root.sh install-mailpit  (tarball on stdin)" >&2; exit 1; }
    do_install_mailpit
    ;;
  remove-mailpit)
    [ "$#" -eq 1 ] || { echo "usage: root.sh remove-mailpit" >&2; exit 1; }
    do_remove_mailpit
    ;;
  grant-mariadb)
    [ "$#" -eq 2 ] || { echo "usage: root.sh grant-mariadb <user>" >&2; exit 1; }
    grant_mariadb_user "$2"
    ;;
  grant-postgres)
    [ "$#" -eq 2 ] || { echo "usage: root.sh grant-postgres <user>" >&2; exit 1; }
    grant_postgres_role "$2"
    ;;
  init-mariadb) init_mariadb ;;
  init-postgres) init_postgres ;;
  php-ext)
    shift
    [ "$#" -ge 1 ] || { echo "usage: root.sh php-ext <ext...>" >&2; exit 1; }
    enable_php_ext "$@"
    ;;
  *)
    echo "unknown action: ${1:-}" >&2
    echo "usage: root.sh vhost-install|vhost-remove|nginx-tune|systemctl|pacman|pacman-r|install-mailpit|remove-mailpit|grant-mariadb|grant-postgres|init-mariadb|init-postgres|php-ext" >&2
    exit 1
    ;;
esac
