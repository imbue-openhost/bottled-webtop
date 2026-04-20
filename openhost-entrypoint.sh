#!/bin/bash
#
# openhost-entrypoint.sh
#
# Bridge between the OpenHost app contract and the upstream
# linuxserver/webtop container. Responsibilities:
#
#   1. If the OpenHost-managed persistent directory
#      ($OPENHOST_APP_DATA_DIR) is empty, seed it with the upstream
#      /config baseline so webtop's abc user has a working home.
#   2. Bind-mount $OPENHOST_APP_DATA_DIR over /config so all of webtop's
#      writes land on the OpenHost persistent volume. (A symlink would
#      be simpler, but the upstream Dockerfile declares /config as a
#      VOLUME, which makes it a kernel mountpoint at runtime. You cannot
#      rm or replace a mountpoint from inside the container, so we
#      bind-mount on top of it instead.)
#   3. chown the persistent dir to $PUID:$PGID (default 911:911, the abc
#      user) so upstream services can write there. The chown runs once
#      per container start (skipped if a marker in /run says we already
#      did it in this lifetime, which matters when the entrypoint is
#      re-exec'd from a diagnostic `docker exec`).
#   4. Exec the upstream s6-overlay /init so webtop comes up normally.
#
# Requirements (expressed in openhost.toml):
#   - capabilities = ["SYS_ADMIN"]  -- needed for the bind mount.
#
# Failure policy: fail loud. A partially bridged /config would result in
# a desktop that appears to work but loses all user state on restart, so
# we prefer a visible container crash over a silent data leak.

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
# suppresses `set -e` inside the function body. We therefore check
# find's exit status explicitly rather than relying on set -e to catch
# failures, and bail out via `die` on unexpected errors (e.g. the
# directory itself is unreadable) so a caller never mis-interprets a
# transient failure as "empty".
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
    # Translate "probe file is non-empty" to a shell exit status:
    # 0 = directory has content, 1 = directory is empty.
    local rc=1
    if [[ -s "$probe" ]]; then
        rc=0
    fi
    rm -f "$probe"
    # Caveat: find with -quit exits 0 even if it encountered permission
    # errors on subdirs it couldn't read, provided -quit fired on
    # something readable first. We accept this because the seed step
    # only ADDS files; it never removes anything, so at worst we'd add
    # spurious baseline files rather than lose user data. If we're
    # killed by a signal mid-find, the probe file lingers in the
    # container's ephemeral tmpfs until container removal -- trivial.
    return "$rc"
}

# Return 0 if /config is already bind-mounted from $1 (same device and
# inode as the source). Parsing /proc/self/mountinfo would be messier
# because the source path sits after a variable-length optional-fields
# section terminated by "-"; a device+inode comparison is robust across
# kernel versions and mount-option variations.
is_config_backed_by() {
    local src=$1
    if [[ ! -d /config || ! -d "$src" ]]; then
        return 1
    fi
    local config_id src_id
    config_id=$(stat -c '%d:%i' /config) || die "stat /config failed"
    src_id=$(stat -c '%d:%i' "$src") || die "stat $src failed"
    [[ "$config_id" == "$src_id" ]]
}

# Marker written after a successful chown of PERSIST_DIR. Lives in
# /run, which is a tmpfs that Docker re-creates fresh on every
# container start (both `docker run` and `docker restart`). The marker
# therefore guards against a re-chown within a single start-to-stop
# cycle -- important when the entrypoint is re-exec'd from a
# diagnostic `docker exec` -- but does not survive a restart, which is
# fine: the persistent dir might have been touched by another tool in
# between. We keep the marker out of PERSIST_DIR so the persistent
# volume stays clean of bookkeeping files.
CHOWN_DONE_MARKER="/run/openhost-webtop-chowned"

if [[ -z "${OPENHOST_APP_DATA_DIR:-}" ]]; then
    die "OPENHOST_APP_DATA_DIR is not set; refusing to start."
fi

PERSIST_DIR="$OPENHOST_APP_DATA_DIR"
log "Persistent data dir: $PERSIST_DIR"

if ! mkdir -p "$PERSIST_DIR"; then
    die "could not create $PERSIST_DIR. Check that the OpenHost persistent volume for this app is mounted and writable."
fi

# Step 1: seed PERSIST_DIR if it is empty and /config has baseline
# content to copy from. We never destroy existing contents of
# PERSIST_DIR; a partial seed from a crashed prior boot is a user-
# recoverable condition (remove and redeploy), not something we
# auto-repair at the risk of destroying real user data.
#
# We do the probe BEFORE the bind mount, so /config here is the Docker
# anonymous volume with the baseline content the image shipped.
if dir_has_content "$PERSIST_DIR"; then
    log "Persistent dir already has user state; not reseeding from baseline"
elif dir_has_content /config; then
    log "Seeding empty persistent dir from /config baseline"
    # `/config/.` copies the contents of /config (including dotfiles)
    # into PERSIST_DIR without creating a nested /config directory.
    # `-a` preserves permissions/ownership/timestamps.
    #
    # A failed seed leaves PERSIST_DIR non-empty, which on the next
    # boot reads as "has user state" and skips reseeding. We report the
    # failure with a clear message so an operator can see why the
    # desktop never came up; recovery is "oh app remove && oh app
    # deploy" (the partial PERSIST_DIR contents come with the --data
    # removal).
    if ! cp -a /config/. "$PERSIST_DIR"/; then
        die "failed to seed persistent dir from /config baseline. PERSIST_DIR may contain a partial copy; remove the app data via 'oh app remove' and redeploy."
    fi
else
    log "Persistent dir is empty and /config has no baseline to seed from; continuing without seeding"
fi

# Step 2: bind-mount PERSIST_DIR over /config. Skip if it is already
# bound (detected by comparing device+inode, which is bind-mount-safe
# and doesn't depend on parsing mountinfo).
if is_config_backed_by "$PERSIST_DIR"; then
    log "/config is already bind-mounted from $PERSIST_DIR"
else
    log "Bind-mounting $PERSIST_DIR over /config"
    # Requires SYS_ADMIN; openhost.toml declares it. The bind shadows
    # the Docker anonymous volume at /config for the life of this
    # container; the anonymous volume itself is discarded when the
    # container is removed. The most common failure here is a missing
    # SYS_ADMIN capability, so we hint at that in the error.
    if ! mount --bind "$PERSIST_DIR" /config; then
        die "bind-mounting $PERSIST_DIR over /config failed. The SYS_ADMIN capability is required (see 'capabilities' in openhost.toml)."
    fi
fi

# Belt-and-suspenders sanity check: /config must now be backed by
# PERSIST_DIR.
if ! is_config_backed_by "$PERSIST_DIR"; then
    die "/config is not backed by $PERSIST_DIR after mount"
fi

# Step 3: ownership. The default PUID/PGID in the upstream image is
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
    # re-targeting ownership on the symlink target. -xdev stays on the
    # same filesystem, which covers the common case; a malicious bind
    # mount inside PERSIST_DIR that resolves to the same device can
    # still be traversed, but that would require root (which the
    # desktop user has anyway inside the container), so it is not an
    # elevation of privilege.
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
