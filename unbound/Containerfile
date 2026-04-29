FROM sureserver/hardened-unbound:latest

ADD --chown=unbound:unbound etc/* /etc/unbound/

# Lock down: remove apk, set strict permissions, remove chown
RUN $APP_DIR/post-install.sh

# Drop privileges. The base image's setcap on /usr/sbin/unbound grants
# CAP_NET_BIND_SERVICE, so unbound can still bind port 53 as a non-root user.
USER unbound
