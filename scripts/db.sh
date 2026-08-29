#!/usr/bin/env bash
# OmarchWeb — database management backend (MariaDB/MySQL and PostgreSQL).
#
# MariaDB: connects as the current OS user through unix_socket auth.
# PostgreSQL: connects as the current OS user through peer auth (a role
# matching the OS username).
#
# When privileges are missing, mutating operations escalate to root once,
# grant this user a passwordless account, and retry — so at most one prompt
# is ever needed.
#
# Usage:
#   db.sh list [engine]                  STATUS, engine|name, and USER rows
#   db.sh create [engine] <name>
#   db.sh delete [engine] <name>
#   db.sh exists [engine] <name>         exit 0 if the database exists
#   db.sh user-create <engine> <name>    password on stdin (never argv)
#   db.sh user-delete <engine> <name>
#   db.sh grant [engine]                 ensure local access for this user
#
# engine is mariadb or postgresql. Omitted engine on create/delete/exists
# defaults to mariadb (legacy). Omitted engine on list/grant means both.

set -u
# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if [ -n "${OMARCHWEB_DB_BIN:-}" ]; then
  DB_BIN="$OMARCHWEB_DB_BIN"
elif command -v mariadb >/dev/null 2>&1; then
  DB_BIN="mariadb"
elif command -v mysql >/dev/null 2>&1; then
  DB_BIN="mysql"
else
  DB_BIN="mariadb"
fi
DB_USER="${OMARCHWEB_DB_USER:-$(id -un)}"
PG_BIN="${OMARCHWEB_PG_BIN:-psql}"

name_ok() {
  case "$1" in
    *[!A-Za-z0-9_.-]*|''|.*) return 1 ;;
    *) return 0 ;;
  esac
}

user_ok() {
  case "$1" in
    *[!A-Za-z0-9_]*|'') return 1 ;;
    *) return 0 ;;
  esac
}

is_system_db_user() {
  case "$1" in
    root|mysql|mariadb.sys|postgres|PUBLIC|"") return 0 ;;
    *) return 1 ;;
  esac
}

sql_quote() {
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

is_engine() {
  case "$1" in
    mariadb|postgresql) return 0 ;;
    *) return 1 ;;
  esac
}

safe_user() {
  local user="${DB_USER//[^A-Za-z0-9_]/}"
  [ -n "$user" ] || return 1
  printf '%s\n' "$user"
}

svc_running() {
  systemctl is-active --quiet "$1" 2>/dev/null \
    || systemctl --user is-active --quiet "$1" 2>/dev/null
}

# ---- MariaDB / MySQL -------------------------------------------------------

db() {
  "$DB_BIN" "$@"
}

# The helper builds the grant SQL itself; only a validated role name crosses
# the privilege boundary.
grant_mariadb() {
  local user
  user="$(safe_user)" || return 1
  command -v mariadb >/dev/null 2>&1 || {
    echo "ERROR: mariadb elevation requires the mariadb client" >&2
    return 1
  }
  omarchweb_elevate grant-mariadb "$user" >/dev/null
}

db_privileged() {
  local out rc
  out="$(db "$@" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  case "$out" in
    *[Dd]enied*)
      grant_mariadb || { printf '%s\n' "$out" >&2; return $rc; }
      db "$@"
      ;;
    *)
      printf '%s\n' "$out" >&2
      return $rc
      ;;
  esac
}

# Feed SQL on the client stdin so secrets never appear in process argv.
db_privileged_sql() {
  local sql="$1"
  local out rc
  out="$(printf '%s\n' "$sql" | db 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  case "$out" in
    *[Dd]enied*)
      grant_mariadb || { printf '%s\n' "$out" >&2; return $rc; }
      printf '%s\n' "$sql" | db
      ;;
    *)
      printf '%s\n' "$out" >&2
      return $rc
      ;;
  esac
}

mariadb_status() {
  if ! command -v "$DB_BIN" >/dev/null 2>&1; then
    echo "missing"
    return
  fi
  if ! svc_running mariadb && ! svc_running mysql && ! svc_running mysqld; then
    echo "down"
    return
  fi
  if db -N -e "SELECT 1;" >/dev/null 2>&1; then
    echo "ok"
    return
  fi
  echo "denied"
}

