#!/usr/bin/env bash
# OmarchWeb — virtual host management backend (Nginx).
#
# Generates an nginx server block for a PHP, Laravel, or WordPress
# project and enables it via sites-available/sites-enabled. PHP/Laravel
# vhosts get a project folder; WordPress vhosts download a pinned release
# (scripts/pins.sh) and verify its digest before extract.
#
# Conventions (all tunable via env):
#   OMARCHWEB_WEB_ROOT   base dir for projects           (default: ~/Web)
#   OMARCHWEB_NGINX_DIR  nginx config dir                (default: /etc/nginx)
#   OMARCHWEB_PORT       listen port for vhosts          (default: 80)
#
# Nginx server blocks are rendered inside the root-owned helper from
# allowlisted args (name, kind, host, root, port). The FPM socket is
# derived there from the calling user — never taken from this process.
#
# The privileged parts (writing nginx configs, /etc/hosts, reloading nginx)
# run through the root-owned helper snapshot via passwordless sudo when
# available, otherwise pkexec so the desktop polkit agent can prompt.

set -u
# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WEB_ROOT="${OMARCHWEB_WEB_ROOT:-$HOME/Web}"
NGINX_DIR="${OMARCHWEB_NGINX_DIR:-/etc/nginx}"
PORT="${OMARCHWEB_PORT:-80}"

fpm_sock_for_user() {
  local u="${1:-${USER:-}}"
  printf 'unix:/run/php-fpm/omarchweb-%s.sock' "$u"
}

AVAIL="$NGINX_DIR/sites-available"
ENABLED="$NGINX_DIR/sites-enabled"

ensure_php_fpm_pool() {
  omarchweb_elevate php-fpm-pool-ensure
}

prepare_php_vhost() {
  ensure_php_fpm_pool || return 1
}

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
      else
        type="other"
      fi
    fi
    printf '%s|%s|%s|%s\n' "$f" "$type" "$host" "$root"
  done
}

# WordPress asks for FTP when PHP-FPM (user http) cannot write, or when it
# refuses the "direct" filesystem method because files are owned by the
# desktop user. Force direct I/O with a fixed define — never caller text.
ensure_wordpress_direct_fs() {
  local dest="$1" f marker inserted
  [ -n "$dest" ] && [ -d "$dest" ] || return 0
  marker="/* That's all, stop editing!"
  for f in "$dest/wp-config.php" "$dest/wp-config-sample.php"; do
    [ -f "$f" ] || continue
    [ ! -L "$f" ] || continue
    if grep -Eq "^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]FS_METHOD['\"]" "$f"; then
      continue
    fi
    inserted="$(mktemp -p "$(dirname -- "$f")" ".wp-config.XXXXXX")" || return 1
    if grep -Fq "$marker" "$f"; then
      if ! awk -v marker="$marker" '
        index($0, marker) && !done {
          print "define('\''FS_METHOD'\'', '\''direct'\'');"
          print ""
          done=1
        }
        { print }
      ' "$f" > "$inserted"; then
        rm -f -- "$inserted"
        return 1
      fi
    else
      if ! { cat "$f"; printf '\n%s\n' "define('FS_METHOD', 'direct');"; } > "$inserted"; then
        rm -f -- "$inserted"
        return 1
      fi
    fi
    chmod --reference="$f" "$inserted" 2>/dev/null || chmod 0644 -- "$inserted"
    if ! mv -f -- "$inserted" "$f"; then
      rm -f -- "$inserted"
      return 1
    fi
    echo "OK: set FS_METHOD=direct in $f"
  done
}

# Allow php-fpm (http) to write plugins/uploads. Recalculates the ACL mask so
# a stale mask::r-x cannot silently drop the named-user write bit.
apply_wordpress_http_acls() {
  local dest="$1"
  [ -n "$dest" ] && [ -d "$dest" ] || return 0
  id http >/dev/null 2>&1 || return 0
  command -v setfacl >/dev/null 2>&1 || return 0
  setfacl -R -m u:http:rwX -m m::rwx "$dest" 2>/dev/null || true
  setfacl -R -d -m u:http:rwX -m m::rwx "$dest" 2>/dev/null || true
}

