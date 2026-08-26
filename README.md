# OmarchWeb

A web development control panel for the Omarchy Quattro bar: start/stop/restart
services, manage MySQL and PostgreSQL databases and app users, and add PHP,
Laravel, WordPress, or Node virtual hosts.

## Install

```sh
omarchy plugin add https://github.com/giodc/omarchweb.git --enable
```

Or, for a local checkout under `~/.config/omarchy/plugins/`:

```sh
omarchy plugin enable io.github.giodc.omarchweb
omarchy bar move io.github.giodc.omarchweb --section right
```

Saved changes under the plugin folder hot-reload. If a change does not apply:

```sh
omarchy-shell shell rescanPlugins
```

## Usage

Click the globe icon on the bar to open or close the panel. Press Escape to
close it. Middle-click the bar icon to refresh.

The panel opens on the **Services** tab. Other tabs:

| Tab | Purpose |
| --- | --- |
| **Services** | Start / stop / restart / install / uninstall PHP-FPM, MariaDB, Nginx, PostgreSQL, Redis, Mailpit |
| **MySQL** / **PostgreSQL** | List, create, and delete databases and password users (shown only if that server is installed) |
| **Vhosts** | Add or remove PHP, Laravel, WordPress, or Node Nginx sites |

Privileged actions (systemd, pacman, nginx, MariaDB elevation) prompt through
the desktop polkit agent (`pkexec`). The bar process has no TTY, so plain
`sudo` cannot ask for a password.

### Mailpit

SMTP catcher on port **1025**, web UI on **http://127.0.0.1:8025**. Install from
Services (AUR `mailpit-bin`); Open appears while it is running.

### WordPress vhosts

Choosing type **wordpress** downloads the latest release into the site folder,
enables `mysqli`, and grants the `http` user write access for the installer.

## Configure

```sh
omarchy bar set io.github.giodc.omarchweb refreshSeconds 30
omarchy bar set io.github.giodc.omarchweb webRoot ~/Web
omarchy bar set io.github.giodc.omarchweb nginxPort 80
omarchy bar move io.github.giodc.omarchweb --section right
```

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `refreshSeconds` | integer | 30 | How often to re-check service/db state while the panel is open |
| `webRoot` | path | `~/Web` | Base folder for new vhosts/projects |
| `nginxPort` | integer | 80 | Listen port for generated virtual hosts |

## IPC

```sh
omarchy-shell ipc call io.github.giodc.omarchweb toggle
omarchy-shell shell summon io.github.giodc.omarchweb '{}'
omarchy-shell shell hide io.github.giodc.omarchweb
```

## Backends

Scripts in `scripts/` (run from the panel):

- `services.sh` — systemd unit status/start/stop/restart
- `db.sh` — MariaDB and PostgreSQL databases and app users
- `vhost.sh` — Nginx virtual hosts (WordPress download, php/laravel/node)
- `setup.sh` — install/uninstall packages for a service
- `root.sh` — privileged helper via `pkexec` / passwordless sudo

Environment overrides: `OMARCHWEB_SERVICES`, `OMARCHWEB_DB_BIN`,
`OMARCHWEB_PG_BIN`, `OMARCHWEB_WEB_ROOT`, `OMARCHWEB_NGINX_DIR`,
`OMARCHWEB_PORT`, `OMARCHWEB_FPM_SOCK`, `OMARCHWEB_WP_URL`.

## Remove

```sh
omarchy plugin remove io.github.giodc.omarchweb
```

## License

MIT — see [LICENSE](LICENSE).