list_mariadb() {
  db -N -e "SHOW DATABASES;" 2>/dev/null \
    | grep -v -E '^(information_schema|performance_schema|mysql|sys)$' \
    | while IFS= read -r n; do
        [ -n "$n" ] && printf 'mariadb|%s\n' "$n"
      done
}

mariadb_exists() {
  db -N -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$1';" 2>/dev/null | grep -q .
}

create_mariadb() {
  local name="$1"
  if mariadb_exists "$name"; then
    echo "INFO: MariaDB database '$name' already exists"
    return 0
  fi
  db_privileged -e "CREATE DATABASE \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1
  echo "OK: created MariaDB database '$name'"
}

delete_mariadb() {
  local name="$1"
  db_privileged -e "DROP DATABASE IF EXISTS \`$name\`;" || return 1
  echo "OK: dropped MariaDB database '$name'"
}

list_mariadb_users() {
  db -N -e "SELECT User, IFNULL(plugin,'') FROM mysql.user WHERE Host IN ('localhost','127.0.0.1') AND User NOT IN ('','root','mysql','mariadb.sys') ORDER BY User;" 2>/dev/null \
    | while IFS=$'\t' read -r user plugin; do
        [ -n "$user" ] || continue
        [ -z "$plugin" ] || [ "$plugin" != "unix_socket" ] && plugin="password"
        printf 'USER mariadb|%s|%s\n' "$user" "$plugin"
      done
}

create_mariadb_user() {
  local name="$1" pass="$2"
  user_ok "$name" || { echo "ERROR: invalid user name" >&2; return 1; }
  is_system_db_user "$name" && { echo "ERROR: cannot manage system user '$name'" >&2; return 1; }
  [ -n "$pass" ] || { echo "ERROR: password is required" >&2; return 1; }
  local u p
  u="$(sql_quote "$name")"
  p="$(sql_quote "$pass")"
  db_privileged_sql "CREATE USER IF NOT EXISTS ${u}@'localhost' IDENTIFIED BY ${p}; ALTER USER ${u}@'localhost' IDENTIFIED BY ${p}; GRANT ALL PRIVILEGES ON *.* TO ${u}@'localhost'; FLUSH PRIVILEGES;" || return 1
  echo "OK: MariaDB user '$name'@localhost (password login, all databases)"
}

delete_mariadb_user() {
  local name="$1"
  user_ok "$name" || { echo "ERROR: invalid user name" >&2; return 1; }
  is_system_db_user "$name" && { echo "ERROR: cannot delete system user '$name'" >&2; return 1; }
  [ "$name" = "$(safe_user)" ] && { echo "ERROR: cannot delete your socket account '$name'" >&2; return 1; }
  local u
  u="$(sql_quote "$name")"
  db_privileged -e "DROP USER IF EXISTS ${u}@'localhost'; FLUSH PRIVILEGES;" || return 1
  echo "OK: dropped MariaDB user '$name'@localhost"
}

# ---- PostgreSQL ------------------------------------------------------------

pg() {
  "$PG_BIN" -d postgres -v ON_ERROR_STOP=1 "$@"
}

grant_postgres() {
  local user
  user="$(safe_user)" || return 1
  command -v "$PG_BIN" >/dev/null 2>&1 || {
    echo "ERROR: postgresql client (psql) is not installed" >&2
    return 1
  }
  omarchweb_elevate grant-postgres "$user" >/dev/null
}

pg_privileged() {
  local out rc
  out="$(pg "$@" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  case "$out" in
    *"permission denied"*|*"must be owner"*|*"must be superuser"*|*"does not exist"*)
      grant_postgres || { printf '%s\n' "$out" >&2; return $rc; }
      pg "$@"
      ;;
    *)
      printf '%s\n' "$out" >&2
      return $rc
      ;;
  esac
}

