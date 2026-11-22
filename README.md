# OpenHamClock Control

A small desktop control panel and safe updater for [OpenHamClock](https://github.com/accius/openhamclock) on Ubuntu and other Linux desktops.

It gives you a point-and-click menu (built with `zenity`) to start, stop, restart and watch the OpenHamClock service, and an updater that:

- installs the **latest official release** (a GitHub release tag, not whatever is on `main`)
- **backs up first**: full git history, your `.env` and your `data/` folder
- **merges your personal `.env` settings into the new release's `.env.example`**, so you keep your settings *and* pick up any new ones
- **rolls back automatically** if anything fails
- can run **hands-off**, including from cron

> This is an independent helper script, not part of the OpenHamClock project.

## Requirements

- Linux with systemd and a desktop session (for the menu), e.g. Ubuntu
- OpenHamClock installed as a **git clone** at `~/openhamclock`
  (`git clone https://github.com/accius/openhamclock.git`), not from a zip file
- A systemd service named `openhamclock` that runs `npm start`, such as the one OpenHamClock's `scripts/setup-linux.sh` creates
- `git`, `curl`, `python3`, `npm`, `zenity`, `tar`, and `gnome-terminal` (for the live-log window)

```bash
sudo apt install git curl python3 zenity
```

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/williamscody/openhamclock-control/main/openhamclock-control.sh
chmod +x openhamclock-control.sh
./openhamclock-control.sh
```

If your install or service lives somewhere else, edit the settings at the top of the script:

| Setting       | Default                    | Meaning                               |
|---------------|----------------------------|---------------------------------------|
| `SERVICE`     | `openhamclock`             | systemd service name                  |
| `APP_DIR`     | `$HOME/openhamclock`       | your OpenHamClock git clone           |
| `BACKUP_ROOT` | `$HOME/OpenHamClock-Backups` | where update backups are kept       |
| `AUTO_MODE`   | `false`                    | `true` = no prompts during updates    |

## The menu

| Action             | What it does                                         |
|--------------------|------------------------------------------------------|
| View Live Logs     | Opens a terminal streaming `journalctl -u openhamclock -f` |
| Start / Restart / Stop Service | Controls the systemd service             |
| Enable / Disable Autostart | Starts OpenHamClock at boot, or not          |
| Check for Updates  | Runs the updater described below                     |

## How an update works

1. Checks that `APP_DIR` is a clone of the official repository and that no **tracked** files have local changes. Untracked files, such as stray backups, are ignored.
2. Asks GitHub for the latest release. If you already have it, or something newer, it stops.
3. Asks for confirmation, unless `AUTO_MODE=true`.
4. Creates a timestamped backup folder in `BACKUP_ROOT` (readable only by you) containing:
   - `repository.bundle`: the full git history
   - `user-data.tar.gz`: your `.env` and `data/`
   - `restore-info.txt`: the previous commit, branch and version
5. Stops the service and checks out the release tag.
6. **Merges your `.env`** (see below).
7. Runs `npm ci`, but only if `package-lock.json` changed.
8. Restarts the service. `npm start` rebuilds the frontend.
9. If any step fails, it rolls back to the previous commit and restores your original `.env` and `data/`.

### The `.env` merge

New releases sometimes add settings to `.env.example`. A plain "keep my old `.env`" update never picks them up. The merge builds a new `.env` from the **new** `.env.example` and carries your settings into it:

- Every `KEY=value` you have replaces the template's line for that key.
- If you set a key that the template only shows commented out (`# KEY=...`), your line takes its place.
- If you commented out a key that the template has active, it stays commented out.
- Keys the template no longer mentions (your own additions, or renamed or retired settings) are kept in a labelled block at the end of the file.
- If upstream changed a default and you still have the old default, **your value is kept** and the change is reported.

The report lists **setting names only**, never your values, so API keys don't end up in logs.

With `AUTO_MODE=false`, a review window shows the report and a line-by-line diff:

- **Apply merged .env** writes the merged file.
- **Keep my current .env** leaves your file untouched. The merged copy is saved as `env.merged` in that update's backup folder.

## Hands-off updates

Once you trust it, set `AUTO_MODE=true` at the top of the script. Clicking **Check for Updates** then runs with no prompts.

To update on a schedule, use `--auto`. It shows no menu and no windows, and adds its output to `BACKUP_ROOT/auto-update.log`:

```bash
crontab -e
# Every day at 03:30
30 3 * * * $HOME/openhamclock-control.sh --auto
```

Cron can't type a `sudo` password, so allow the three service commands without one. Run `sudo visudo -f /etc/sudoers.d/openhamclock` and add this, replacing `YOUR_USER`:

```
YOUR_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start openhamclock, /usr/bin/systemctl stop openhamclock, /usr/bin/systemctl restart openhamclock
```

If Node.js was installed with `nvm`, cron won't find `npm`. Run `which npm` and add a matching `PATH=...` line at the top of your crontab.

## Restoring a backup by hand

Each backup folder's `restore-info.txt` names the previous commit. To go back:

```bash
sudo systemctl stop openhamclock
cd ~/openhamclock
git checkout --detach <previous commit>
tar -xzf ~/OpenHamClock-Backups/<stamp>/user-data.tar.gz -C ~/openhamclock
npm ci
sudo systemctl start openhamclock
```

## License

MIT. See [LICENSE](LICENSE).
