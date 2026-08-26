# OmarchWeb

![OmarchWeb panel](docs/screenshot.png)

A native Omarchy Quattro bar plugin for local web development: start/stop
services, manage MariaDB and PostgreSQL databases and users, and add Nginx
virtual hosts (PHP, WordPress, Laravel, Node).

## Install

```sh
omarchy plugin add https://github.com/giodc/omarchweb.git --enable
```

Or from a local clone under `~/.config/omarchy/plugins/io.github.giodc.omarchweb/`:

```sh
omarchy plugin enable io.github.giodc.omarchweb right
```

Saved edits hot-reload. If a change does not apply:

```sh
omarchy-shell shell rescanPlugins
```

## Usage

Click the globe on the bar to open the panel. Escape closes it.

- **Services** — install, start, stop, restart, or uninstall PHP-FPM, MariaDB,
  Nginx, PostgreSQL, Redis, and Mailpit. Privileged actions use the desktop
  polkit agent (`pkexec`).
- **MariaDB / PostgreSQL** — tabs appear when that server is installed. Create
  and delete databases and password users for apps (e.g. WordPress).
- **Vhosts** — add PHP, WordPress, Laravel, or Node sites. WordPress downloads
  the latest release into the site folder.

Default panel tab is **Services**. The bar widget defaults to the **right**
section (`defaultSection`).

## Configure

```sh
omarchy bar move io.github.giodc.omarchweb --section right
omarchy bar set io.github.giodc.omarchweb refreshSeconds 30
omarchy bar set io.github.giodc.omarchweb webRoot ~/Web
omarchy bar set io.github.giodc.omarchweb nginxPort 80
```

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `refreshSeconds` | integer | 30 | How often to re-check service/db state while the panel is open |
| `webRoot` | path | `~/Web` | Base folder for new vhosts/projects |
| `nginxPort` | integer | 80 | Listen port for generated virtual hosts |

## Privileges

Systemd control, package install/remove, nginx config, `/etc/hosts`, and some
database grants run through `scripts/root.sh` via passwordless `sudo` when
available, otherwise `pkexec`. The panel itself has no TTY, so password prompts
use Omarchy’s polkit dialog.

## Backends

Scripts in `scripts/` (not invoked as a second Quickshell process):

- `services.sh` — systemd status/start/stop/restart
- `db.sh` — MariaDB and PostgreSQL databases and app users
- `vhost.sh` — Nginx virtual hosts
- `setup.sh` — install/uninstall stack packages (Mailpit via AUR + `pkexec`)
- `root.sh` — allow-listed privileged helper

Environment overrides: `OMARCHWEB_SERVICES`, `OMARCHWEB_DB_BIN`,
`OMARCHWEB_PG_BIN`, `OMARCHWEB_WEB_ROOT`, `OMARCHWEB_NGINX_DIR`,
`OMARCHWEB_PORT`, `OMARCHWEB_FPM_SOCK`, `OMARCHWEB_WP_URL`.

## IPC

```sh
omarchy-shell ipc call io.github.giodc.omarchweb toggle
omarchy-shell shell summon io.github.giodc.omarchweb '{}'
omarchy-shell shell hide io.github.giodc.omarchweb
```

## Remove

```sh
omarchy plugin remove io.github.giodc.omarchweb
```

Removing the plugin does not uninstall web services or virtual hosts.

## License

MIT — see [LICENSE](LICENSE).
