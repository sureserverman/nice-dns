FROM pihole/pihole:latest

COPY --chown=pihole:pihole etc/* /etc/pihole/
COPY --chown=pihole:pihole web/* /etc/pihole/