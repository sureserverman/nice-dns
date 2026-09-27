#!/bin/sh
# nice-dns entry step for both Pi-hole images (Sub-plan 4, Tasks 2.1 and 2.2;
# ARCH-06). Runs before the image's own entrypoint, which it then execs:
#   standard: ENTRYPOINT ["tini", "--", "nd-start.sh", "start.sh"] (as root)
#   hardened: ENTRYPOINT ["tini", "--", "nd-start.sh"], CMD ["/bin/start.sh"]
#             (as the pihole user)
#
# 1. Admin password. Upstream's start.sh reads /run/secrets/$WEBPASSWORD_FILE
#    only when it can: an empty file becomes an empty password, which serves
#    the admin API with no login at all, and a missing or unreadable one falls
#    back to a random password printed to the log. Both are refused here.
#
# 2. The operator's lists. gravity.db lives on the lists volume
#    (/var/lib/nice-dns-pihole, pihole.toml files.gravity). The image carries
#    the gravity.db it built (its seed) and the seed's id. While the volume's
#    seed id matches, the volume is used as it is. When it differs (a new
#    image, a switch between the standard and hardened images, a rollback),
#    a fresh copy of this image's seed takes the operator's rows from the
#    previous gravity.db (merge-lists.sql), and the previous file is kept as
#    gravity.db.previous. If the merge fails, the previous lists stay in use
#    unchanged and the next start tries again. An empty volume is seeded.
set -eu

ND=/usr/share/nice-dns/pihole
L=/var/lib/nice-dns-pihole

log() { echo "nd-start: $*"; }
die() { echo "nd-start: $*; refusing to start" >&2; exit 1; }

if [ -z "${FTLCONF_webserver_api_password+x}" ] && [ -n "${WEBPASSWORD_FILE+x}" ]; then
    case "$WEBPASSWORD_FILE" in
        ''|.|..|*/*) die "WEBPASSWORD_FILE must name a file in /run/secrets" ;;
    esac
    if [ ! -f "/run/secrets/$WEBPASSWORD_FILE" ] || [ ! -r "/run/secrets/$WEBPASSWORD_FILE" ] \
        || [ ! -s "/run/secrets/$WEBPASSWORD_FILE" ]; then
        die "WEBPASSWORD_FILE=$WEBPASSWORD_FILE is not a readable, non-empty file in /run/secrets"
    fi
fi

[ -L "$L" ] && die "$L is a symlink"
[ -d "$L" ] || die "$L is missing (the lists volume)"
# A real write probe: `test -w` misses a read-only mount.
( : >"$L/.nd-write-probe" && rm -f "$L/.nd-write-probe" ) 2>/dev/null || die "$L is not writable by $(id -un)"
for f in gravity.db gravity.db.new gravity.db.previous seed-id; do
    [ -L "$L/$f" ] && die "$L/$f is a symlink"
done
sid="$(cat "$ND/seed-id")"
if [ -f "$L/gravity.db" ] && [ "$(cat "$L/seed-id" 2>/dev/null || true)" = "$sid" ]; then
    log "lists: in use (seed $sid)"
else
    rm -f "$L/gravity.db.new"
    cp "$ND/gravity.seed.db" "$L/gravity.db.new"
    if [ ! -f "$L/gravity.db" ]; then
        mv -f "$L/gravity.db.new" "$L/gravity.db"
        printf '%s\n' "$sid" >"$L/seed-id"
        log "lists: seeded (seed $sid)"
    elif sed "s|@OLD@|$L/gravity.db|" "$ND/merge-lists.sql" \
            | pihole-FTL sqlite3 -ni "$L/gravity.db.new" >/dev/null 2>"$L/merge.err"; then
        mv -f "$L/gravity.db" "$L/gravity.db.previous"
        mv -f "$L/gravity.db.new" "$L/gravity.db"
        printf '%s\n' "$sid" >"$L/seed-id"
        rm -f "$L/merge.err"
        log "lists: the operator's lists carried into seed $sid"
    else
        rm -f "$L/gravity.db.new"
        log "lists: WARNING: could not carry the operator's lists into seed $sid ($(head -c 300 "$L/merge.err" | tr '\n' ' ')); the previous lists stay in use"
    fi
fi
if [ "$(id -u)" = 0 ]; then
    chown -R pihole:pihole "$L"
fi

exec "$@"
