# syntax=docker/dockerfile:1
#
# openhost-webtop
#
# A full XFCE Linux desktop, served to any modern web browser via Selkies /
# KasmVNC, wrapped to fit the OpenHost app contract.
#
# Upstream image: https://github.com/linuxserver/docker-webtop
#   - Listens on HTTP :3000 and HTTPS :3001 by default.
#   - Persists user state under /config.
#   - Managed by s6-overlay.
#
# OpenHost contract quirks we have to bridge:
#   - Containers get a persistent data directory at OPENHOST_APP_DATA_DIR
#     (typically /data/app_data/<app_name>), NOT at /config. The
#     upstream Dockerfile declares `VOLUME /config`, which makes /config
#     a kernel mountpoint at runtime; we cannot replace it with a
#     symlink and we cannot rm it. Instead, our entrypoint bind-mounts
#     OPENHOST_APP_DATA_DIR over /config on startup so all of webtop's
#     writes land on the OpenHost-managed persistent volume. This
#     requires SYS_ADMIN, which we declare in openhost.toml.
#   - The OpenHost router terminates TLS and proxies plain HTTP to our
#     port 3000. We expose only the HTTP listener; upstream's internal
#     HTTPS listener on 3001 is still started by s6-overlay but is not
#     reachable from outside.
#   - The upstream image ships an abc user and drops privileges to them
#     via PUID/PGID when s6-overlay comes up. Our bridge entrypoint runs
#     briefly as root to seed the persistent dir from the baseline if
#     empty, bind-mount /config, and chown the persistent dir, then
#     hands off to s6-overlay.
#
# We track the :ubuntu-xfce rolling tag deliberately so the image picks up
# base OS security updates. Pin this to a digest if that becomes a concern.
FROM lscr.io/linuxserver/webtop:ubuntu-xfce

# Bridge entrypoint: see openhost-entrypoint.sh for the full flow. Runs
# briefly as root to set up /config, then execs s6-overlay /init.
COPY openhost-entrypoint.sh /usr/local/bin/openhost-entrypoint.sh
RUN chmod +x /usr/local/bin/openhost-entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/openhost-entrypoint.sh"]
