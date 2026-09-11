#!/usr/bin/env bash
# Encode the marketplace privilege / supply-chain review as local checks.
#
#   bash test/security.sh
#
# Each failure names the review finding it corresponds to. No root required.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass=0
fail=0
# shellcheck disable=SC2329
ok() { printf 'ok  %s\n' "$1"; pass=$((pass + 1)); }
# shellcheck disable=SC2329
bad() { printf 'FAIL  %s\n    %s\n' "$1" "$2"; fail=$((fail + 1)); }

# shellcheck source=../scripts/lib.sh
. "$ROOT/scripts/lib.sh"

echo "== static: privilege TOCTOU =="

if grep -nE 'sudo .*"\$omarchweb_scripts|pkexec .*"\$omarchweb_scripts' scripts/lib.sh; then
  bad "helper-from-checkout" \
    "lib.sh still passes a user-writable plugin path to sudo/pkexec (review: execute a root-owned snapshot instead)."
else
  ok "lib.sh does not sudo/pkexec the plugin checkout"
fi

if grep -nE 'sudo .*"\$omarchweb_root"|pkexec .*"\$omarchweb_root"' scripts/lib.sh; then
  bad "helper-from-checkout-var" \
    "lib.sh still elevates \$omarchweb_root from the checkout."
else
  ok "lib.sh does not elevate \$omarchweb_root"
fi

if grep -q '/usr/local/libexec/omarchweb/root.sh' scripts/lib.sh scripts/pins.sh; then
  ok "helper dest is the root-owned snapshot path"
else
  bad "helper-dest" "expected hardcoded /usr/local/libexec/omarchweb/root.sh"
fi

got="$(omarchweb_sha256 "$ROOT/scripts/root.sh")"
if [ "$got" = "$OMARCHWEB_HELPER_SHA256" ]; then
  ok "pins.sh helper digest matches scripts/root.sh"
else
  bad "helper-digest-drift" \
    "OMARCHWEB_HELPER_SHA256=$OMARCHWEB_HELPER_SHA256 but scripts/root.sh is $got — update pins.sh after editing root.sh."
fi

prog="$(omarchweb_helper_install_program)" || prog=""
if printf '%s' "$prog" | grep -q '/usr/local/libexec/omarchweb/root.sh' \
  && printf '%s' "$prog" | grep -q "$OMARCHWEB_HELPER_SHA256"; then
  ok "snapshot installer hardcodes dest + digest"
else
  bad "snapshot-installer" "install program must hardcode dest and the reviewed digest"
fi
if printf '%s' "$prog" | grep -q "$ROOT"; then
  bad "snapshot-installer-path" "install program must not embed the plugin checkout path"
else
  ok "snapshot installer does not embed the checkout path"
fi
if printf '%s' "$prog" | grep -q 'parent=/usr/local/libexec' \
  && printf '%s' "$prog" | grep -q 'chmod 0755 "\$parent"'; then
  ok "snapshot installer makes /usr/local/libexec traversable"
else
  bad "libexec-traverse" "install program must chmod 0755 /usr/local/libexec for post-install verify"
fi

echo "== behavioral: descriptor binding (TOCTOU) =="

toctou="$(mktemp -d "${TMPDIR:-/tmp}/omarchweb-toctou.XXXXXX")"
printf '%s\n' 'reviewed-helper-bytes' > "$toctou/root.sh"
expected="$(omarchweb_sha256 "$toctou/root.sh")"
if omarchweb_open_pinned "$toctou/root.sh" "$expected"; then
  # Truncate-in-place AND replace the directory entry — both must leave the
  # pinned fd unchanged (this is the polkit-prompt race).
  printf '%s\n' 'MALWARE-TRUNCATED-THE-INODE' > "$toctou/root.sh"
  printf '%s\n' 'MALWARE-REPLACED-THE-PATH' > "$toctou/root.sh.new"
  mv -f "$toctou/root.sh.new" "$toctou/root.sh"
  bound="$(omarchweb_sha256 "/proc/self/fd/$OMARCHWEB_PINNED_FD")"
  pathnow="$(omarchweb_sha256 "$toctou/root.sh")"
  exec {OMARCHWEB_PINNED_FD}<&-
  if [ "$bound" = "$expected" ] && [ "$pathnow" != "$expected" ]; then
    ok "pinned snapshot is unchanged after the checkout file is replaced"
  else
    bad "descriptor-toctou" \
      "after replacing the pathname, fd digest=$bound path digest=$pathnow expected=$expected"
  fi
