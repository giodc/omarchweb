# OmarchWeb — Omarchy web development control panel

A native Omarchy bar plugin that manages your local web dev stack from the
status bar: start/stop/restart services, create/delete databases, and add
virtual hosts.

## Features

- **Services** — start / stop / restart PHP-FPM, MariaDB, Nginx (plus
  PostgreSQL, Redis, and Mailpit if installed). Mailpit is an SMTP catcher
  (port 1025) with a web UI on port 8025. Services are managed as systemd
  units; privileged actions prompt through the desktop polkit agent (`pkexec`).
- **MySQL / PostgreSQL** — separate tabs (shown only if that server is
  installed) to list, create, and delete databases and app users. MySQL/MariaDB
  uses the unix_socket account for the panel; create a password user for
  WordPress and other apps (`localhost`). PostgreSQL uses peer auth for the
  panel; password users connect at `127.0.0.1`.
- **Virtual hosts** — add PHP, Laravel, WordPress, or Node Nginx vhosts and
  remove them. WordPress vhosts download the latest release into the site
  folder. Generated server blocks live under `/etc/nginx/sites-available|enabled`.
- **One-shot setup** — installs and enables `php-fpm`, `mariadb`, `nginx`,
  `composer`, and the Laravel installer when the stack is missing.

## Install

```sh
omarchy plugin enable giodc.omarchweb right
```

The plugin lives in `~/.config/omarchy/plugins/giodc.omarchweb/` (symlinked at
`~/Documents/Development/Plugins/OmarchWeb`). Saving any file under the plugin
folder hot-reloads it; if a change doesn't apply, run
`omarchy-shell shell rescanPlugins`.

## Settings

Configured in the widget's own `shell.json` entry, or via
`omarchy bar set giodc.omarchweb <key> <value>`:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `refreshSeconds` | integer | 30 | How often to re-check service/db state while the panel is open |
| `webRoot` | path | `~/Web` | Base folder where new vhosts/projects are created |
| `nginxPort` | integer | 80 | Listen port for generated virtual hosts |

## Backends

The plugin shells out to scripts in `scripts/`:

- `services.sh status|start|stop|restart <service>` — systemd unit control
  (auto-detects system vs `--user` unit; system units go through `pkexec`).
- `db.sh list|create|delete|exists|user-create|user-delete|grant` — MariaDB and
  PostgreSQL database and app-user ops (`engine` is `mariadb` or `postgresql`).
- `vhost.sh list|add|remove` — Nginx virtual host generation (one `pkexec`
  prompt to write the site, update `/etc/hosts`, and reload nginx).
- `setup.sh install|status` — one-shot stack installer.
- `root.sh` — privileged helper used by the scripts above; not invoked from the panel directly.

Overridable via environment: `OMARCHWEB_SERVICES`, `OMARCHWEB_DB_BIN`,
`OMARCHWEB_PG_BIN`, `OMARCHWEB_WEB_ROOT`, `OMARCHWEB_NGINX_DIR`,
`OMARCHWEB_PORT`, `OMARCHWEB_FPM_SOCK`.

## IPC

`IpcHandler` target `giodc.omarchweb` exposes `open`, `close`, `show`, `hide`,
`toggle`:

```sh
omarchy-shell ipc call giodc.omarchweb toggle
```
