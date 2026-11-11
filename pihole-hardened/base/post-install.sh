#!/usr/bin/env sh
# shellcheck disable=SC3040
# Targets Alpine's busybox ash, which supports `set -o pipefail` even though
# strict POSIX sh does not. Same pattern as sibling images.

# Lock down the image after downstream Dockerfiles have layered on their
# adlists/allowlists/config. Removes apk, freezes app dir permissions,
# self-deletes. Mirrors hardened-unbound/post-install.sh; amended to
# preserve the pihole runtime dirs (/etc/pihole, /opt/pihole,
# /var/log/pihole, /var/www/html) which must remain writable/readable
# by the pihole user.

set -e
set -o pipefail

# remove apk package manager
find / -type f -iname '*apk*' -xdev -delete
find / -type d -iname '*apk*' -print0 -xdev | xargs -0 rm -r --

# Freeze $APP_DIR (no app config lives here for pihole — it's at /etc/pihole)
find "$APP_DIR" -type d -exec chmod 500 {} +
find "$APP_DIR" -type f -exec chmod 400 {} +
chmod -R u=rwx "$DATA_DIR/"

# pihole runtime dirs: directories owner-writable, files owner-only.
# /etc/pihole holds gravity.db + pihole.toml — pihole-FTL needs to write
# both at runtime (gravity rebuild, FTLCONF_* updates). /var/log/pihole
# holds pihole-FTL.log. /var/www/html/admin is the static admin UI —
# served read-only.
#
# /opt/pihole and /etc/.pihole hold the bash CLI and its sourced scripts
# (`pihole`, `gravity.sh`, the advanced/Scripts/ tree). Stripping +x with
# a blanket chmod 600 here breaks every CLI invocation (`pihole -v`,
# `pihole status`, `pihole -g`) because podman exec resolves /usr/local/
# bin/pihole through the symlink and lands on a non-executable file.
# Treat them separately: scripts owner-exec-only, data files owner-read.
for d in /etc/pihole /var/log/pihole; do
    [ -d "$d" ] && find "$d" -type d -exec chmod 700 {} +
    [ -d "$d" ] && find "$d" -type f -exec chmod 600 {} +
done
for d in /opt/pihole /etc/.pihole; do
    [ -d "$d" ] || continue
    find "$d" -type d -exec chmod 500 {} +
    find "$d" -type f \( -name '*.sh' -o -name 'pihole' -o -name 'gravity.sh' \) \
        -exec chmod 500 {} +
    find "$d" -type f \
        ! -name '*.sh' ! -name 'pihole' ! -name 'gravity.sh' \
        -exec chmod 400 {} +
done
[ -d /var/www/html ] && {
    find /var/www/html -type d -exec chmod 555 {} +
    find /var/www/html -type f -exec chmod 444 {} +
}

# chown all pihole-owned trees
chown "$APP_USER:$APP_USER" -R "$APP_DIR" "$DATA_DIR" /etc/pihole /var/log/pihole /opt/pihole
[ -d /etc/.pihole ] && chown "$APP_USER:$APP_USER" -R /etc/.pihole
chown -R "$APP_USER:$APP_USER" /var/www/html

# remove chown after use
find / \( -type f -o -type l \) -iname 'chown' -xdev -delete

# finally remove this file
rm -- "$0"
