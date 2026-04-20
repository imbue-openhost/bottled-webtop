#!/bin/bash
#
# openhost-entrypoint.sh
#
# Bridge between the OpenHost app contract and the upstream
# linuxserver/webtop container. Responsibilities:
#
#   1. Seed OPENHOST_APP_DATA_DIR (== /config via a build-time symlink)
#      from the baseline snapshot at /opt/webtop-baseline on first boot,
#      when the persistent dir is empty. /config itself resolves to
#      OPENHOST_APP_DATA_DIR (the OpenHost persistent bind mount) so
#      everything webtop writes there goes to the persistent volume.
#   2. chown the persistent dir to $PUID:$PGID (default 911:911, the abc
#      user) so upstream services can write there.
#   3. Exec the upstream s6-overlay /init so webtop comes up normally.
#
# Background: the upstream image declares `VOLUME /config`. OpenHost
# cannot mount its persistent volume directly at /config (its manifest
# API has no mount-destination field) and cannot relax Docker's default
# seccomp profile to let us bind-mount inside the container. Instead,
# the Dockerfile replaces /config with a symlink to OPENHOST_APP_DATA_DIR
# at build time, so VOLUME /config is resolved to the symlink target at
# `docker run` and OpenHost's own `-v` bind mount wins against the
# anonymous volume Docker would otherwise create. Net result: /config
# and OPENHOST_APP_DATA_DIR are the same directory at runtime.
#
# Failure policy: fail loud. A partially seeded persistent dir would
# produce a broken desktop with no clear error, so we prefer a visible
# container crash over silent misbehavior.

set -euo pipefail

log() { printf '[openhost-entrypoint] %s\n' "$*"; }
die() {
    log "FATAL: $*" >&2
    exit 1
}

# Return 0 if the directory argument contains at least one entry
# (including dotfiles), 1 if it is empty or does not exist.
#
# Important: this function is called from `if` conditions, where bash
# suppresses `set -e` inside the function body. We therefore check the
# critical commands' exit statuses explicitly rather than relying on
# set -e to catch failures, and bail out via `die` on unexpected
# errors.
dir_has_content() {
    local dir=$1
    if [[ ! -d "$dir" ]]; then
        return 1
    fi
    local probe
    probe=$(mktemp)
    # An empty probe path means mktemp failed (bash's set -e is
    # suppressed in function bodies invoked as `if` conditions, so we
    # check this explicitly). Use die() instead of return 1 so a
    # transient mktemp failure is never mis-read as "empty dir", which
    # would trigger an unwanted reseed.
    if [[ -z "$probe" ]]; then
        die "mktemp failed while probing $dir"
    fi
    local find_rc=0
    # -mindepth 1 -print -quit prints the first entry and exits
    # immediately, keeping this O(1) on non-empty dirs.
    find "$dir" -mindepth 1 -print -quit > "$probe" || find_rc=$?
    if (( find_rc != 0 )); then
        rm -f "$probe"
        die "could not probe $dir for existing content (find exited $find_rc)"
    fi
    local rc=1
    if [[ -s "$probe" ]]; then
        rc=0
    fi
    rm -f "$probe"
    # Caveat: find with -quit exits 0 even if it encountered permission
    # errors on subdirs it couldn't read, provided -quit fired on
    # something readable first. We accept this because the seed step
    # only ADDS files; it never removes anything, so at worst we'd add
    # spurious baseline files rather than lose user data.
    return "$rc"
}

# Marker written after a successful chown of PERSIST_DIR. Lives in
# /run, which Docker re-creates fresh on every container start (both
# `docker run` and `docker restart`). The marker therefore guards
# against a re-chown within a single start-to-stop cycle (important
# when the entrypoint is re-exec'd from a diagnostic `docker exec`)
# but does not survive a restart, which is fine: the persistent dir
# might have been touched by another tool in between. We keep the
# marker out of PERSIST_DIR so the persistent volume stays clean of
# bookkeeping files.
CHOWN_DONE_MARKER="/run/openhost-webtop-chowned"

