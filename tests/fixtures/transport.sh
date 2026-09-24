# shellcheck shell=bash
# Shared helpers for the proxy-image transport groups (sub-plan 02, Tasks
# 1.2 and 1.3; ARCH-04, ARCH-08, ARCH-09). Sourced by group files; the runner
# provides assert_*, fail, RUN_ID and CASE_DIR. Bash 3.2 compatible.
#
#   tp_setup <repo>        build (or reuse) localhost/nd-test-<repo>:<hash>
#                          from the sibling checkout; set the cleanup trap
#   tp_holder              a --network none namespace other containers join
#   tp_ns <cmd...>         run a host command inside that namespace
#   tp_socks_start         tests/fixtures/socksfixture.py on 127.0.0.1:9050
#                          inside the namespace (stands in for Tor)
#   tp_socks_mode <words>  accept | reject [IP...] | relay PORT
#   tp_send <port> <marker>  one TCP stream to 127.0.0.1:<port> carrying marker
#   tp_dests <marker>      "ip:port" per SOCKS request whose payload is marker
#   tp_run <name> <args>   podman run -d, joining the namespace; tracked
#
# Safety: containers are named nd-test-tp-<run id>-<case>-*, never publish a
# port, and join a --network none namespace, so nothing leaves the host
# loopback of that namespace. The production pod and its images are never
# touched. The SOCKS fixture has no route anywhere: "destinations" are only
# recorded, never contacted.

# TP_IMG, TP_SRC, TP_CTR, TP_SOCKS and TP_NSPID are read by the group files.
# shellcheck disable=SC2034
TP_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"
TP_SOCKS_PY="$NICE_DNS_ROOT/tests/fixtures/socksfixture.py"
TP_WARN="level=warning msg=\"The storage 'driver' option"

# tp_pm <podman args...>: TP_OUT (stdout+stderr, storage warning removed), TP_RC.
tp_pm() {
  TP_OUT="$(podman "$@" 2>&1)"
  TP_RC=$?
  TP_OUT="$(printf '%s\n' "$TP_OUT" | grep -v -- "$TP_WARN")"
}

tp_ns() { tp_pm unshare nsenter -t "$TP_NSPID" -n "$@"; }

tp_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# tp_src_hash <dir>: content hash of the build inputs: tracked and untracked
# (not ignored) files, excluding tests/ and the untracked bridge-eval binary.
tp_src_hash() {
  local f
  (cd "$1" && git ls-files -co --exclude-standard) | grep -v -e '^tests/' -e '^bridge-eval/bridge-eval$' \
    | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\n' "$f"
      if [ -f "$1/$f" ]; then tp_sha <"$1/$f"; else printf 'absent\n'; fi
    done | tp_sha
}

tp_setup() {
  local repo="$1" src h
  src="$TP_SIBS/$repo"
  TP_PFX="nd-test-tp-$RUN_ID-$(basename "$CASE_DIR" | tr '_' '-')"
  TP_CTRS="" TP_SOCKS_WRAP="" TP_NSPID=""
  trap tp_cleanup EXIT
  [ -f "$src/Dockerfile" ] || fail "$repo sibling checkout not found at $src"
  h="$(tp_src_hash "$src")"
  # shellcheck disable=SC2034
  TP_SRC="$src"
  TP_IMG="localhost/nd-test-$repo:$(printf '%s' "$h" | cut -c1-16)"
  if ! podman image exists "$TP_IMG" 2>/dev/null; then
    podman build -t "$TP_IMG" "$src" >"$CASE_DIR/build.log" 2>&1 \
      || fail "$repo image build failed: $(tail -n 15 "$CASE_DIR/build.log")"
  fi
  printf 'image\t%s\t%s\t%s\n' "$repo" "$TP_IMG" "$(git -C "$src" rev-parse HEAD 2>/dev/null)" >"$CASE_DIR/image.tsv"
}

tp_cleanup() {
  local c rev=""
  if [ -n "$TP_SOCKS_WRAP" ]; then
    [ -f "$CASE_DIR/socks/pypid" ] && kill "$(cat "$CASE_DIR/socks/pypid")" 2>/dev/null
    kill "$TP_SOCKS_WRAP" 2>/dev/null; wait "$TP_SOCKS_WRAP" 2>/dev/null
  fi
  for c in $TP_CTRS; do rev="$c $rev"; done
  for c in $rev; do podman rm -f -t 0 "$c" >/dev/null 2>&1; done
  return 0
}

tp_holder() {
  TP_HOLDER="$TP_PFX-ns"
  TP_CTRS="$TP_CTRS $TP_HOLDER"
  tp_pm run -d --name "$TP_HOLDER" --network none --entrypoint /bin/sleep "$TP_IMG" 900
  assert_rc 0 "$TP_RC" "network namespace holder starts: $TP_OUT"
  TP_NSPID="$(podman inspect -f '{{.State.Pid}}' "$TP_HOLDER" 2>/dev/null)"
  assert_match '^[1-9][0-9]*$' "$TP_NSPID" "holder has a pid"
}

# tp_run <name suffix> <podman run args...>: a tracked container in the namespace.
tp_run() {
  local n="$TP_PFX-$1"
  shift
  TP_CTRS="$TP_CTRS $n"
  # shellcheck disable=SC2034
  TP_CTR="$n"
  tp_pm run -d --name "$n" --network "container:$TP_HOLDER" "$@"
  assert_rc 0 "$TP_RC" "container $n starts: $TP_OUT"
}

tp_socks_start() {
  local d="$CASE_DIR/socks" i=0
  mkdir -m 700 "$d" || fail "cannot create $d"
  podman unshare nsenter -t "$TP_NSPID" -n sh -c 'echo $$ >"$1/pypid"; exec python3 "$2" --state "$1" --max-seconds "$3"' \
    sh "$d" "$TP_SOCKS_PY" "${FX_MAX_SECONDS:-600}" >"$d/fixture.log" 2>&1 </dev/null &
  TP_SOCKS_WRAP=$!
  while [ ! -f "$d/ready" ]; do
    i=$((i + 1))
    [ "$i" -le 300 ] || fail "SOCKS fixture did not start: $(cat "$d/fixture.log")"
    sleep 0.05
  done
  TP_SOCKS="$d"
}

tp_socks_mode() { printf '%s\n' "$*" >"$TP_SOCKS/mode"; }

# tp_wait_listen <port> [seconds]: wait until something listens on the port.
tp_wait_listen() {
  local i=0 max=$(( ${2:-20} * 5 ))
  while [ "$i" -lt "$max" ]; do
    tp_ns ss -Hltn "sport = :$1"
    case "$TP_OUT" in *LISTEN*) return 0 ;; esac
    i=$((i + 1)); sleep 0.2
  done
  return 1
}

# tp_send <port> <marker>: connect, send the marker, wait briefly for close.
tp_send() {
  # shellcheck disable=SC2016
  tp_ns python3 -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(sys.argv[2].encode())
s.settimeout(3)
try:
    s.recv(64)
except OSError:
    pass
s.close()' "$1" "$2"
}

tp_dests() {
  awk -F '\t' -v m="$1" '$5 == m { print $2 ":" $3 }' "$TP_SOCKS/connects.tsv" | LC_ALL=C sort -u
}
