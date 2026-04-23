#!/bin/bash
#
# openhost-entrypoint.sh
#
# Bridge between the OpenHost app contract and the upstream
# linuxserver/webtop container.
#
# Persistence strategy
# --------------------
#
# The upstream image declares `VOLUME /config`, which Docker/podman
# materializes as an anonymous volume mounted at /config inside the
# container on every fresh start. Anonymous volumes do not survive
# container removal, and OpenHost rebuilds the container on every
# reload, so if we do nothing webtop's home directory gets wiped
# each deploy.
#
# A previous attempt replaced /config with a symlink to
# OPENHOST_APP_DATA_DIR at image build time, so the later `VOLUME`
# resolution would follow the symlink to OpenHost's bind-mounted
# path. Buildah (which OpenHost uses) materializes VOLUME even
# during RUN steps, so `rm -rf /config` inside the Dockerfile fails
# with EBUSY on the mountpoint itself. We can't swap /config as a
# directory at runtime either, for the same reason. Bind-mounting
# OPENHOST_APP_DATA_DIR over /config at runtime would require
# CAP_SYS_ADMIN plus a relaxed seccomp profile; OpenHost provides
# neither.
#
# Workaround: treat /config as a write-through indirection layer.
# Leave /config as the kernel mountpoint it is, but replace each
# *entry inside* /config with a symlink to a matching path under
# OPENHOST_APP_DATA_DIR. Webtop's actual writes (browser profiles
# under /config/.mozilla/, desktop files under /config/Desktop/,
# shell history under /config/.bash_history, proot-apps under
# /config/proot-apps/, etc.) all happen one level below /config,
# so they transit through the symlink into the persistent volume.
#
# Caveats:
#   - Files created directly AT /config/<new-top-level-file> after
#     startup land on the anonymous volume and are lost on reload.
#     Webtop doesn't do this in normal operation.
#   - Users creating brand-new top-level files/dirs after first
#     boot won't find them re-symlinked. The entrypoint re-applies
#     the symlink pass on every container start, picking up any
#     new entries that ended up on the anonymous volume IF they
#     weren't already evicted. To be safe, we also copy any new
#     top-level entries from /config into the persistent dir on
#     shutdown... actually no, there's no clean shutdown hook;
#     users should avoid putting data directly at /config root.
#
# Failure policy: fail loud. A partially-wired persistent dir
# would produce a broken desktop with no clear error.

set -euo pipefail

log() { printf '[openhost-entrypoint] %s\n' "$*"; }
die() {
    log "FATAL: $*" >&2
    exit 1
}

# Marker written after a successful chown of PERSIST_DIR. Lives in
# /run (a tmpfs Docker recreates each container start) so it guards
# against re-chown within a single start-to-stop cycle without
# persisting across restarts, which would skip a chown we legitimately
# need after PUID/PGID changes.
CHOWN_DONE_MARKER="/run/openhost-webtop-chowned"

# Path where the Dockerfile stashed the baseline /config contents
# before VOLUME materialization wiped the live /config. Used for
# first-boot seeding and for ensuring the persistent dir contains
# entries for all the paths webtop expects.
BASELINE_DIR="/opt/webtop-baseline"

if [[ -z "${OPENHOST_APP_DATA_DIR:-}" ]]; then
    die "OPENHOST_APP_DATA_DIR is not set; refusing to start."
fi

PERSIST_DIR="$OPENHOST_APP_DATA_DIR"
log "Persistent data dir: $PERSIST_DIR"

if ! mkdir -p "$PERSIST_DIR"; then
    die "could not create $PERSIST_DIR. Check that the OpenHost persistent volume for this app is mounted and writable."
fi

if [[ ! -d /config ]]; then
    die "/config does not exist. The upstream webtop image should provide this as a VOLUME mountpoint."
fi

# Step 1: seed any missing baseline entries into PERSIST_DIR. We
# only ADD; we never remove or overwrite existing user data. Missing
# entries happen on first boot (PERSIST_DIR is empty) or when the
# upstream image adds new default config files between versions.
if [[ -d "$BASELINE_DIR" ]]; then
    log "Seeding missing baseline entries into $PERSIST_DIR"
    # -n: never overwrite an existing file. -a: preserve
    # permissions/ownership/timestamps.
    if ! cp -an "$BASELINE_DIR"/. "$PERSIST_DIR"/; then
        die "failed to seed $PERSIST_DIR from $BASELINE_DIR."
    fi
else
    log "No baseline directory at $BASELINE_DIR; skipping seed"
fi

# Step 2: wire every top-level entry in the persistent dir up as a
# symlink from /config. This is the core of the persistence bridge.
# For each entry <name> in PERSIST_DIR, ensure /config/<name> is a
# symlink to PERSIST_DIR/<name>.
#
# Handling pre-existing /config/<name>:
#   * if it's already the correct symlink -> leave it
#   * if it's the wrong symlink -> replace
#   * if it's a real file or dir (came from the anonymous volume
#     seed that buildah leaves in the mountpoint) -> delete and
#     replace with the symlink, since the PERSIST_DIR copy is
#     authoritative.
log "Wiring /config/<entry> symlinks into $PERSIST_DIR"
shopt -s dotglob nullglob
for src in "$PERSIST_DIR"/*; do
    name="$(basename "$src")"
    # Defensively skip anything our own tooling writes and does
    # not want symlinked into the desktop home. None at the moment,
    # but keeps the door open.
    case "$name" in
        .ok-to-copy) continue ;;
    esac
    link="/config/$name"
    want_target="$src"

    if [[ -L "$link" ]]; then
        existing_target="$(readlink "$link")"
        if [[ "$existing_target" == "$want_target" ]]; then
            continue
        fi
        log "  retargeting $link: $existing_target -> $want_target"
        rm -f "$link"
    elif [[ -e "$link" ]]; then
        log "  replacing pre-existing $link with symlink to $want_target"
        rm -rf "$link"
    fi
    ln -s "$want_target" "$link"
done
shopt -u dotglob nullglob

# Step 3: ownership. The default PUID/PGID in the upstream image is
# 911/911 (the abc user). Respect caller-provided overrides.
export PUID="${PUID:-911}"
export PGID="${PGID:-911}"
log "Running webtop as PUID=$PUID PGID=$PGID"

if [[ -f "$CHOWN_DONE_MARKER" ]]; then
    log "Ownership already fixed up in this container; skipping recursive chown"
else
    log "Setting ownership of $PERSIST_DIR to $PUID:$PGID"
    # -h (don't dereference symlinks) and -xdev (stay on the same
    # filesystem) keep chown from leaking into bind-mounted host
    # paths that symlinks under the user's home might point at.
    if ! find "$PERSIST_DIR" -xdev -exec chown -h "$PUID:$PGID" {} +; then
        die "failed to chown $PERSIST_DIR to $PUID:$PGID."
    fi
    # /config itself and the symlinks we made in it also need owner
    # fixups so the upstream services can traverse them.
    if ! chown -h "$PUID:$PGID" /config /config/* 2>/dev/null; then
        log "warning: chown on /config symlinks reported errors; continuing"
    fi
    if ! touch "$CHOWN_DONE_MARKER"; then
        die "failed to write chown marker at $CHOWN_DONE_MARKER."
    fi
fi

# Step 4: hand off to upstream s6-overlay. exec replaces this shell
# so SIGTERM from docker stop reaches s6 directly.
log "Handing off to s6-overlay /init"
exec /init "$@"