pg_privileged_sql() {
  local sql="$1"
  local out rc
  out="$(printf '%s\n' "$sql" | pg 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  case "$out" in
    *"permission denied"*|*"must be owner"*|*"must be superuser"*|*"does not exist"*)
      grant_postgres || { printf '%s\n' "$out" >&2; return $rc; }
      printf '%s\n' "$sql" | pg
      ;;
    *)
      printf '%s\n' "$out" >&2
      return $rc
      ;;
  esac
}

postgres_status() {
  if ! command -v "$PG_BIN" >/dev/null 2>&1; then
    echo "missing"
    return
  fi
  if ! svc_running postgresql; then
    echo "down"
    return
  fi
  local err
  err="$(psql -d postgres -Atqc 'SELECT 1;' 2>&1)" && { echo "ok"; return; }
  case "$err" in
    *"does not exist"*) echo "no-role" ;;
    *"permission denied"*) echo "denied" ;;
    *) echo "error" ;;
  esac
}

list_postgres() {
  psql -d postgres -Atqc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1;" 2>/dev/null \
    | while IFS= read -r n; do
        [ -n "$n" ] && printf 'postgresql|%s\n' "$n"
      done
}

postgres_exists() {
  psql -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$1';" 2>/dev/null | grep -q 1
}

create_postgres() {
  local name="$1"
  if postgres_exists "$name"; then
    echo "INFO: PostgreSQL database '$name' already exists"
    return 0
  fi
  pg_privileged -c "CREATE DATABASE \"$name\" ENCODING 'UTF8';" || return 1
  echo "OK: created PostgreSQL database '$name'"
}

delete_postgres() {
  pg_privileged -c "DROP DATABASE IF EXISTS \"$1\" WITH (FORCE);" || return 1
  echo "OK: dropped PostgreSQL database '$1'"
}

list_postgres_users() {
  psql -d postgres -Atqc "SELECT rolname FROM pg_roles WHERE rolcanlogin AND rolname NOT IN ('postgres') AND rolname NOT LIKE 'pg_%' ORDER BY 1;" 2>/dev/null \
    | while IFS= read -r n; do
        [ -n "$n" ] || continue
        auth="password"
        [ "$n" = "$DB_USER" ] && auth="peer"
        printf 'USER postgresql|%s|%s\n' "$n" "$auth"
      done
}

create_postgres_user() {
  local name="$1" pass="$2"
  user_ok "$name" || { echo "ERROR: invalid user name" >&2; return 1; }
  is_system_db_user "$name" && { echo "ERROR: cannot manage system user '$name'" >&2; return 1; }
  [ -n "$pass" ] || { echo "ERROR: password is required" >&2; return 1; }
  local u p
  u="$(sql_quote "$name")"
  p="$(sql_quote "$pass")"
  pg_privileged_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = ${u}) THEN CREATE ROLE ${name} WITH LOGIN PASSWORD ${p} CREATEDB; ELSE ALTER ROLE ${name} WITH LOGIN PASSWORD ${p} CREATEDB; END IF; END \$\$;" || return 1
  echo "OK: PostgreSQL user '$name' (password login; host 127.0.0.1)"
}

delete_postgres_user() {
  local name="$1"
  user_ok "$name" || { echo "ERROR: invalid user name" >&2; return 1; }
  is_system_db_user "$name" && { echo "ERROR: cannot delete system user '$name'" >&2; return 1; }
  [ "$name" = "$(safe_user)" ] && { echo "ERROR: cannot delete your peer role '$name'" >&2; return 1; }
  pg_privileged -c "DROP ROLE IF EXISTS \"$name\";" || return 1
  echo "OK: dropped PostgreSQL user '$name'"
}

# ---- Dispatch --------------------------------------------------------------

parse_engine_name() {
  engine="${1:-}"
  name="${2:-}"
  if [ -z "$name" ]; then
    if is_engine "$engine"; then
      echo "ERROR: missing database name" >&2
      return 1
    fi
    name="$engine"
    engine="mariadb"
  fi
  is_engine "$engine" || { echo "ERROR: unknown engine '$engine' (mariadb|postgresql)" >&2; return 1; }
  name_ok "$name" || { echo "ERROR: invalid database name" >&2; return 1; }
}

