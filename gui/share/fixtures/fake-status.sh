#!/bin/sh
# Test stand-in for `nice-dns status --tsv`: prints a fixture and exits with
# the given code. Usage: fake-status.sh <fixture|-> <exit>  (- prints nothing)
[ "$1" = - ] || cat "$1"
exit "$2"
