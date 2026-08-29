# OmarchWeb — shared helpers (sourced by the other scripts).
#
# Privilege: backends are launched from the bar panel (no TTY). The reviewed
# helper is installed as a root-owned snapshot under /usr/local/libexec, then
# sudo/pkexec execute that file — never the user-writable plugin checkout.

# shellcheck source=pins.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pins.sh"

omarchweb_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
omarchweb_helper_dest="$OMARCHWEB_HELPER_DEST"
omarchweb_helper_sha256="$OMARCHWEB_HELPER_SHA256"

omarchweb_digest_ok() {
  case "$1" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

omarchweb_sha256() {
  sha256sum -- "$1" | awk '{print $1}'
}

omarchweb_fetch_verified() {
  local url="$1" dest="$2" sha256="$3" max_bytes="$4"
  omarchweb_digest_ok "$sha256" || { echo "ERROR: invalid digest pin" >&2; return 1; }
  [ "$max_bytes" -gt 0 ] 2>/dev/null || { echo "ERROR: invalid size limit" >&2; return 1; }
  command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; return 1; }
  if ! curl -fL --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 20 \
      --max-filesize "$max_bytes" -o "$dest" "$url"; then
    echo "ERROR: download failed: $url" >&2
    rm -f -- "$dest"
    return 1
  fi
  local got size
  size="$(stat -c '%s' -- "$dest")"
  if [ "$size" -gt "$max_bytes" ]; then
    echo "ERROR: downloaded file exceeds size limit ($size > $max_bytes)" >&2
    rm -f -- "$dest"
    return 1
  fi
  got="$(omarchweb_sha256 "$dest")"
  if [ "$got" != "$sha256" ]; then
    echo "ERROR: digest mismatch for $url" >&2
    echo "ERROR: expected $sha256" >&2
    echo "ERROR: got      $got" >&2
    rm -f -- "$dest"
    return 1
  fi
}

# Copy path to a private unlinked inode, then hash that. The original pathname
# can be replaced (or truncated) during a later polkit prompt without changing
# the bytes we will install.
omarchweb_open_pinned() {
  local path="$1" expected="$2" got priv dir
  omarchweb_digest_ok "$expected" || { echo "ERROR: invalid digest pin" >&2; return 1; }
  [ -f "$path" ] || { echo "ERROR: missing $path" >&2; return 1; }
  dir="${XDG_RUNTIME_DIR:-}"
  if [ -z "$dir" ] || [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
    dir="${TMPDIR:-/tmp}"
  fi
  priv="$(mktemp -p "$dir" omarchweb-pin.XXXXXX)" || return 1
  chmod 0600 -- "$priv" || { rm -f -- "$priv"; return 1; }
  if ! cp -- "$path" "$priv"; then
    rm -f -- "$priv"
    return 1
  fi
  got="$(omarchweb_sha256 "$priv")"
  if [ "$got" != "$expected" ]; then
    rm -f -- "$priv"
    echo "ERROR: digest mismatch: $path" >&2
    echo "ERROR: expected $expected" >&2
    echo "ERROR: got      $got" >&2
    return 1
  fi
  exec {OMARCHWEB_PINNED_FD}<"$priv" || { rm -f -- "$priv"; return 1; }
  rm -f -- "$priv"
}

omarchweb_helper_mode_ok() {
  local dest="$1" uid mode
  [ -f "$dest" ] && [ ! -L "$dest" ] || return 1
  uid="$(stat -c '%u' -- "$dest")"
  mode="$(stat -c '%a' -- "$dest")"
  [ "$uid" = "0" ] || return 1
  case "$mode" in
    555|0555|755|0755) return 0 ;;
    *) return 1 ;;
  esac
}

omarchweb_helper_current() {
  omarchweb_helper_mode_ok "$omarchweb_helper_dest" || return 1
  [ "$(omarchweb_sha256 "$omarchweb_helper_dest")" = "$omarchweb_helper_sha256" ]
}