# Re-apply FS_METHOD + ACLs on every managed WordPress docroot (idempotent).
fix_wordpress_sites() {
  local name type host root
  while IFS='|' read -r name type host root; do
    [ -n "$root" ] || continue
    root="$(normalize_root "$root")"
    case "$root" in
      "$HOME"/*) ;;
      *) continue ;;
    esac
    [ -f "$root/wp-load.php" ] || [ "$type" = "wordpress" ] || continue
    [ -d "$root" ] || continue
    ensure_wordpress_direct_fs "$root"
    apply_wordpress_http_acls "$root"
  done < <(list_vhosts)
}

install_wordpress() {
  local dest="$1"
  mkdir -p "$dest" || return 1
  if [ -f "$dest/wp-load.php" ]; then
    echo "INFO: WordPress already present in $dest"
    ensure_wordpress_direct_fs "$dest"
    apply_wordpress_http_acls "$dest"
    return 0
  fi

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/omarchweb-wp.XXXXXX")" || return 1
  echo "Downloading WordPress $OMARCHWEB_WP_VERSION..."
  if ! omarchweb_fetch_verified "$OMARCHWEB_WP_URL" "$tmp/wordpress.tar.gz" \
      "$OMARCHWEB_WP_SHA256" "$OMARCHWEB_WP_MAX_BYTES"; then
    rm -rf "$tmp"
    return 1
  fi
  if ! omarchweb_open_pinned "$tmp/wordpress.tar.gz" "$OMARCHWEB_WP_SHA256"; then
    rm -rf "$tmp"
    return 1
  fi
  # SHA-1 and tar open /proc/self/fd/N (new description, offset 0) so the
  # pinned fd is not consumed and a replaced pathname cannot change the bytes.
  if command -v sha1sum >/dev/null 2>&1; then
    local sha1
    sha1="$(sha1sum -- "/proc/self/fd/$OMARCHWEB_PINNED_FD" | awk '{print $1}')"
    if [ "$sha1" != "$OMARCHWEB_WP_SHA1" ]; then
      exec {OMARCHWEB_PINNED_FD}<&-
      echo "ERROR: WordPress SHA1 mismatch" >&2
      rm -rf "$tmp"
      return 1
    fi
  fi
  if ! tar -xzf "/proc/self/fd/$OMARCHWEB_PINNED_FD" -C "$tmp" \
        --no-same-owner --no-same-permissions wordpress \
      || [ ! -d "$tmp/wordpress" ] || [ -L "$tmp/wordpress" ]; then
    exec {OMARCHWEB_PINNED_FD}<&-
    echo "ERROR: failed to extract WordPress" >&2
    rm -rf "$tmp"
    return 1
  fi
  exec {OMARCHWEB_PINNED_FD}<&-
  if ! cp -a "$tmp/wordpress/." "$dest/"; then
    echo "ERROR: failed to copy WordPress into $dest" >&2
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  ensure_wordpress_direct_fs "$dest"
  apply_wordpress_http_acls "$dest"
  echo "OK: WordPress $OMARCHWEB_WP_VERSION extracted to $dest"
}

# Prepare an empty Laravel project directory. Do not scaffold — the user runs
# composer create-project (or laravel new <name> --force from the parent).
prepare_laravel_project() {
  local dest="$1"
  local entries

  [ -n "$dest" ] || return 1
  mkdir -p "$dest" || return 1

  if [ -f "$dest/artisan" ]; then
    echo "INFO: Laravel already present in $dest"
    return 0
  fi

  # Drop the old OmarchWeb phpinfo stub so scaffolding can run into an empty dir.
  if [ -d "$dest/public" ] && [ -f "$dest/public/index.php" ] \
      && [ ! -f "$dest/artisan" ] \
      && grep -Fq 'phpinfo' "$dest/public/index.php" 2>/dev/null; then
    rm -rf -- "$dest/public"
  fi

  entries="$(find "$dest" -mindepth 1 -maxdepth 1 \
    ! -name '.DS_Store' ! -name '._*' 2>/dev/null | head -1)"
  if [ -n "$entries" ]; then
    echo "ERROR: $dest is not empty — remove it or choose another name." >&2
    echo "ERROR: leave the folder empty so you can run: composer create-project laravel/laravel ." >&2
    return 1
  fi

  echo "OK: empty Laravel project folder at $dest"
  echo "Next: cd $(printf %q "$dest")"
  echo "      composer create-project laravel/laravel ."
  echo "      # or: laravel/react-starter-kit | vue-starter-kit | livewire-starter-kit | svelte-starter-kit"
  echo "      (or from the parent: laravel new $(basename -- "$dest") --force [--react|--vue|--livewire|--svelte])"
  echo "      Note: 'laravel new .' fails on current installer — it treats '.' as already existing."
}

add_vhost() {
  # add <name> <type> [host] [root]
  local name="$1" type="$2"
  local host="${3:-}"
  local root="${4:-}"

  name_ok "$name" || { echo "ERROR: invalid vhost name '$name'" >&2; return 1; }
  [ "$type" = "php" ] || [ "$type" = "laravel" ] || [ "$type" = "wordpress" ] || {
    echo "ERROR: unknown type '$type' (php|laravel|wordpress)" >&2; return 1; }
  [ -z "$host" ] && host="${name}.test"
  host_ok "$host" || { echo "ERROR: invalid host '$host'" >&2; return 1; }

  ensure_dirs

  if [ -f "$AVAIL/$name" ]; then
    echo "ERROR: vhost '$name' already exists" >&2
    return 1
  fi

  local kind="$type"
  local nginx_type="$type"
  local project=""

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

  case "$kind" in
    wordpress|laravel|php)
      prepare_php_vhost || return 1
      ;;
  esac

  if [ "$kind" = "wordpress" ]; then
    omarchweb_elevate php-ext mysqli || return 1
    install_wordpress "$root" || return 1
  elif [ "$kind" = "laravel" ]; then
    case "$root" in
      */public) project="${root%/public}" ;;
      *) project="$root" ;;
    esac
    [ -n "$project" ] || project="$WEB_ROOT/$name"
    prepare_laravel_project "$project" || return 1
    root="$project/public"
  elif [ "$nginx_type" = "php" ]; then
    mkdir -p "$root"
    if [ ! -f "$root/index.php" ]; then
      printf '%s\n' '<?php phpinfo(); ?>' > "$root/index.php"
    fi
  fi

  # Helper renders the fixed server block from allowlisted args only.
  if ! omarchweb_elevate vhost-install "$name" "$kind" "$host" "$root" "$PORT"; then
    return 1
  fi

  echo "OK: enabled vhost '$name' ($kind) at $host -> $root"
}