emit_status() {
  printf 'STATUS %s %s\n' "$1" "$2"
}

do_list() {
  local only="${1:-}"
  if [ -z "$only" ] || [ "$only" = "mariadb" ]; then
    local st
    st="$(mariadb_status)"
    emit_status mariadb "$st"
    if [ "$st" = "ok" ]; then
      list_mariadb
      list_mariadb_users
    fi
  fi
  if [ -z "$only" ] || [ "$only" = "postgresql" ]; then
    local st
    st="$(postgres_status)"
    emit_status postgresql "$st"
    if [ "$st" = "ok" ]; then
      list_postgres
      list_postgres_users
    fi
  fi
}

case "${1:-}" in
  list)
    only="${2:-}"
    if [ -n "$only" ] && ! is_engine "$only"; then
      echo "ERROR: unknown engine '$only' (mariadb|postgresql)" >&2
      exit 1
    fi
    do_list "$only"
    ;;
  create)
    parse_engine_name "${2:-}" "${3:-}" || exit 1
    if [ "$engine" = "postgresql" ]; then
      create_postgres "$name"
    else
      create_mariadb "$name"
    fi
    ;;
  delete)
    parse_engine_name "${2:-}" "${3:-}" || exit 1
    if [ "$engine" = "postgresql" ]; then
      delete_postgres "$name"
    else
      delete_mariadb "$name"
    fi
    ;;
  exists)
    parse_engine_name "${2:-}" "${3:-}" || exit 1
    if [ "$engine" = "postgresql" ]; then
      postgres_exists "$name"
    else
      mariadb_exists "$name"
    fi
    ;;
  user-create)
    parse_engine_name "${2:-}" "${3:-}" || exit 1
    [ -z "${4:-}" ] || { echo "ERROR: pass the password on stdin, not as an argument" >&2; exit 1; }
    IFS= read -r pass || true
    [ -n "$pass" ] || { echo "ERROR: password is required on stdin" >&2; exit 1; }
    user_ok "$name" || { echo "ERROR: invalid user name" >&2; exit 1; }
    if [ "$engine" = "postgresql" ]; then
      create_postgres_user "$name" "$pass"
    else
      create_mariadb_user "$name" "$pass"
    fi
    ;;
  user-delete)
    parse_engine_name "${2:-}" "${3:-}" || exit 1
    user_ok "$name" || { echo "ERROR: invalid user name" >&2; exit 1; }
    if [ "$engine" = "postgresql" ]; then
      delete_postgres_user "$name"
    else
      delete_mariadb_user "$name"
    fi
    ;;
  grant)
    engine="${2:-}"
    rc=0
    if [ -n "$engine" ] && ! is_engine "$engine"; then
      echo "ERROR: unknown engine '$engine' (mariadb|postgresql)" >&2
      exit 1
    fi
    if [ -z "$engine" ] || [ "$engine" = "mariadb" ]; then
      if [ "$(mariadb_status)" != "missing" ]; then
        grant_mariadb && echo "OK: passwordless MariaDB access granted for '$DB_USER'" || rc=1
      elif [ -n "$engine" ]; then
        echo "ERROR: MariaDB is not installed" >&2
        rc=1
      fi
    fi
    if [ -z "$engine" ] || [ "$engine" = "postgresql" ]; then
      if [ "$(postgres_status)" != "missing" ]; then
        grant_postgres && echo "OK: PostgreSQL role granted for '$DB_USER'" || rc=1
      elif [ -n "$engine" ]; then
        echo "ERROR: PostgreSQL is not installed" >&2
        rc=1
      fi
    fi
    exit $rc
    ;;
  *)
    echo "unknown action: ${1:-}" >&2
    echo "usage: db.sh list [engine] | create [engine] <name> | delete [engine] <name> | exists [engine] <name> | user-create <engine> <name> | user-delete <engine> <name> | grant [engine]" >&2
    echo "       user-create reads the password from stdin" >&2
    exit 1
    ;;
esac
