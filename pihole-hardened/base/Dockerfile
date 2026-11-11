FROM alpine:3.21.3

LABEL org.opencontainers.image.source="https://github.com/sureserverman/pi-hole-hardened"

SHELL ["/bin/sh", "-o", "pipefail", "-c"]

# HTTPS-only apk repositories (matches sibling images).
RUN echo "https://alpine.global.ssl.fastly.net/alpine/v$(cut -d . -f 1,2 < /etc/alpine-release)/main" > /etc/apk/repositories \
    && echo "https://alpine.global.ssl.fastly.net/alpine/v$(cut -d . -f 1,2 < /etc/alpine-release)/community" >> /etc/apk/repositories

ENV APP_USER=pihole
ENV APP_DIR="/$APP_USER"
ENV DATA_DIR="$APP_DIR/data"
ENV CONF_DIR="$APP_DIR/conf"

# Buildx-injected; used to pick the right pihole-FTL binary at build time.
ARG TARGETARCH
ARG TARGETVARIANT

# Pinned in docs/decisions.md. Override at build time with --build-arg X=Y.
ARG FTL_VERSION=v6.6.1
ARG PIHOLE_CORE_VERSION=v6.4.2
ARG PIHOLE_WEB_VERSION=v6.5

RUN apk add --no-cache ca-certificates

# App user and pihole runtime directories. /etc/pihole and /var/log/pihole are
# the canonical pihole config + log paths — kept on the FS owned by the
# unprivileged user instead of relocated, so the upstream CLI scripts work
# unmodified.
RUN adduser -s /bin/true -u 1000 -D -h "$APP_DIR" "$APP_USER" \
    && mkdir -p "$DATA_DIR" "$CONF_DIR" /etc/pihole /var/log/pihole /var/www/html/admin /opt/pihole \
    && chown -R "$APP_USER:$APP_USER" "$APP_DIR" "$CONF_DIR" "$DATA_DIR" /etc/pihole /var/log/pihole /var/www/html /opt/pihole \
    && chmod 700 "$APP_DIR" "$DATA_DIR" "$CONF_DIR" \
    && chmod 755 /etc/pihole /var/log/pihole /var/www/html/admin /opt/pihole

# Hardening (mirrors ironpeakservices/iron-alpine).
# Note: pihole-FTL is later installed at /usr/bin/pihole-FTL, NOT /sbin or
# /usr/sbin, so the find ... -delete pass below leaves it untouched.
RUN rm -fr /var/spool/cron /etc/crontabs /etc/periodic \
    && find /sbin /usr/sbin ! -type d -a ! -name apk -a ! -name ln -delete \
    && find / -xdev -type d -perm +0002 -exec chmod o-w {} + \
    && find / -xdev -type f -perm +0002 -exec chmod o-w {} + \
    && chmod 777 /tmp/ && chown $APP_USER:root /tmp/ \
    && sed -i -r "/^($APP_USER|root|nobody)/!d" /etc/group \
    && sed -i -r "/^($APP_USER|root|nobody)/!d" /etc/passwd \
    && sed -i -r 's#^(.*):[^:]*$#\1:/sbin/nologin#' /etc/passwd \
    && { while IFS=: read -r username _; do passwd -l "$username"; done < /etc/passwd || true; } \
    && find /bin /etc /lib /sbin /usr -xdev -type f -regex '.*-$' -exec rm -f {} + \
    && find /bin /etc /lib /sbin /usr -xdev -type d -exec chown root:root {} \; -exec chmod 0755 {} \; \
    && find /bin /etc /lib /sbin /usr -xdev -type f -a \( -perm +4000 -o -perm +2000 \) -delete \
    && find /bin /etc /lib /sbin /usr -xdev \( \
         -iname hexdump -o -iname chgrp -o -iname ln -o -iname od -o \
         -iname strings -o -iname su -o -iname sudo \) -delete \
    && rm -fr /etc/init.d /lib/rc /etc/conf.d /etc/inittab /etc/runlevels /etc/rc.conf /etc/logrotate.d \
    && rm -fr /etc/sysctl* /etc/modprobe.d /etc/modules /etc/mdev.conf /etc/acpi \
    && rm -fr /root \
    && rm -f /etc/fstab \
    && find /bin /etc /lib /sbin /usr -xdev -type l -exec test ! -e {} \; -delete

