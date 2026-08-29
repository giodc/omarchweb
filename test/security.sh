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

if grep -nE 'install-dir|install -d "\$\{' scripts/*.sh; then
  bad "generic-install-d" \
    "privileged helper still forwards arguments to install -d (review: allowlisted paths only)."
else
  ok "no generic install-dir / install -d \"\${...}\" primitive"
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
  scripts/pins.sh scripts/db.sh scripts/services.sh test/security.sh
ok "bash -n on all scripts"

echo
if [ "$fail" -gt 0 ]; then
  echo "$fail failed, $pass passed"
  exit 1
fi
echo "all $pass checks passed"
