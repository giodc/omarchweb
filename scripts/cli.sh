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

install_cli_wrappers() {
  local dest_dir="${OMARCHWEB_CLI_BIN_DIR:-$HOME/.local/bin}"
  local cli="$omarchweb_scripts/cli.sh"
  local wrapper

  mkdir -p "$dest_dir" || return 1
  for wrapper in omarchweb web; do
    cat > "$dest_dir/$wrapper" <<EOF
#!/usr/bin/env bash
exec $(printf '%q' "$cli") "\$@"
EOF
    chmod 0755 "$dest_dir/$wrapper" || return 1
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
      && grep -Fq "$cli" "$dest_dir/web" 2>/dev/null \
      && grep -Fq "$cli" "$dest_dir/omarchweb" 2>/dev/null; then
    echo "STATUS cli installed"
    return 0
  fi
  if [ -e "$dest_dir/web" ] || [ -e "$dest_dir/omarchweb" ]; then
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