else
  bad "open-pinned" "omarchweb_open_pinned rejected a valid file"
fi
rm -rf "$toctou"

mismatch="$(mktemp)"
printf '%s\n' 'not-the-helper' > "$mismatch"
if omarchweb_open_pinned "$mismatch" "$OMARCHWEB_HELPER_SHA256" 2>/dev/null; then
  exec {OMARCHWEB_PINNED_FD}<&-
  bad "digest-mismatch" "open_pinned accepted a file that does not match the pin"
else
  ok "open_pinned rejects a digest mismatch"
fi
rm -f "$mismatch"

echo "== static: supply chain =="

if grep -nE 'latest\.tar\.gz|wordpress.org/latest' scripts/*.sh; then
  bad "wordpress-unpinned" \
    "WordPress still downloads latest.tar.gz (review: pin version + digest + size limit)."
else
  ok "WordPress URL is not latest.tar.gz"
fi

if grep -q 'wordpress-7.1.tar.gz' scripts/pins.sh \
  && grep -q "$OMARCHWEB_WP_SHA256" scripts/pins.sh \
  && grep -q 'max-filesize' scripts/lib.sh; then
  ok "WordPress version, SHA-256, and curl --max-filesize are pinned"
else
  bad "wordpress-pins" "missing version, digest, or download size limit"
fi

if grep -q 'omarchweb_open_pinned' scripts/vhost.sh \
  && grep -q 'OMARCHWEB_PINNED_FD' scripts/vhost.sh \
  && ! grep -nE 'tar -xzf "\$tmp/wordpress' scripts/vhost.sh; then
  ok "WordPress extract is descriptor-bound after digest verify"
else
  bad "wordpress-pathname" \
    "vhost.sh must extract WordPress from a digest-pinned fd, not the download pathname."
fi

if grep -Fq "define('FS_METHOD', 'direct')" scripts/vhost.sh \
  && grep -q 'ensure_wordpress_direct_fs' scripts/vhost.sh \
  && grep -q 'apply_wordpress_http_acls' scripts/vhost.sh; then
  ok "WordPress install forces FS_METHOD=direct and http write ACLs"
else
  bad "wordpress-fs-method" \
    "vhost.sh must set a fixed FS_METHOD=direct define and refresh http write ACLs."
fi

if grep -q 'm::rwx' scripts/root.sh scripts/vhost.sh \
  && grep -q 'grant_http_access "\$docroot" "write"' scripts/root.sh; then
  ok "WordPress ACL path refreshes mask::rwx on managed docroots"
else
  bad "wordpress-acl-mask" \
    "root.sh/vhost.sh must set m::rwx when granting http write on WordPress trees."
fi

if grep -q 'repair_wordpress_docroot_ownership' scripts/root.sh \
  && grep -q '\-user http -o -group http' scripts/root.sh \
  && grep -q 'repair_wordpress_docroot_ownership "\$docroot" "\$user"' scripts/root.sh; then
  ok "WordPress tune reclaims http-owned files under managed docroots"
else
  bad "wordpress-ownership-repair" \
    "root.sh must chown http-owned paths under managed WordPress docroots on tune."
fi

if grep -n 'laravel/installer"' scripts/setup.sh | grep -v "${OMARCHWEB_LARAVEL_INSTALLER_VERSION}"; then
  bad "composer-unpinned" "composer require must pin laravel/installer:${OMARCHWEB_LARAVEL_INSTALLER_VERSION}"
elif grep -q "laravel/installer:\${OMARCHWEB_LARAVEL_INSTALLER_VERSION}" scripts/setup.sh; then
  ok "Composer laravel/installer is version-pinned"
else
  bad "composer-unpinned" "setup.sh must require laravel/installer with a pinned version"
fi

if grep -nE 'pacman-u|yay -S|makepkg' scripts/*.sh; then
  bad "aur-pathname" \
    "AUR build artifact still passed to the helper (review: descriptor/digest-bound or pinned release)."
else
  ok "no AUR pathname passed to the privileged helper"
fi

if grep -q 'install-mailpit' scripts/root.sh scripts/setup.sh \
  && grep -q "$OMARCHWEB_MAILPIT_SHA256_AMD64" scripts/root.sh \
  && grep -q "$OMARCHWEB_MAILPIT_SHA256_ARM64" scripts/root.sh; then
  ok "Mailpit is a pinned GitHub release baked into the helper snapshot"
else
  bad "mailpit-pins" "root.sh must bake in the same Mailpit digests as pins.sh"
fi

amd_root="$(sed -n 's/^MAILPIT_SHA256_AMD64="//p' scripts/root.sh | tr -d '"')"
arm_root="$(sed -n 's/^MAILPIT_SHA256_ARM64="//p' scripts/root.sh | tr -d '"')"
if [ "$amd_root" = "$OMARCHWEB_MAILPIT_SHA256_AMD64" ] \
  && [ "$arm_root" = "$OMARCHWEB_MAILPIT_SHA256_ARM64" ]; then
  ok "root.sh Mailpit digests match pins.sh"
else
  bad "mailpit-digest-drift" "root.sh AMD64=$amd_root ARM64=$arm_root"
fi

echo "== static: generic root filesystem primitive =="

if grep -nE 'install-dir|install -d' scripts/*.sh; then
  bad "generic-install-d" \
    "privileged helper still uses install -d (review: allowlisted mkdir/chown of exact paths)."
else
  ok "no generic install-dir / install -d primitive"
fi

out="$(scripts/root.sh install-dir /tmp/omarchweb-should-not-exist 2>&1 || true)"
if printf '%s' "$out" | grep -q 'unknown action'; then
  ok "root.sh rejects install-dir"
else
  bad "install-dir-action" "root.sh install-dir should be an unknown action; got: $out"
fi

out="$(scripts/root.sh pacman-u /tmp/mailpit.pkg.tar.zst 2>&1 || true)"
if printf '%s' "$out" | grep -q 'unknown action'; then
  ok "root.sh rejects pacman-u pathname install"
else
  bad "pacman-u-action" "root.sh pacman-u should be an unknown action; got: $out"
fi

# A root-run `mariadb`/`psql` accepting caller options is a generic root
# primitive (--tee writes as root, COPY FROM PROGRAM executes). Only the two
# narrow grant operations may cross the boundary.
for act in mariadb postgres; do
  out="$(scripts/root.sh "$act" -e 'SELECT 1;' 2>&1 || true)"
  if printf '%s' "$out" | grep -q 'unknown action'; then
    ok "root.sh rejects the generic '$act' client passthrough"
  else
    bad "db-client-passthrough" \
      "root.sh '$act' must not forward caller arguments to a privileged client; got: $out"
  fi
done

if grep -nE 'omarchweb_elevate (mariadb|postgres)([[:space:]]|$)' scripts/*.sh; then
  bad "db-elevate-passthrough" \
    "a backend still elevates a raw database client (use grant-mariadb/grant-postgres)."
else
  ok "no backend elevates a raw database client"
fi

for u in root postgres 'ev;il' '' 'a b'; do
  out="$(scripts/root.sh grant-mariadb "$u" 2>&1 || true)"
  if printf '%s' "$out" | grep -qE 'invalid database user|usage: root.sh grant-mariadb'; then
    :
  else
    bad "grant-user-validation" "grant-mariadb accepted role '$u'; got: $out"
    break
  fi
done
ok "grant-mariadb rejects system and non-identifier role names"

# systemctl enable accepts a unit *pathname*, so a smuggled extra argument
# alongside an allow-listed service would link an arbitrary unit as root.
smuggled=0
for args in "start mariadb /tmp/evil.service" "enable mariadb /tmp/evil.service" \
  "enable --now mariadb /tmp/evil.service" "disable mariadb extra"; do
  # shellcheck disable=SC2086
  out="$(scripts/root.sh systemctl $args 2>&1 || true)"
  if ! printf '%s' "$out" | grep -q 'exactly one service'; then
    bad "systemctl-extra-args" "root.sh systemctl $args was not refused; got: $out"
    smuggled=1
    break
  fi
done
[ "$smuggled" -eq 0 ] && ok "root.sh systemctl takes exactly one allow-listed unit"

if grep -n 'omarchweb_elevate nginx-tune "\$HOME"' scripts/*.sh; then
  bad "nginx-tune-home-arg" \
    "nginx-tune still takes a caller-supplied home (it is interpolated into sed over /etc/nginx)."
else
  ok "nginx-tune derives the home from the authenticated caller"
fi

out="$(scripts/root.sh nginx-tune /etc 2>&1 || true)"
if printf '%s' "$out" | grep -q 'usage: root.sh nginx-tune'; then
  ok "root.sh nginx-tune refuses a caller-supplied path"
else
  bad "nginx-tune-arg" "nginx-tune should take no arguments; got: $out"
fi

out="$(scripts/root.sh init-postgres /etc 2>&1 || true)"
if printf '%s' "$out" | grep -q 'usage: root.sh init-postgres'; then
  ok "root.sh init-postgres refuses extra arguments"
else
  bad "init-postgres-arg" "init-postgres should take no arguments; got: $out"
fi

if grep -q 'PG_VERSION' scripts/root.sh \
  && grep -q 'Initializing PostgreSQL' scripts/root.sh \
  && ! grep -nE 'initdb .* \|\| true' scripts/root.sh; then
  ok "postgres init checks PG_VERSION and does not swallow initdb failures"
else
  bad "postgres-init" \
    "init_postgres must key off PG_VERSION/base and must not '|| true' initdb."
fi

if grep -q 'init-postgres' scripts/services.sh; then
  ok "starting postgresql ensures the cluster is initialized first"
else
  bad "postgres-start-init" "services.sh start/restart postgresql must call init-postgres."
fi

out="$(scripts/root.sh init-mariadb /var/lib/mysql 2>&1 || true)"
if printf '%s' "$out" | grep -q 'usage: root.sh init-mariadb'; then
  ok "root.sh init-mariadb refuses extra arguments"
else
  bad "init-mariadb-arg" "init-mariadb should take no arguments; got: $out"
fi

out="$(scripts/root.sh php-fpm-pool-ensure extra 2>&1 || true)"
if printf '%s' "$out" | grep -q 'usage: root.sh php-fpm-pool-ensure'; then
  ok "root.sh php-fpm-pool-ensure refuses extra arguments"
else
  bad "php-fpm-pool-arg" "php-fpm-pool-ensure should take no arguments; got: $out"
fi

if grep -q 'php-fpm-pool-ensure' scripts/root.sh scripts/vhost.sh scripts/setup.sh \
  && grep -q '/etc/php/php-fpm.d/omarchweb-' scripts/root.sh \
  && grep -q 'pool_user_ok' scripts/root.sh \
  && ! grep -nE 'omarchweb_elevate php-fpm-pool-ensure[[:space:]]+"\$' scripts/*.sh; then
  ok "php-fpm pool is a fixed-path helper action with a validated caller username"
else
  bad "php-fpm-pool-review" \
    "pool ensure must hardcode /etc/php/php-fpm.d/omarchweb-<user>.conf and take no caller path."
fi

if grep -q 'fpm_sock_for_user' scripts/vhost.sh \
  && grep -q 'omarchweb-%s.sock' scripts/vhost.sh \
  && grep -q 'prepare_php_vhost' scripts/vhost.sh; then
  ok "vhost PHP sites default to the per-user OmarchWeb pool socket"
else
  bad "vhost-fpm-socket" "vhost.sh must use a per-user omarchweb pool socket for PHP sites."
fi

if grep -q 'repair_vhost_fpm_sockets' scripts/root.sh \
  && grep -q 'fastcgi_pass unix:/run/php-fpm/' scripts/root.sh; then
  ok "nginx-tune rewires managed vhost fastcgi_pass to the caller pool"
else
  bad "vhost-fpm-rewire" "root.sh nginx-tune must repair fastcgi_pass for managed vhosts."
fi

if grep -qE 'php\|laravel\|wordpress' scripts/vhost.sh \
  && ! grep -q 'proxy_pass' scripts/vhost.sh \
  && ! grep -qE '"node"|"static"' Panel.qml \
  && ! grep -qE 'php\|static\|laravel|php\|laravel\|wordpress\|node' scripts/vhost.sh \
  && ! grep -q 'repair_node_vhost_locations' scripts/root.sh; then
  ok "creatable vhost types are php|laravel|wordpress only"
else
  bad "vhost-types" \
    "creatable types must be php|laravel|wordpress (no node/static/proxy_pass)."
fi

if grep -q 'prepare_laravel_project' scripts/vhost.sh \
  && ! grep -nE '\$\(laravel_bin\)|"\$bin" new |[^:]laravel new \. --' scripts/vhost.sh; then
  ok "Laravel vhosts leave an empty project folder for the user to scaffold"
else
  bad "laravel-scaffold" \
    "vhost.sh must prepare an empty Laravel project dir and not run laravel new itself."
fi

if grep -q 'open_vhost_url' scripts/vhost.sh \
  && grep -q 'resolve_vhost' scripts/vhost.sh \
  && grep -q 'install_cli_wrappers' scripts/cli.sh \
  && grep -q 'cli.sh" install-cli' scripts/setup.sh; then
  ok "CLI can open/url the vhost for cwd and installs omarchweb/web wrappers"
else
  bad "cli-open" \
    "vhost.sh open/url + cli.sh install-cli (from setup) are required."
fi

echo "== CLI wrapper install (marketplace: refuse foreign files, atomic write) =="

if grep -nE 'cat > "\$dest_dir/\$wrapper"|cat > "\$\{?dest_dir' scripts/cli.sh; then
  bad "cli-blind-truncate" \
    "install_cli_wrappers still truncates wrappers with cat > (review: atomic write)."
else
  ok "CLI install does not blind-truncate with cat >"
fi

if grep -q 'cli_atomic_write' scripts/cli.sh \
  && grep -q 'mktemp -p' scripts/cli.sh \
  && grep -q 'mv -f -- "\$tmp" "\$dest"' scripts/cli.sh \
  && grep -q '# managed by OmarchWeb' scripts/cli.sh \
  && grep -q 'refusing to overwrite' scripts/cli.sh; then
  ok "CLI install uses owned-marker checks and atomic rename"
else
  bad "cli-atomic-owned" \
    "cli.sh must refuse non-owned targets and write via mktemp+fsync+mv."
fi

cli_tmp="$(mktemp -d "${TMPDIR:-/tmp}/omarchweb-cli.XXXXXX")"
# Fresh install into an empty bin dir.
if OMARCHWEB_CLI_BIN_DIR="$cli_tmp" scripts/cli.sh install-cli >/dev/null \
  && [ -f "$cli_tmp/web" ] && [ ! -L "$cli_tmp/web" ] \
  && [ -f "$cli_tmp/omarchweb" ] && [ ! -L "$cli_tmp/omarchweb" ] \
  && grep -q '^# managed by OmarchWeb' "$cli_tmp/web" \
  && grep -Fq "$ROOT/scripts/cli.sh" "$cli_tmp/web"; then
  ok "CLI install creates owned regular wrappers"
else
  bad "cli-install-fresh" "failed to install wrappers into an empty directory"
fi

# Reinstall over our own wrappers must succeed (refresh / stale path update).
if OMARCHWEB_CLI_BIN_DIR="$cli_tmp" scripts/cli.sh install-cli >/dev/null; then
  ok "CLI install may refresh OmarchWeb-owned wrappers"
else
  bad "cli-install-refresh" "refused to replace our own managed wrappers"
fi

# Legacy unmarked wrappers (pre-# managed marker) must be refreshable.
legacy_tmp="$(mktemp -d "${TMPDIR:-/tmp}/omarchweb-cli-legacy.XXXXXX")"
cat > "$legacy_tmp/web" <<EOF
#!/usr/bin/env bash
exec $ROOT/scripts/cli.sh "\$@"
EOF
cat > "$legacy_tmp/omarchweb" <<EOF
#!/usr/bin/env bash
exec $ROOT/scripts/cli.sh "\$@"
EOF
chmod 0755 "$legacy_tmp/web" "$legacy_tmp/omarchweb"
if OMARCHWEB_CLI_BIN_DIR="$legacy_tmp" scripts/cli.sh install-cli >/dev/null \
  && grep -q '^# managed by OmarchWeb' "$legacy_tmp/web" \
  && grep -q '^# managed by OmarchWeb' "$legacy_tmp/omarchweb"; then
  ok "CLI install upgrades legacy unmarked OmarchWeb wrappers"
else
  bad "cli-install-legacy" "should replace pre-marker wrappers that exec this plugin's cli.sh"
fi
rm -rf -- "$legacy_tmp"

# Unrelated regular file must be refused and left intact.
printf '%s\n' 'FOREIGN-TOOL' > "$cli_tmp/foreign-bin"
mv -f "$cli_tmp/web" "$cli_tmp/web.bak" 2>/dev/null || true
printf '%s\n' 'FOREIGN-TOOL' > "$cli_tmp/web"
out="$(OMARCHWEB_CLI_BIN_DIR="$cli_tmp" scripts/cli.sh install-cli 2>&1 || true)"
if printf '%s' "$out" | grep -q 'refusing to overwrite' \
  && grep -qx 'FOREIGN-TOOL' "$cli_tmp/web"; then
  ok "CLI install refuses an unrelated regular file"
else
  bad "cli-refuse-foreign" "should refuse foreign ~/.local/bin/web; got: $out"
fi
rm -f -- "$cli_tmp/web"
mv -f "$cli_tmp/web.bak" "$cli_tmp/web" 2>/dev/null || true

# Symlink must be refused; linked target must stay untouched.
precious="$cli_tmp/precious-target"
printf '%s\n' 'DO-NOT-CLOBBER' > "$precious"
rm -f -- "$cli_tmp/web"
ln -s "$(basename -- "$precious")" "$cli_tmp/web"
out="$(OMARCHWEB_CLI_BIN_DIR="$cli_tmp" scripts/cli.sh install-cli 2>&1 || true)"
if printf '%s' "$out" | grep -q 'refusing to overwrite' \
  && [ -L "$cli_tmp/web" ] \
  && grep -qx 'DO-NOT-CLOBBER' "$precious"; then
  ok "CLI install refuses a symlink and does not follow it"
else
  bad "cli-refuse-symlink" \
    "should refuse symlink wrappers without touching the target; got: $out"
fi

rm -rf -- "$cli_tmp"

# The vhost document root is the one caller-supplied path root grants ACLs on.
confined=0
for r in /etc/evil "$PWD/../etc/evil" relative/path; do
  out="$(printf 'server {\n    root %s;\n}\n' "$r" \
    | SUDO_UID=0 scripts/root.sh vhost-install probe probe.test 2>&1 || true)"
  if ! printf '%s' "$out" | grep -q 'ERROR: vhost root must'; then
    bad "vhost-docroot" "vhost root '$r' was not refused; got: $out"
    confined=1
    break
  fi
done
[ "$confined" -eq 0 ] && ok "vhost document root is confined to the caller's home"

size="$(wc -c < scripts/root.sh)"
if [ "$size" -lt 1048576 ]; then
  ok "helper source is under the 1MiB snapshot size limit ($size bytes)"
else
  bad "helper-too-large" "scripts/root.sh is $size bytes; snapshot installer dd-caps at 1MiB"
fi

bash -n scripts/lib.sh scripts/root.sh scripts/setup.sh scripts/vhost.sh \
  scripts/pins.sh scripts/db.sh scripts/services.sh scripts/cli.sh test/security.sh
ok "bash -n on all scripts"

echo
if [ "$fail" -gt 0 ]; then
  echo "$fail failed, $pass passed"
  exit 1
fi
echo "all $pass checks passed"
