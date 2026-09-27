#!/bin/sh
# Entrypoint guard for the standard image (Sub-plan 4 Task 2.1, ARCH-06).
#
# Upstream's start.sh reads /run/secrets/$WEBPASSWORD_FILE only when it can:
# an empty file becomes an empty password, which serves the admin API with no
# login at all, and a missing or unreadable one falls back to a random
# password printed to the log. The hardened image refuses both; this does the
# same here, then hands over to upstream's entrypoint unchanged.
set -eu
if [ -z "${FTLCONF_webserver_api_password+x}" ] && [ -n "${WEBPASSWORD_FILE+x}" ]; then
    case "$WEBPASSWORD_FILE" in
        ''|.|..|*/*)
            echo "nd-secret-guard: WEBPASSWORD_FILE must name a file in /run/secrets; refusing to start" >&2
            exit 1 ;;
    esac
    if [ ! -f "/run/secrets/$WEBPASSWORD_FILE" ] || [ ! -r "/run/secrets/$WEBPASSWORD_FILE" ] \
        || [ ! -s "/run/secrets/$WEBPASSWORD_FILE" ]; then
        echo "nd-secret-guard: WEBPASSWORD_FILE=$WEBPASSWORD_FILE is not a readable, non-empty file in /run/secrets; refusing to start" >&2
        exit 1
    fi
fi
exec start.sh "$@"
