# openhost-webtop

A full XFCE Linux desktop environment, accessible from any low quality web
browser (JS support required), packaged as an OpenHost app.

Under the hood this is
[`linuxserver/webtop:ubuntu-xfce`](https://github.com/linuxserver/docker-webtop)
with a thin bridge so webtop's `/config` persistence convention lines up
with OpenHost's persistent-volume contract. The bridge replaces `/config`
with a symlink to `$OPENHOST_APP_DATA_DIR` at image build time; the
upstream `VOLUME /config` directive then resolves through the symlink
to the persistent path at `docker run`, and OpenHost's own `-v` bind
mount already occupies that path, so webtop's `/config` ends up backed
by the OpenHost persistent volume without any runtime mount gymnastics.
TLS is terminated by the OpenHost router; only the upstream HTTP
listener on port 3000 is exposed to the router.

## What you get

- Ubuntu + XFCE desktop session.
- Browser-based client served on a single HTTPS URL
  (`https://webtop.<your-compute-space>/`).
- Persistent home directory: everything the `abc` user stores in their
  home (including `proot-apps`, Firefox/Chromium profiles, shell
  history, downloads, etc.) survives rebuilds.
- Clipboard sync, file upload/download, audio in/out, and the other
  Selkies features that ship in the upstream image.

## Deploying

```
oh app deploy https://github.com/imbue-openhost/openhost-webtop --wait
```

The app is available at `https://webtop.<zone-domain>/` and is gated
behind OpenHost auth (no `public_paths` are declared).

## Installing applications

The container filesystem is ephemeral, so packages installed with
`apt-get install` inside the desktop disappear on rebuild. Two options
for persistent installs:

- **proot-apps** (recommended for most GUI apps). Open a terminal inside
  the desktop and run `proot-apps install <name>`. Installs go into
  `~/proot-apps/` which is on the persistent volume.
- **DOCKER_MODS**. Add the
  [`universal-package-install`](https://github.com/linuxserver/docker-mods/tree/universal-package-install)
  mod to install apt packages on every container start. This is not
  currently wired up in `openhost.toml`; edit the manifest (add
  `DOCKER_MODS` + `INSTALL_PACKAGES` env vars via a custom Dockerfile
  layer) if you want this.

## Security

- The container has no internal auth. Access is gated by OpenHost's
  built-in session auth, so only the compute space owner can reach it.
- `sudo` inside the desktop is passwordless by upstream default. Anyone
  who can access the desktop can become root inside the container. Do
  not add `public_paths` for this app unless you understand that
  implication.
- No extra Linux capabilities are requested; the image runs with
  Docker's default capability set.

## Resource tuning

The default manifest requests 4 GiB RAM and 2 CPU cores. XFCE itself is
lightweight; this budget is sized for running a browser and a few
desktop apps at once. Edit `[resources]` in `openhost.toml` to adjust.

## Known limitations

- **No `--shm-size` control.** OpenHost's manifest spec does not expose
  Docker's `--shm-size` flag. The container runs with Docker's 64 MiB
  default. This is noticeable in Chromium with many tabs open but is
  otherwise fine for typical usage. The upstream webtop documentation
  recommends 1 GiB here; if OpenHost adds a manifest field for it, bump
  this.

- **No GPU acceleration.** The `devices` and `gpu` manifest fields
  would need the host compute space to actually have a GPU; on the
  typical compute space they don't, so we leave this off.

- **Large image.** The upstream webtop image is ~1.6 GiB. First deploy
  will take a while to pull and build.

## Files

- `openhost.toml` — OpenHost manifest.
- `Dockerfile` — extends `lscr.io/linuxserver/webtop:ubuntu-xfce` with
  our bridge entrypoint.
- `openhost-entrypoint.sh` — verifies that `/config` has been
  replaced with a symlink to `$OPENHOST_APP_DATA_DIR` (set up by the
  Dockerfile at build time). Seeds the persistent dir from
  `/opt/webtop-baseline` (a copy of the baseline `/config` the image
  shipped with) when the persistent dir is empty. Runs a symlink-safe
  `chown` of the persistent dir (using `find -xdev` and `chown -h`)
  once per container start, then hands off to upstream s6-overlay.
