FROM pihole/pihole:latest

RUN apk -U --no-cache upgrade \
    && apk add --no-cache tini

COPY --chown=pihole:pihole etc/* /etc/pihole/

# Harden: lock down config, remove apk
RUN chmod 400 /etc/pihole/dns-servers.conf /etc/pihole/dnsmasq.conf \
    && find / -type f -iname '*apk*' -xdev -delete \
    && find / -type d -iname '*apk*' -print0 -xdev | xargs -0 rm -r --

ENTRYPOINT ["tini", "--", "start.sh"]