# Path where the Dockerfile stashed the baseline /config contents
# before replacing /config with a symlink. Only used for first-boot
# seeding.
BASELINE_DIR="/opt/webtop-baseline"

if [[ -z "${OPENHOST_APP_DATA_DIR:-}" ]]; then
    die "OPENHOST_APP_DATA_DIR is not set; refusing to start."
fi

PERSIST_DIR="$OPENHOST_APP_DATA_DIR"
log "Persistent data dir: $PERSIST_DIR"

if ! mkdir -p "$PERSIST_DIR"; then
    die "could not create $PERSIST_DIR. Check that the OpenHost persistent volume for this app is mounted and writable."
fi

# /config should be a symlink to PERSIST_DIR (created by the Dockerfile).
# Verify before we do anything else -- if it isn't, the VOLUME trick has
# broken down and later steps would silently write to the wrong place.
if [[ ! -L /config ]]; then
    die "/config is not a symlink. The Dockerfile expected to replace /config with 'ln -s $PERSIST_DIR /config' at build time; something in the image has diverged from that."
fi
if [[ "$(readlink -f /config)" != "$(readlink -f "$PERSIST_DIR")" ]]; then
    die "/config symlink does not resolve to $PERSIST_DIR. Got $(readlink /config) -> $(readlink -f /config)."
fi

# Step 1: seed PERSIST_DIR if it is empty and we have a baseline to
# copy from. We never destroy existing contents of PERSIST_DIR; a
# partial seed from a crashed prior boot is a user-recoverable
# condition (remove and redeploy), not something we auto-repair at the
# risk of destroying real user data.
if dir_has_content "$PERSIST_DIR"; then
    log "Persistent dir already has user state; not reseeding from baseline"
elif dir_has_content "$BASELINE_DIR"; then
    log "Seeding empty persistent dir from $BASELINE_DIR"
    # `$BASELINE_DIR/.` copies the contents (including dotfiles) into
    # PERSIST_DIR without creating a nested baseline/ directory.
    # `-a` preserves permissions/ownership/timestamps.
    if ! cp -a "$BASELINE_DIR"/. "$PERSIST_DIR"/; then
        die "failed to seed persistent dir from $BASELINE_DIR. PERSIST_DIR may contain a partial copy; remove the app data via 'oh app remove' and redeploy."
    fi
else
    log "Persistent dir is empty and $BASELINE_DIR has no baseline to seed from; continuing without seeding"
fi

# Step 2: ownership. The default PUID/PGID in the upstream image is
# 911/911 (the abc user). Honor any caller-provided override but
# otherwise keep the default.
export PUID="${PUID:-911}"
export PGID="${PGID:-911}"
log "Running webtop as PUID=$PUID PGID=$PGID"

if [[ -f "$CHOWN_DONE_MARKER" ]]; then
    log "Ownership already fixed up in this container; skipping recursive chown"
else
    log "Setting ownership of $PERSIST_DIR to $PUID:$PGID"
    # Use chown -h (don't dereference symlinks) via find -exec so
    # symlinks under the user's home can't trick chown into
    # re-targeting ownership on the symlink target. -xdev stays on
    # the same filesystem.
    if ! find "$PERSIST_DIR" -xdev -exec chown -h "$PUID:$PGID" {} +; then
        die "failed to chown $PERSIST_DIR to $PUID:$PGID. Check that PUID/PGID are valid numeric IDs and that the persistent volume is not mounted read-only."
    fi
    if ! touch "$CHOWN_DONE_MARKER"; then
        die "failed to write chown marker at $CHOWN_DONE_MARKER. /run should be a writable tmpfs in a normal container."
    fi
fi

# Hand off to the upstream s6-overlay init. Using exec ensures we
# replace this shell so signals (SIGTERM from docker stop) reach s6
# directly.
log "Handing off to s6-overlay /init"
exec /init "$@"
