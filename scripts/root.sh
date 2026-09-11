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

# Site kinds the helper will render. Anything else is refused.
kind_ok() {
  case "$1" in
    php|laravel|wordpress) return 0 ;;
    *) return 1 ;;
  esac
}

# Listen port for generated vhosts only.
port_ok() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
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

caller_username() {
  local uid="${PKEXEC_UID:-${SUDO_UID:-}}"
  if [ -n "$uid" ]; then
    getent passwd "$uid" | cut -d: -f1
    return
  fi
  local user="${SUDO_USER:-}"
  if [ -n "$user" ] && [ "$user" != "root" ]; then
    printf '%s\n' "$user"
    return
  fi
  printf '%s\n' ""
}

# Pool usernames become a filename suffix and ini values; restrict like db roles.
pool_user_ok() {
  case "$1" in
    *[!A-Za-z0-9_-]*|'') return 1 ;;
    root|http|nginx|nobody|mysql|mariadb|postgres|daemon|bin|sys|ftp) return 1 ;;
    *) return 0 ;;
  esac
}

render_php_fpm_pool() {
  local user="$1"
  cat <<EOF
; managed by OmarchWeb
[omarchweb-${user}]
user = ${user}
group = ${user}
listen = /run/php-fpm/omarchweb-${user}.sock
listen.owner = http
listen.group = http
listen.mode = 0660
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
clear_env = no
EOF
}

# Install a fixed per-user pool under /etc/php/php-fpm.d/omarchweb-<user>.conf.
# The username is derived from the authenticated caller only.
ensure_php_fpm_pool() {
  local user conf home
  user="$(caller_username)"
  pool_user_ok "$user" || { echo "ERROR: invalid pool user '$user'" >&2; return 1; }
  home="$(getent passwd "$user" | cut -d: -f6)"
  [ -n "$home" ] && [ -d "$home" ] || {
    echo "ERROR: cannot resolve home for pool user '$user'" >&2
    return 1
  }
  conf="/etc/php/php-fpm.d/omarchweb-${user}.conf"
  if [ -f "$conf" ] && grep -q '^; managed by OmarchWeb' "$conf" 2>/dev/null \
      && grep -Fq "listen = /run/php-fpm/omarchweb-${user}.sock" "$conf" \
      && grep -Fq "user = ${user}" "$conf"; then
    :
  else
    render_php_fpm_pool "$user" | atomic_replace "$conf" || return 1
    echo "OK: installed php-fpm pool for $user"
  fi
  if systemctl is-active --quiet php-fpm 2>/dev/null; then
    systemctl reload php-fpm || systemctl restart php-fpm
  fi
}

