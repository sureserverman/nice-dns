#!/bin/sh
# shellcheck disable=SC3040
# Targets Alpine's busybox ash, not strict POSIX sh.
set -eu

# pihole-FTL refuses to start without /etc/pihole/pihole.toml. If the
# operator hasn't supplied one (typical for fresh container starts and for
# downstream images that don't ship config), copy the default we baked in
# at build time. Existing operator config is never overwritten.
if [ ! -f /etc/pihole/pihole.toml ]; then
    cp /etc/pihole/pihole.toml.default /etc/pihole/pihole.toml
fi

# Optional: any FTLCONF_* env vars are interpreted by pihole-FTL itself
# at startup (upstream feature) — no shell-side templating required here.
# See https://docs.pi-hole.net/ftldns/configfile/ for the env var schema.

# Admin password, with the upstream image's Docker contract
# (https://docs.pi-hole.net/docker/configuration/): FTLCONF_webserver_api_password
# wins; otherwise WEBPASSWORD_FILE names a secret file in /run/secrets. A
# secret that was named but cannot be read stops the container: starting
# with an unknown or empty password would be worse than not starting.
if [ -z "${FTLCONF_webserver_api_password+x}" ] && [ -n "${WEBPASSWORD_FILE+x}" ]; then
    case "$WEBPASSWORD_FILE" in
        ''|.|..|*/*)
            echo "start.sh: WEBPASSWORD_FILE must name a file in /run/secrets; refusing to start" >&2
            exit 1 ;;
    esac
    if [ ! -f "/run/secrets/$WEBPASSWORD_FILE" ] || [ ! -r "/run/secrets/$WEBPASSWORD_FILE" ] \
        || [ ! -s "/run/secrets/$WEBPASSWORD_FILE" ]; then
        echo "start.sh: WEBPASSWORD_FILE=$WEBPASSWORD_FILE is not a readable, non-empty file in /run/secrets; refusing to start" >&2
        exit 1
    fi
    FTLCONF_webserver_api_password="$(cat "/run/secrets/$WEBPASSWORD_FILE")"
    export FTLCONF_webserver_api_password
    echo "start.sh: admin password set from WEBPASSWORD_FILE"
fi

# No password anywhere: never serve an open admin API. Upstream assigns a
# random password and prints it to the log; this image assigns one and
# prints nothing. Supply WEBPASSWORD_FILE (or FTLCONF_webserver_api_password)
# to choose it; an explicit empty FTLCONF_webserver_api_password still means
# "no password", as upstream.
if [ -z "${FTLCONF_webserver_api_password+x}" ] \
    && [ -z "$(pihole-FTL --config webserver.api.pwhash 2>/dev/null)" ]; then
    # (od is removed by the Dockerfile's hardening; without pipefail tr's
    # SIGPIPE is harmless.)
    FTLCONF_webserver_api_password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)"
    # An empty value would mean "no password": fail closed instead.
    if [ "${#FTLCONF_webserver_api_password}" -lt 48 ]; then
        echo "start.sh: could not generate an admin password; refusing to start" >&2
        exit 1
    fi
    export FTLCONF_webserver_api_password
    echo "start.sh: no admin password configured; a random one was set and not shown (use WEBPASSWORD_FILE to choose it)"
fi

exec pihole-FTL -f
