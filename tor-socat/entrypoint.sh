#!/bin/sh
# Set DNS resolver to 1.1.1.1 at container startup
# This persists even after podman restart
echo "nameserver 1.1.1.1" > /etc/resolv.conf

# Execute the original command if provided, otherwise start supervisord
if [ $# -gt 0 ]; then
    exec "$@"
else
    exec /usr/bin/supervisord -c /etc/supervisord.conf
fi