# Literal program executed as /usr/bin/bash -c by pkexec/sudo. Dest, mode, and
# digest are constants so root never runs a user-writable pathname.
omarchweb_helper_install_program() {
  omarchweb_digest_ok "$omarchweb_helper_sha256" || return 1
  cat <<EOF
set -euo pipefail
PATH=/usr/bin:/usr/sbin:/bin:/sbin
umask 077
dest=/usr/local/libexec/omarchweb/root.sh
dir=/usr/local/libexec/omarchweb
parent=/usr/local/libexec
expected=${omarchweb_helper_sha256}
mkdir -p "\$dir"
# Parent is often 0700 on Arch; unprivileged verify (stat/sha256) needs traverse.
if [ -d "\$parent" ]; then
  chmod 0755 "\$parent"
  chown root:root "\$parent"
fi
chmod 0755 "\$dir"
chown root:root "\$dir"
tmp=\$(mktemp -p "\$dir" .root.XXXXXX)
dd bs=4096 count=256 of="\$tmp" status=none
got=\$(sha256sum -- "\$tmp" | awk '{print \$1}')
if [ "\$got" != "\$expected" ]; then
  rm -f -- "\$tmp"
  echo "ERROR: helper digest mismatch while installing snapshot" >&2
  exit 1
fi
chmod 0555 -- "\$tmp"
chown root:root -- "\$tmp"
mv -f -- "\$tmp" "\$dest"
EOF
}

omarchweb_install_helper() {
  local src="$omarchweb_scripts/root.sh" prog rc=0
  [ -f "$src" ] || { echo "ERROR: missing helper source $src" >&2; return 127; }
  omarchweb_open_pinned "$src" "$omarchweb_helper_sha256" || return 1
  prog="$(omarchweb_helper_install_program)" || { exec {OMARCHWEB_PINNED_FD}<&-; return 1; }
  echo "Installing OmarchWeb privileged helper (password prompt)..."
  if [ "$(id -u)" -eq 0 ]; then
    /usr/bin/bash -c "$prog" <&"$OMARCHWEB_PINNED_FD" || rc=$?
  elif sudo -n true </dev/null >/dev/null 2>&1; then
    sudo -n /usr/bin/bash -c "$prog" <&"$OMARCHWEB_PINNED_FD" || rc=$?
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec /usr/bin/bash -c "$prog" <&"$OMARCHWEB_PINNED_FD" || rc=$?
  else
    echo "ERROR: root privileges required to install $omarchweb_helper_dest" >&2
    rc=1
  fi
  exec {OMARCHWEB_PINNED_FD}<&-
  return $rc
}

omarchweb_ensure_helper() {
  if omarchweb_helper_current; then
    return 0
  fi
  omarchweb_install_helper || return 1
  if ! omarchweb_helper_current; then
    echo "ERROR: privileged helper is missing or not the reviewed snapshot" >&2
    echo "ERROR: expected $omarchweb_helper_dest owned by root, digest $omarchweb_helper_sha256" >&2
    if [ -d /usr/local/libexec ] && [ ! -r /usr/local/libexec ] && [ ! -x /usr/local/libexec ]; then
      echo "ERROR: /usr/local/libexec is not traversable; retry after: sudo chmod 755 /usr/local/libexec" >&2
    fi
    return 1
  fi
}

omarchweb_elevate() {
  omarchweb_ensure_helper || return 1
  if [ "$(id -u)" -eq 0 ]; then
    "$omarchweb_helper_dest" "$@"
    return $?
  fi
  if sudo -n true </dev/null >/dev/null 2>&1; then
    sudo -n "$omarchweb_helper_dest" "$@"
    return $?
  fi
  if command -v pkexec >/dev/null 2>&1; then
    pkexec "$omarchweb_helper_dest" "$@"
    return $?
  fi
  echo "ERROR: root privileges required (no polkit/pkexec, and sudo cannot prompt without a TTY)" >&2
  return 1
}
