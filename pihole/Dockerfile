FROM pihole/pihole:latest

RUN apk -U --no-cache upgrade \
    && apk add --no-cache tini

COPY --chown=pihole:pihole etc/* /etc/pihole/

# Build gravity.db at IMAGE BUILD TIME from the URL list. This recreates the
# original "fast first-start" UX (where gravity.db was committed to git as a
# 100 MB binary blob) without putting the binary in source. The container's
# /etc/resolv.conf during build inherits the host's working DNS, so blocklist
# downloads succeed cleanly here — unlike at first-container-start where
# rootless aardvark-DNS can't be reached from inside the container.
COPY --chown=pihole:pihole adlists-default.txt /tmp/adlists.txt
COPY --chown=pihole:pihole custom-allowlist.txt /tmp/allowlist.txt
RUN set -e \
    && grep -vE '^[[:space:]]*(#|$)' /tmp/adlists.txt > /etc/pihole/adlists.list \
    && chown pihole:pihole /etc/pihole/adlists.list \
    && pihole -g \
    && grep -vE '^[[:space:]]*(#|$)' /tmp/allowlist.txt | while IFS= read -r d; do \
         pihole-FTL sqlite3 -ni /etc/pihole/gravity.db \
           "INSERT OR IGNORE INTO domainlist (type, domain, enabled, comment) \
            VALUES (0, '$d', 1, 'Seeded at image build time (allowlist)');"; \
       done \
    && rm /tmp/adlists.txt /tmp/allowlist.txt

# Harden: lock down config, remove apk
RUN chmod 400 /etc/pihole/dns-servers.conf /etc/pihole/dnsmasq.conf \
    && find / -type f -iname '*apk*' -xdev -delete \
    && find / -type d -iname '*apk*' -print0 -xdev | xargs -0 rm -r --

ENTRYPOINT ["tini", "--", "start.sh"]
