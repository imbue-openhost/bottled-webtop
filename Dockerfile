# syntax=docker/dockerfile:1
#
# openhost-webtop
#
# A full XFCE Linux desktop, served to any modern web browser via Selkies,
# wrapped to fit the OpenHost app contract.
#
# Upstream image: https://github.com/linuxserver/docker-webtop
#   - Listens on HTTP :3000 and HTTPS :3001 by default.
#   - Persists user state under /config.
#   - Managed by s6-overlay.
#   - Declares `VOLUME /config` in the baseimage.
#
# OpenHost contract quirks we have to bridge:
#
#   - Containers get a persistent data directory at OPENHOST_APP_DATA_DIR
#     (typically /data/app_data/<app_name>), NOT at /config.
#   - OpenHost does not expose Docker's --security-opt or any mechanism
#     to relax the default seccomp profile, which blocks the mount
#     syscall even with SYS_ADMIN. So we cannot bind-mount
#     OPENHOST_APP_DATA_DIR over /config from inside the container.
#   - The `VOLUME /config` directive means Docker auto-creates a volume
#     at /config at runtime, making it a kernel mountpoint we cannot
#     delete or replace.
#
# The trick we use: replace /config in the image with a symlink to
# OPENHOST_APP_DATA_DIR *at build time*, before VOLUME /config is
# re-processed at runtime. When Docker resolves VOLUME /config it
# follows the symlink to its target and looks for a bind mount there
# instead of creating an anonymous volume; OpenHost has already bind-
# mounted the persistent volume at OPENHOST_APP_DATA_DIR, so the VOLUME
# directive is effectively satisfied by the OpenHost bind mount and all
# of webtop's writes to /config go through the symlink to the persistent
# volume.
#
# TLS is terminated by the OpenHost router; only the upstream HTTP
# listener on port 3000 is exposed.

FROM lscr.io/linuxserver/webtop:ubuntu-xfce

# OPENHOST_APP_DATA_DIR is /data/app_data/<name> for an app with
# [data] app_data = true. Hardcode this because OpenHost sets the env
# var at run time (too late for build-time RUN) and because OpenHost's
# internal container mount path is structural, not configurable.
ENV OPENHOST_APP_DATA_DIR_TARGET=/data/app_data/webtop

# Move the baseline /config contents somewhere safe so our bridge
# entrypoint can seed the persistent dir from them on first boot, then
# replace /config with a symlink. Because VOLUME /config is declared in
# the parent image, Docker will re-process it on every `docker run` and
# create the anonymous volume at the symlink target (our persistent
# path), which OpenHost's -v bind mount already occupies. The bind mount
# wins, so webtop sees the persistent volume at /config.
RUN mkdir -p /opt/webtop-baseline \
    && cp -a /config/. /opt/webtop-baseline/ \
    && rm -rf /config \
    && ln -s "$OPENHOST_APP_DATA_DIR_TARGET" /config

# Bridge entrypoint: see openhost-entrypoint.sh. Seeds the persistent
# dir from /opt/webtop-baseline on first boot, chowns, then execs s6.
COPY openhost-entrypoint.sh /usr/local/bin/openhost-entrypoint.sh
RUN chmod +x /usr/local/bin/openhost-entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/openhost-entrypoint.sh"]