remove_vhost() {
  local name="$1"
  name_ok "$name" || { echo "ERROR: invalid vhost name '$name'" >&2; return 1; }
  omarchweb_elevate vhost-remove "$name" || return 1
  echo "OK: removed vhost '$name'"
}

vhost_url_for() {
  local host="$1"
  local url="http://${host}"
  if [ "$PORT" != "80" ]; then
    url="${url}:${PORT}"
  fi
  printf '%s\n' "$url"
}

# Resolve a managed vhost from an explicit name or the current working directory.
# Prints: name|type|host|root|url
resolve_vhost() {
  local want="${1:-}"
  local cwd name type host root project best_name="" best_type="" best_host="" best_root="" best_len=0
  cwd="$(pwd -P 2>/dev/null || pwd)"

  while IFS='|' read -r name type host root; do
    [ -n "$name" ] || continue
    root="$(normalize_root "$root")"
    if [ -n "$want" ]; then
      if [ "$name" = "$want" ] || [ "$host" = "$want" ]; then
        printf '%s|%s|%s|%s|%s\n' "$name" "$type" "$host" "$root" "$(vhost_url_for "$host")"
        return 0
      fi
      continue
    fi

    project="$root"
    case "$type" in
      laravel)
        case "$root" in
          */public) project="${root%/public}" ;;
        esac
        ;;
    esac

    case "$cwd" in
      "$root"|"$root"/*|"$project"|"$project"/*)
        if [ "${#project}" -gt "$best_len" ]; then
          best_len="${#project}"
          best_name="$name"
          best_type="$type"
          best_host="$host"
          best_root="$root"
        fi
        ;;
    esac
  done < <(list_vhosts)

  if [ -n "$want" ]; then
    echo "ERROR: no OmarchWeb vhost named '$want'" >&2
    return 1
  fi
  if [ -z "$best_name" ]; then
    echo "ERROR: cwd is not inside an OmarchWeb vhost project ($cwd)" >&2
    echo "ERROR: cd into ~/Web/<site> (or pass a vhost name)" >&2
    return 1
  fi
  printf '%s|%s|%s|%s|%s\n' "$best_name" "$best_type" "$best_host" "$best_root" "$(vhost_url_for "$best_host")"
}

print_vhost_url() {
  local row url
  row="$(resolve_vhost "${1:-}")" || return 1
  url="$(printf '%s\n' "$row" | cut -d'|' -f5)"
  printf '%s\n' "$url"
}

open_vhost_url() {
  local row url
  row="$(resolve_vhost "${1:-}")" || return 1
  url="$(printf '%s\n' "$row" | cut -d'|' -f5)"
  if ! command -v xdg-open >/dev/null 2>&1; then
    echo "ERROR: xdg-open not found" >&2
    echo "$url"
    return 1
  fi
  echo "Opening $url"
  xdg-open "$url" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

case "${1:-}" in
  list) list_vhosts ;;
  add)
    shift
    add_vhost "$@"
    ;;
  tune)
    prepare_php_vhost || exit 1
    fix_wordpress_sites
    omarchweb_elevate nginx-tune
    ;;
  fix-wordpress)
    prepare_php_vhost || exit 1
    fix_wordpress_sites
    omarchweb_elevate nginx-tune
    echo "OK: WordPress FS_METHOD, http write ACLs, and ownership repaired"
    ;;
  remove)
    [ "$#" -lt 2 ] && { echo "usage: vhost.sh remove <name>" >&2; exit 1; }
    remove_vhost "$2"
    ;;
  url)
    print_vhost_url "${2:-}"
    ;;
  open)
    open_vhost_url "${2:-}"
    ;;
  *)
    echo "unknown action: ${1:-}" >&2
    echo "usage: vhost.sh list | add <name> <php|laravel|wordpress> [host] [root] | remove <name> | tune | fix-wordpress | open [name] | url [name]" >&2
    exit 1
    ;;
esac
