FROM alpinelinux/unbound:latest

RUN apk add --no-cache bind-tools
ADD --chown=unbound:unbound etc/* /etc/unbound/