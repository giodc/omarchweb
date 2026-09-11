#!/usr/bin/env bash
# OmarchWeb — user CLI (omarchweb / web).
#
# Installed as ~/.local/bin/omarchweb and ~/.local/bin/web by setup or
# `omarchweb install-cli`. Resolves the current directory to a managed vhost.
#
# Usage:
#   omarchweb open [name]     open the site for cwd (or named vhost) in a browser
#   omarchweb url [name]      print the site URL
#   omarchweb list            list managed vhosts
#   omarchweb install-cli     install/refresh ~/.local/bin wrappers
#   web …                     same commands (wrapper)

set -u
# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

VHOST="$omarchweb_scripts/vhost.sh"

# True if path is a regular file we own and that OmarchWeb previously wrote
# (current marked wrappers, or legacy unmarked wrappers from older installs).
cli_wrapper_is_ours() {
  local path="$1"
  # Never treat a symlink as ours — install must not follow it.
  [ -L "$path" ] && return 1
  [ -f "$path" ] || return 1
  [ "$(stat -c '%u' -- "$path")" = "$(id -u)" ] || return 1

  if grep -q '^# managed by OmarchWeb' "$path" 2>/dev/null \
      && grep -qE '^exec .+/cli\.sh' "$path" 2>/dev/null; then
    return 0
  fi

  # Legacy shape (before the managed marker):
  #   #!/usr/bin/env bash
  #   exec …/io.github.giodc.omarchweb/scripts/cli.sh "$@"
  if head -n 1 "$path" | grep -qE '^#!/usr/bin/env bash|^#!/bin/bash' \
      && grep -qE '^exec .+io\.github\.giodc\.omarchweb/scripts/cli\.sh' "$path" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Write stdin over dest: O_EXCL temp in the same directory, fsync, rename.
# rename(2) replaces a symlink at dest instead of writing through it.
cli_atomic_write() {
  local dest="$1"
  local dir tmp
  dir="$(dirname -- "$dest")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp -p "$dir" -- ".$(basename -- "$dest").XXXXXX")" || return 1
  if ! cat > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chmod 0755 -- "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! sync -d "$tmp" 2>/dev/null && ! sync "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  sync -d "$dir" 2>/dev/null || true
}

install_cli_wrappers() {
  local dest_dir="${OMARCHWEB_CLI_BIN_DIR:-$HOME/.local/bin}"
  local cli="$omarchweb_scripts/cli.sh"
  local wrapper dest

  [ -f "$cli" ] || { echo "ERROR: missing helper $cli" >&2; return 127; }
  mkdir -p "$dest_dir" || return 1

  for wrapper in omarchweb web; do
    dest="$dest_dir/$wrapper"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      if ! cli_wrapper_is_ours "$dest"; then
        echo "ERROR: refusing to overwrite $dest (not an OmarchWeb-owned CLI wrapper)" >&2
        echo "ERROR: remove it manually if you want OmarchWeb to install '$wrapper' here" >&2
        return 1
      fi
    fi
    if ! cli_atomic_write "$dest" <<EOF
#!/usr/bin/env bash
# managed by OmarchWeb
exec $(printf '%q' "$cli") "\$@"
EOF
    then
      echo "ERROR: failed to install $dest" >&2
      return 1
    fi
  done

  echo "OK: installed $dest_dir/omarchweb and $dest_dir/web"
  case ":$PATH:" in
    *":$dest_dir:"*) ;;
    *)
      echo "NOTE: $dest_dir is not on PATH — add it to your shell profile, then re-open the terminal."
      ;;
  esac
}

# Prints: STATUS cli installed|missing|stale
status_cli() {
  local dest_dir="${OMARCHWEB_CLI_BIN_DIR:-$HOME/.local/bin}"
  local cli="$omarchweb_scripts/cli.sh"
  if [ -x "$dest_dir/web" ] && [ -x "$dest_dir/omarchweb" ] \
      && ! [ -L "$dest_dir/web" ] && ! [ -L "$dest_dir/omarchweb" ] \
      && grep -q '^# managed by OmarchWeb' "$dest_dir/web" 2>/dev/null \
      && grep -q '^# managed by OmarchWeb' "$dest_dir/omarchweb" 2>/dev/null \
      && grep -Fq "$cli" "$dest_dir/web" 2>/dev/null \
      && grep -Fq "$cli" "$dest_dir/omarchweb" 2>/dev/null; then
    echo "STATUS cli installed"
    return 0
  fi
  if [ -e "$dest_dir/web" ] || [ -L "$dest_dir/web" ] \
      || [ -e "$dest_dir/omarchweb" ] || [ -L "$dest_dir/omarchweb" ]; then
    echo "STATUS cli stale"
    return 1
  fi
  echo "STATUS cli missing"
  return 1
}

usage() {
  echo "usage: omarchweb open [name] | url [name] | list | install-cli | status | help" >&2
  echo "       web open [name]   # same (after install-cli / setup)" >&2
}

case "${1:-}" in
  open)
    shift
    exec "$VHOST" open "$@"
    ;;
  url)
    shift
    exec "$VHOST" url "$@"
    ;;
  list)
    exec "$VHOST" list
    ;;
  install-cli|install)
    install_cli_wrappers
    ;;
  status)
    status_cli
    ;;
  help|-h|--help|"")
    usage
    [ "${1:-}" = "" ] && exit 1
    exit 0
    ;;
  *)
    echo "unknown command: ${1:-}" >&2
    usage
    exit 1
    ;;
esac