# Point managed PHP vhosts under the caller's home at their OmarchWeb pool socket.
repair_vhost_fpm_sockets() {
  local home="$1" user sock f docroot esc
  user="$(caller_username)"
  pool_user_ok "$user" || return 0
  [ -n "$home" ] || return 0
  sock="unix:/run/php-fpm/omarchweb-${user}.sock"
  esc="$(printf '%s' "$sock" | sed 's/[&/\]/\\&/g')"
  for f in "$AVAIL"/*; do
    [ -f "$f" ] || continue
    grep -q 'managed by OmarchWeb' "$f" 2>/dev/null || continue
    grep -q 'fastcgi_pass' "$f" 2>/dev/null || continue
    docroot="$(sed -n 's/.*root[[:space:]]*\([^;]*\);.*/\1/p' "$f" | tr -d ' ' | head -1)"
    [ -n "$docroot" ] || continue
    case "$docroot" in
      "$home"/*) ;;
      *) continue ;;
    esac
    grep -Fq "fastcgi_pass $sock;" "$f" 2>/dev/null && continue
    atomic_replace "$f" sed \
      -e "s|fastcgi_pass unix:/run/php-fpm/[^;]*;|fastcgi_pass ${esc};|g" \
      "$f" || return 1
  done
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
  [ -n "$docroot" ] || { echo "ERROR: vhost root must be set" >&2; return 1; }
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
    # Always refresh the mask with the named-user rights. A stale mask::r-x
    # leaves http unable to write even when u:http:rwx is present.
    if [ "$write" = "write" ]; then
      setfacl -R -m "u:http:${mode}" -m m::rwx "$docroot" 2>/dev/null || true
      setfacl -R -d -m u:http:rwX -m m::rwx "$docroot" 2>/dev/null || true
    else
      setfacl -R -m "u:http:${mode}" "$docroot" 2>/dev/null || true
    fi
  fi
}

# Reclaim files created when php-fpm ran as http (legacy pool) so the caller
# owns their WordPress tree again under the per-user OmarchWeb pool.
repair_wordpress_docroot_ownership() {
  local docroot="$1" user="$2"
  local count
  [ -n "$docroot" ] && [ -d "$docroot" ] || return 0
  pool_user_ok "$user" || return 0
  id http >/dev/null 2>&1 || return 0
  count="$(find "$docroot" -xdev \( -user http -o -group http \) 2>/dev/null | wc -l)"
  [ "${count:-0}" -eq 0 ] && return 0
  find "$docroot" -xdev \( -user http -o -group http \) \
    -exec chown "$user:$user" {} + 2>/dev/null || return 1
  echo "OK: reclaimed $count http-owned paths under $docroot"
}

# Collapse $HOME/~/Web and ~/Web into $HOME/Web in managed vhost files,
# and move any projects created under a literal ~/ directory.
repair_vhost_paths() {
  local home="$1"
  [ -n "$home" ] || return 0
  local f docroot src dest user
  user="$(caller_username)"
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
  # WordPress needs write ACLs (and a correct mask) on each managed docroot;
  # the Web/ grant above is read/traverse only.
  for f in "$AVAIL"/*; do
    [ -f "$f" ] || continue
    grep -q 'managed by OmarchWeb' "$f" 2>/dev/null || continue
    docroot="$(sed -n 's/.*root[[:space:]]*\([^;]*\);.*/\1/p' "$f" | tr -d ' ' | head -1)"
    [ -n "$docroot" ] && [ -d "$docroot" ] || continue
    case "$docroot" in
      "$home"/*) ;;
      *) continue ;;
    esac
    if grep -q '^# type wordpress' "$f" 2>/dev/null || [ -f "$docroot/wp-load.php" ]; then
      grant_http_access "$docroot" "write"
      repair_wordpress_docroot_ownership "$docroot" "$user"
    fi
  done
}

reload_nginx() {
  if ! command -v nginx >/dev/null 2>&1; then
    return 0
  fi
  # Config may have been invalid while nginx was down; only touch the unit after -t.
  nginx -t || return 1
  if systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx
  else
    systemctl start nginx
  fi
}

# Render the fixed OmarchWeb nginx server block. No caller text is interpolated
# beyond already-validated name/kind/host/root/port and the caller's pool sock.
render_vhost_conf() {
  local kind="$1" host="$2" root="$3" port="$4" sock="$5"
  cat <<EOF
# managed by OmarchWeb
# type $kind
server {
    listen $port;
    server_name $host;

    root $root;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass $sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF
}

vhost_install() {
  local name="$1" kind="$2" host="$3" root="$4" port="${5:-80}"
  local home user sock write=""
  name_ok "$name" || { echo "ERROR: invalid vhost name '$name'" >&2; return 1; }
  kind_ok "$kind" || { echo "ERROR: invalid vhost kind '$kind'" >&2; return 1; }
  host_ok "$host" || { echo "ERROR: invalid host '$host'" >&2; return 1; }
  port_ok "$port" || { echo "ERROR: invalid listen port '$port'" >&2; return 1; }

  home="$(caller_home)"
  docroot_ok "$root" "$home" || return 1
  user="$(caller_username)"
  pool_user_ok "$user" || { echo "ERROR: invalid pool user '$user'" >&2; return 1; }
  sock="unix:/run/php-fpm/omarchweb-${user}.sock"

  ensure_nginx_layout
  # Config is rendered entirely inside this root-owned snapshot — never from
  # a caller-supplied server block on stdin.
  render_vhost_conf "$kind" "$host" "$root" "$port" "$sock" \
    | atomic_replace "$AVAIL/$name"
  ln -sf "$AVAIL/$name" "$ENABLED/$name"
  if ! grep -Eq "(^|[[:space:]])$host([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    printf '%s\n' "127.0.0.1 $host" >> /etc/hosts
  fi
  repair_vhost_paths "$home"
  if [ "$kind" = "wordpress" ] || [ -f "$root/wp-load.php" ]; then
    write="write"
  fi
  grant_http_access "$root" "$write"
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
  # Resolve the allow-listed name to the unit systemd tracks: enable/disable
  # on an alias (redis -> valkey on Arch) does not touch the real unit.
  local unit
  unit="$(systemctl show -p Id --value "$1" 2>/dev/null || true)"
  unit="${unit%%$'\n'*}"
  [ -n "$unit" ] || unit="$1"
  if [ -n "$now" ]; then
    systemctl "$action" "$now" "$unit"
  else
    systemctl "$action" "$unit"
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
  # Arch's postgresql.service refuses to start until PGDATA has PG_VERSION +
  # base/ (see postgresql-check-db-dir). A previous failed init can leave an
  # empty directory; treat "initialized" the same way the unit does, not as
  # "directory exists".
  local pgroot=/var/lib/postgres
  local pgdata="$pgroot/data"
  local locale=""

  [ -f /usr/lib/systemd/system/postgresql.service ] || return 0
  command -v initdb >/dev/null 2>&1 || {
    echo "ERROR: initdb not found (install postgresql first)" >&2
    return 1
  }

  if [ -f "$pgdata/PG_VERSION" ] && [ -d "$pgdata/base" ]; then
    return 0
  fi

  mkdir -p "$pgroot"
  chown postgres:postgres "$pgroot"

  if [ -d "$pgdata" ]; then
    if [ -n "$(find "$pgdata" -mindepth 1 -print -quit 2>/dev/null)" ]; then
      echo "ERROR: $pgdata exists but is not an initialized cluster (no PG_VERSION)." >&2
      echo "ERROR: remove that directory only if it holds no data you need, then retry." >&2
      return 1
    fi
  else
    mkdir -p "$pgdata"
  fi
  chown postgres:postgres "$pgdata"
  chmod 0700 "$pgdata"

  # Match Arch wiki; fall back when C.UTF-8 is not generated on the system.
  if locale -a 2>/dev/null | grep -qiE '^C\.(utf-?8)$'; then
    locale="C.UTF-8"
  elif locale -a 2>/dev/null | grep -qiE '^en_US\.(utf-?8)$'; then
    locale="en_US.UTF-8"
  else
    locale="C"
  fi

  echo "Initializing PostgreSQL at $pgdata (locale=$locale)..."
  if command -v runuser >/dev/null 2>&1; then
    runuser -u postgres -- initdb -D "$pgdata" -E UTF8 --locale="$locale"
  else
    su -s /usr/bin/bash -l postgres -c \
      "initdb -D $(printf %q "$pgdata") -E UTF8 --locale=$(printf %q "$locale")"
  fi
}

case "${1:-}" in
  nginx-tune)
    [ "$#" -eq 1 ] || { echo "usage: root.sh nginx-tune" >&2; exit 1; }
    # Derived from the authenticated caller, never from an argument: this path
    # is interpolated into sed expressions over /etc/nginx configs.
    home="$(caller_home)"
    ensure_php_fpm_pool
    ensure_nginx_layout
    repair_vhost_paths "$home"
    repair_vhost_fpm_sockets "$home"
    reload_nginx
    echo "OK: nginx hash sizes updated and vhost paths repaired"
    ;;
  php-fpm-pool-ensure)
    [ "$#" -eq 1 ] || { echo "usage: root.sh php-fpm-pool-ensure" >&2; exit 1; }
    ensure_php_fpm_pool
    echo "OK: php-fpm pool ready for $(caller_username)"
    ;;
  vhost-install)
    # name kind host root [port] — config is rendered inside this helper.
    [ "$#" -eq 5 ] || [ "$#" -eq 6 ] || {
      echo "usage: root.sh vhost-install <name> <php|laravel|wordpress> <host> <root> [port]" >&2
      exit 1
    }
    vhost_install "$2" "$3" "$4" "$5" "${6:-80}"
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
  init-mariadb)
    [ "$#" -eq 1 ] || { echo "usage: root.sh init-mariadb" >&2; exit 1; }
    init_mariadb
    ;;
  init-postgres)
    [ "$#" -eq 1 ] || { echo "usage: root.sh init-postgres" >&2; exit 1; }
    init_postgres
    ;;
  php-ext)
    shift
    [ "$#" -ge 1 ] || { echo "usage: root.sh php-ext <ext...>" >&2; exit 1; }
    enable_php_ext "$@"
    ;;
  *)
    echo "unknown action: ${1:-}" >&2
    echo "usage: root.sh vhost-install|vhost-remove|nginx-tune|php-fpm-pool-ensure|systemctl|pacman|pacman-r|install-mailpit|remove-mailpit|grant-mariadb|grant-postgres|init-mariadb|init-postgres|php-ext" >&2
    exit 1
    ;;
esac
