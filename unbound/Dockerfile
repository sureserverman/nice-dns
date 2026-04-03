FROM sureserver/hardened-unbound:latest

ADD --chown=unbound:unbound etc/* /etc/unbound/

# Lock down: remove apk, set strict permissions, remove chown
RUN $APP_DIR/post-install.sh