COPY --chown=root:root --chmod=500 post-install.sh "$APP_DIR/"

WORKDIR $APP_DIR

# --- Application layer ---
# Runtime apk packages locked in docs/required-binaries.md. tini is PID 1.
# bind-tools is needed for both the healthcheck (dig) and the upstream
# diagnostics scripts. iproute2 + jq are needed by the pihole CLI.
RUN apk -U --no-cache upgrade \
    && apk add --no-cache bash sqlite tini bind-tools curl jq iproute2 ncurses-terminfo-base git

# --- pihole-FTL: per-arch download + SHA256 verify ---
# checksums/FTL-${FTL_VERSION}.sha256 lists 4 lines, one per upstream binary
# name. We pick the line for our buildx target and verify before installing.
COPY checksums/FTL-${FTL_VERSION}.sha256 /tmp/FTL.sha256
RUN set -eu; \
    case "${TARGETARCH}${TARGETVARIANT}" in \
        amd64)   suffix=amd64 ;; \
        arm64)   suffix=arm64 ;; \
        armv7)   suffix=armv7 ;; \
        riscv64) suffix=riscv64 ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH} TARGETVARIANT=${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/pi-hole/FTL/releases/download/${FTL_VERSION}/pihole-FTL-${suffix}"; \
    echo "Fetching ${url}"; \
    wget -q "${url}" -O /usr/bin/pihole-FTL; \
    expected=$(awk -v want="pihole-FTL-${suffix}" '$2==want{print $1}' /tmp/FTL.sha256); \
    test -n "$expected" || { echo "no SHA256 entry for pihole-FTL-${suffix}" >&2; exit 1; }; \
    actual=$(sha256sum /usr/bin/pihole-FTL | awk '{print $1}'); \
    test "$expected" = "$actual" || { echo "SHA256 mismatch for ${suffix}: expected=$expected actual=$actual" >&2; exit 1; }; \
    chmod 0755 /usr/bin/pihole-FTL; \
    rm /tmp/FTL.sha256; \
    # Fetch the upstream-default pihole.toml that pairs with this FTL_VERSION.
    # Stays at /etc/pihole/pihole.toml.default until start.sh installs it on
    # first run (operator-supplied configs win).
    wget -q "https://github.com/pi-hole/FTL/releases/download/${FTL_VERSION}/pihole.toml" \
        -O /etc/pihole/pihole.toml.default; \
    chown "$APP_USER:$APP_USER" /etc/pihole/pihole.toml.default

# Grant CAP_NET_BIND_SERVICE so pihole-FTL can listen on :53 and :80
# without being root. libcap is installed as a virtual package — `apk del
# .setcap-deps` removes it again only if no installed package depends on it.
RUN apk add --no-cache --virtual .setcap-deps libcap \
    && setcap 'cap_net_bind_service=+ep' /usr/bin/pihole-FTL \
    && getcap /usr/bin/pihole-FTL | grep -q cap_net_bind_service \
    && apk del .setcap-deps

# --- pihole CLI + web admin assets ---
# Both repos are pure script/HTML — no compilation. Cloned at the pinned tags
# from docs/decisions.md. After clone, neutralize sudo invocations (we already
# run as the pihole user; gravity.sh's `sudo -u pihole test -r` is a no-op
# we want to skip cleanly).
RUN set -eu; \
    git clone --depth 1 --branch "${PIHOLE_CORE_VERSION}" https://github.com/pi-hole/pi-hole /tmp/core; \
    # Mirrors upstream's installer layout: gravity.sh, pihole, and the
    # contents of advanced/Scripts/ all land flat in /opt/pihole/. Internal
    # `source /opt/pihole/utils.sh` lines depend on this flattening.
    cp -r /tmp/core/advanced/Scripts/. /opt/pihole/; \
    cp /tmp/core/gravity.sh /tmp/core/pihole /opt/pihole/; \
    ln -s /opt/pihole/pihole /usr/local/bin/pihole; \
    chmod 0755 /opt/pihole/pihole /opt/pihole/gravity.sh /opt/pihole/*.sh; \
    find /opt/pihole -type f -name '*.sh' -print0 \
      | xargs -0 sed -i -E 's/(^|[[:space:]])sudo[[:space:]]+/\1/g'; \
    # Keep a full copy of the upstream tree at /etc/.pihole/ — this is where
    # gravity.sh sources advanced/Templates/gravity.db.sql and the
    # database_migration scripts from. Mirrors the layout upstream's
    # `basic-install.sh` produces on a host install. Drop the .git/ and
    # test/ subdirs to keep the image lean.
    rm -rf /tmp/core/.git /tmp/core/test; \
    mv /tmp/core /etc/.pihole; \
    git clone --depth 1 --branch "${PIHOLE_WEB_VERSION}" https://github.com/pi-hole/web /tmp/web; \
    cp -r /tmp/web/. /var/www/html/admin/; \
    rm -rf /tmp/web; \
    # Pre-seed /etc/pihole/versions so `pihole -v` doesn't shell out to git
    # at runtime (we don't ship git in the final image). updatechecker.sh
    # would otherwise ask git for tag/branch/hash; we have all three from the
    # pinned ARGs above.
    { \
      echo "CORE_VERSION=${PIHOLE_CORE_VERSION}"; \
      echo "CORE_BRANCH=master"; \
      echo "CORE_HASH=null"; \
      echo "GITHUB_CORE_VERSION=${PIHOLE_CORE_VERSION}"; \
      echo "GITHUB_CORE_HASH=null"; \
      echo "WEB_VERSION=${PIHOLE_WEB_VERSION}"; \
      echo "WEB_BRANCH=master"; \
      echo "WEB_HASH=null"; \
      echo "GITHUB_WEB_VERSION=${PIHOLE_WEB_VERSION}"; \
      echo "GITHUB_WEB_HASH=null"; \
      echo "FTL_VERSION=${FTL_VERSION}"; \
      echo "FTL_BRANCH=master"; \
      echo "FTL_HASH=null"; \
      echo "GITHUB_FTL_VERSION=${FTL_VERSION}"; \
      echo "GITHUB_FTL_HASH=null"; \
    } > /etc/pihole/versions; \
    chown -R "$APP_USER:$APP_USER" /opt/pihole /var/www/html /etc/pihole /var/log/pihole /etc/.pihole; \
    apk del git

# --- entrypoint ---
COPY --chown=root:root --chmod=755 start.sh /bin/start.sh

# Healthcheck queries the local pihole-FTL via dig. `pi.hole` resolves locally
# even with empty gravity, so this exercises the resolver without any upstream
# traffic. Same shape as hardened-unbound's id.server CHAOS TXT.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD ["dig", "+short", "+norecurse", "+retry=0", "+time=3", "@127.0.0.1", "pi.hole"]

# NOTE: post-install.sh is NOT run here so downstream images can layer on
# adlists/allowlists and call it themselves. Downstream MUST:
#   1. RUN $APP_DIR/post-install.sh   (lock down APP_DIR, remove apk)
#   2. USER pihole                    (drop privileges; CAP_NET_BIND_SERVICE
#                                      is already on /usr/bin/pihole-FTL)

ENTRYPOINT ["tini", "--"]
CMD ["/bin/start.sh"]
