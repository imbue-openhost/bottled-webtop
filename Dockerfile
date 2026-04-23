# syntax=docker/dockerfile:1
#
# openhost-webtop
#
# A full XFCE Linux desktop, served to any modern web browser via
# Selkies, wrapped to fit the OpenHost app contract.
#
# Upstream image: https://github.com/linuxserver/docker-webtop
#   - Listens on HTTP :3000 and HTTPS :3001 by default.
#   - Persists user state under /config.
#   - Managed by s6-overlay.
#   - Declares `VOLUME /config` in the baseimage.
#
# The persistence bridge is all runtime: the entrypoint symlinks
# each child of /config to a matching path under
# OPENHOST_APP_DATA_DIR, so writes through /config land on the
# OpenHost persistent volume. See openhost-entrypoint.sh for the
# full rationale. An earlier design tried to replace /config with
# a symlink at build time, but buildah materializes the upstream
# `VOLUME /config` during RUN steps, making /config a busy
# mountpoint we cannot unlink.
#
# TLS is terminated by the OpenHost router; only the upstream HTTP
# listener on port 3000 is exposed.

FROM lscr.io/linuxserver/webtop:ubuntu-xfce

# Stage a copy of the upstream /config contents at /opt/webtop-baseline.
# The entrypoint uses this to seed the persistent volume on first
# boot and then wire each /config subentry up as a symlink into the
# persistent dir (see openhost-entrypoint.sh for the rationale).
RUN mkdir -p /opt/webtop-baseline \
    && cp -a /config/. /opt/webtop-baseline/

# Bridge entrypoint: see openhost-entrypoint.sh. Seeds the persistent
# dir from /opt/webtop-baseline on first boot, chowns, then execs s6.
COPY openhost-entrypoint.sh /usr/local/bin/openhost-entrypoint.sh
RUN chmod +x /usr/local/bin/openhost-entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/openhost-entrypoint.sh"]
