# shellcheck shell=bash
# Group integration/resolver-state (sub-plan 02, Task 1.1; ARCH-06, ARCH-09).
#
# Proves the Unbound resolver state and management contract on the ACTUAL
# images: the hardened-unbound base is built from the sibling checkout
# (${NICE_DNS_SIBLINGS_DIR:-<parent of this checkout>}/hardened-unbound) and
# nice-dns/unbound is built FROM it with --build-arg BASE_IMAGE. Both tags are
# derived from the source content, so an unchanged tree is built once and
# reused by later cases and runs (the layer cache makes rebuilds cheap too).
#
#   localhost/nd-test-hardened-unbound:<hash>   candidate base
#   localhost/nd-test-unbound:<hash>            candidate product image
#
# Safety: every container is named nd-test-rs-<run id>-<case>-*, runs with
# --network none (or joins such a namespace) and is removed by the case's EXIT
# trap. Nothing here touches the production pod, its containers or images, or
# any host port. The DNSSEC fixture (tests/fixtures/dnsfixture.py) runs on the
# host but inside the test container's network namespace (podman unshare +
# nsenter -n), so it and Unbound share a loopback that has no route anywhere.
# Only controlled fixture names (fixture.test, localhost) are queried.
#
# Requires: podman (rootless), python3, openssl, dig, ss, nsenter, timeout.

# shellcheck source=tests/fixtures/fixture.sh
. "$NICE_DNS_ROOT/tests/fixtures/fixture.sh"
# shellcheck source=tests/fixtures/unbound-image.sh
. "$NICE_DNS_ROOT/tests/fixtures/unbound-image.sh"

RS_BASE_SRC="$UB_BASE_SRC"
RS_PRODUCT_SRC="$UB_PRODUCT_SRC"
RS_ANCHOR=/var/lib/unbound/root.key
RS_SEED=/usr/share/nice-dns/root-anchor.seed
RS_SOCK=/run/unbound/control.sock
RS_START=/usr/local/bin/nice-dns-unbound-start
RS_WARN="level=warning msg=\"The storage 'driver' option"

# ─────────────────────────── plumbing ────────────────────────────────────────

# rs_pm <podman args...>: RS_OUT (stdout+stderr, storage warning removed), RS_RC.
rs_pm() {
  RS_OUT="$(podman "$@" 2>&1)"
  RS_RC=$?
  RS_OUT="$(printf '%s\n' "$RS_OUT" | grep -v -- "$RS_WARN")"
}

# rs_ns <cmd...>: run a host command inside the test network namespace.
rs_ns() {
  rs_pm unshare nsenter -t "$RS_NSPID" -n "$@"
}

# rs_images: the candidate base and product images (tests/fixtures/unbound-image.sh).
rs_images() {
  ub_images
  RS_BASE_IMG="$UB_BASE_IMG" RS_IMG="$UB_IMG"
  cp "$CASE_DIR/unbound-images.tsv" "$CASE_DIR/images.tsv"
}

# rs_setup: images, unique names and the cleanup trap. Call first in a case.
rs_setup() {
  RS_PFX="nd-test-rs-$RUN_ID-$(basename "$CASE_DIR" | tr '_' '-')"
  RS_CTRS="" RS_REV="" RS_OWNED="" RS_FX_PID="" RS_FX_WRAP=""
  trap rs_cleanup EXIT
  rs_images
}

rs_cleanup() {
  local c d
  if [ -n "$RS_FX_PID" ]; then kill "$RS_FX_PID" 2>/dev/null; fi
  if [ -n "$RS_FX_WRAP" ]; then kill "$RS_FX_WRAP" 2>/dev/null; wait "$RS_FX_WRAP" 2>/dev/null; fi
  # Newest first: a namespace holder cannot be removed while a member exists.
  for c in $RS_CTRS; do RS_REV="$c $RS_REV"; done
  for c in $RS_REV; do podman rm -f -t 0 "$c" >/dev/null 2>&1; done
  # Hand container-owned test state back to the invoking user.
  for d in $RS_OWNED; do podman unshare chown -hR 0:0 "$d" >/dev/null 2>&1; done
  return 0
}

# rs_state_dir <name> [uid:gid] [mode]: sets RS_DIR, a host dir to mount as
# /var/lib/unbound (owned by the container's unbound uid 100 by default).
# Not for $(...): the dir must be recorded for cleanup in this shell.
rs_state_dir() {
  RS_DIR="$CASE_DIR/$1"
  mkdir -p "$RS_DIR"
  chmod "${3:-700}" "$RS_DIR"
  RS_OWNED="$RS_OWNED $RS_DIR"
  podman unshare chown "${2:-100:100}" "$RS_DIR" >/dev/null 2>&1 || fail "cannot chown $RS_DIR"
}

# rs_put <host path> <content> [uid:gid]: write a file owned by a container
# uid (inside a state dir that already belongs to that uid).
rs_put() {
  printf '%s' "$2" | podman unshare sh -c 'cat >"$1" && chmod 600 "$1" && chown "$2" "$1"' sh "$1" "${3:-100:100}" \
    >/dev/null 2>&1 || fail "cannot write $1"
}

# rs_holder: a --network none namespace that other containers and the fixture join.
rs_holder() {
  RS_HOLDER="$RS_PFX-ns"
  RS_CTRS="$RS_CTRS $RS_HOLDER"
  rs_pm run -d --name "$RS_HOLDER" --network none --entrypoint /bin/sleep "$RS_IMG" 900
  assert_rc 0 "$RS_RC" "network namespace holder starts: $RS_OUT"
  RS_NSPID="$(podman inspect -f '{{.State.Pid}}' "$RS_HOLDER" 2>/dev/null)"
  assert_match '^[1-9][0-9]*$' "$RS_NSPID" "holder has a pid"
}

# rs_unbound [podman run args...]: start the product image in the holder netns.
rs_unbound() {
  RS_CTR="$RS_PFX-ub"
  RS_CTRS="$RS_CTRS $RS_CTR"
  rs_pm run -d --name "$RS_CTR" --network "container:$RS_HOLDER" "$@" "$RS_IMG"
  assert_rc 0 "$RS_RC" "product container created: $RS_OUT"
}

# rs_wait_ready: until Unbound answers the built-in localhost zone on 5335.
rs_wait_ready() {
  local i=0
  while [ "$i" -lt 60 ]; do
    rs_ns dig @127.0.0.1 -p 5335 +time=1 +tries=1 localhost A
    case "$RS_OUT" in *'status: NOERROR'*) assert_match '127\.0\.0\.1' "$RS_OUT" "unbound answers localhost"; return 0 ;; esac
    if [ "$(podman inspect -f '{{.State.Running}}' "$RS_CTR" 2>/dev/null)" != true ]; then
      rs_pm logs "$RS_CTR"
      fail "unbound container is not running: $RS_OUT"
    fi
    i=$((i + 1))
    sleep 0.5
  done
  rs_pm logs "$RS_CTR"
  fail "unbound never answered on 127.0.0.1:5335: $RS_OUT"
}

# rs_running_product [podman run args...]: holder + product + readiness.
rs_running_product() {
  rs_holder
  rs_unbound "$@"
  rs_wait_ready
}

# rs_exec <user> <cmd...>: podman exec in the running product container.
rs_exec() {
  local u="$1"
  shift
  rs_pm exec --user "$u" --workdir / "$RS_CTR" "$@"
}

# rs_expect_refused <label> <reason regex> [podman run args...]: the product
# container must exit non-zero by itself with a FATAL message naming the
# reason, and nothing may answer on 5335 (Unbound never ran). Unbound logs to
# syslog, which the container lacks, so its absence is proven by the listener.
rs_expect_refused() {
  local label="$1" reason="$2" name
  shift 2
  name="$RS_PFX-bad-$(printf '%s' "$label" | tr -c 'a-z0-9' '-')"
  RS_CTRS="$RS_CTRS $name"
  RS_OUT="$(timeout 30 podman run --name "$name" --network "container:$RS_HOLDER" "$@" "$RS_IMG" 2>&1)"
  RS_RC=$?
  RS_OUT="$(printf '%s\n' "$RS_OUT" | grep -v -- "$RS_WARN")"
  assert_ne 124 "$RS_RC" "$label: the container must exit by itself, not run on"
  assert_nonzero "$RS_RC" "$label: the container must exit non-zero ($RS_OUT)"
  assert_match "nice-dns-unbound-start: FATAL: .*$reason" "$RS_OUT" "$label: a clear FATAL message naming the reason"
  rs_ns dig @127.0.0.1 -p 5335 +time=1 +tries=1 localhost A
  assert_not_match 'status: ' "$RS_OUT" "$label: nothing answers on 5335"
  rs_ns ss -Hlntu
  assert_not_match ':5335([^0-9]|$)' "$RS_OUT" "$label: no resolver listener"
  podman rm -f -t 0 "$name" >/dev/null 2>&1
}

# shellcheck disable=SC2016
rs_image_scan() {
  rs_pm unshare sh -c '
    m=$(podman image mount "$1" 2>/dev/null) || { echo "MOUNT-FAILED"; exit 3; }
    find "$m" -xdev \( -name "unbound_server.*" -o -name "unbound_control.*" \) -print | sed "s|^$m|name:|"
    # A PEM private key block in any file, binary included (-a). The bare
    # words "PRIVATE KEY" also occur in libcrypto; the full marker does not.
    # grep exit 2 is an error, never "clean": it is printed, so the case fails.
    grep -rlaE -e "-----BEGIN [A-Z ]*PRIVATE KEY-----" "$m" >"$2" 2>&1; rc=$?
    sed "s|^$m|content:|" "$2"
    [ "$rc" -le 1 ] || echo "SCAN-FAILED grep exit $rc"
    podman image umount "$1" >/dev/null 2>&1
    exit 0' sh "$1" "$CASE_DIR/scan-$(printf '%s' "$1" | tr -c 'a-z0-9' '-')"
}

# rs_keytags <file>: "<tag> <sha256 DS digest>" per root DNSKEY 257 line,
# computed on the host (RFC 4034 appendix B key tag, RFC 4509 digest).
rs_keytags() {
  python3 - "$1" <<'PY'
import base64, hashlib, struct, sys
for line in open(sys.argv[1]):
    line = line.split(";", 1)[0].split()
    if len(line) < 7 or line[0] != "." or "DNSKEY" not in line:
        continue
    i = line.index("DNSKEY")
    flags, proto, alg = int(line[i + 1]), int(line[i + 2]), int(line[i + 3])
    rdata = struct.pack("!HBB", flags, proto, alg) + base64.b64decode("".join(line[i + 4:]))
    acc = sum(b if n & 1 else b << 8 for n, b in enumerate(rdata))
    tag = (acc + (acc >> 16)) & 0xFFFF
    print(tag, flags, alg, hashlib.sha256(b"\x00" + rdata).hexdigest().upper())
PY
}

# ─────────────────────────── fixture in the test namespace ───────────────────

# rs_fx_start: dnsfixture.py on the host, inside the holder's network namespace.
rs_fx_start() {
  local d="$CASE_DIR/fx" i=0
  mkdir -m 700 "$d" || fail "cannot create $d"
  podman unshare nsenter -t "$RS_NSPID" -n sh -c 'echo $$ >"$1/pypid"; exec python3 "$2" serve --state "$1" --max-seconds "$3"' \
    sh "$d" "$FX_PY" "${FX_MAX_SECONDS:-600}" >"$d/fixture.log" 2>&1 </dev/null &
  RS_FX_WRAP=$!
  while [ ! -f "$d/ports.tsv" ]; do
    i=$((i + 1))
    [ "$i" -le 300 ] || fail "fixture did not start: $(cat "$d/fixture.log")"
    sleep 0.05
  done
  RS_FX_PID="$(cat "$d/pypid")"
  RS_FX_PORT="$(fx_port "$d" dns)"
  assert_match '^[1-9][0-9]*$' "$RS_FX_PORT" "fixture port inside the test namespace"
}

# rs_overlay: TEST-ONLY config = the product config copied out of the image,
# plus the fixture's trust anchor and stub zones for fixture.test. The root
# forward-zone is left exactly as shipped; nothing can leave the namespace.
rs_overlay() {
  local f="$CASE_DIR/overlay.conf"
  rs_pm run --rm --network none --entrypoint /bin/cat "$RS_IMG" /etc/unbound/unbound.conf
  assert_rc 0 "$RS_RC" "product config readable from the image"
  printf '%s\n' "$RS_OUT" >"$CASE_DIR/product.conf"
  {
    cat "$CASE_DIR/product.conf"
    printf '\n# ---- TEST-ONLY overlay (tests/integration/resolver-state.sh) ----\n'
    printf 'server:\n    local-zone: "test." nodefault\n    '
    cat "$CASE_DIR/fx/anchor.unbound"
    printf 'stub-zone:\n    name: "fixture.test."\n    stub-addr: 127.0.0.1@%s\n' "$RS_FX_PORT"
    printf 'stub-zone:\n    name: "unsigned.fixture.test."\n    stub-addr: 127.0.0.1@%s\n' "$RS_FX_PORT"
  } >"$f"
  chmod 644 "$f"
  RS_OVERLAY="$f"
}

# rs_fixture_resolver: namespace + fixture + product image on the overlay.
rs_fixture_resolver() {
  rs_holder
  rs_fx_start
  rs_overlay
  rs_unbound -v "$RS_OVERLAY:/etc/unbound/unbound.conf:ro"
  rs_wait_ready
}

rs_dig() {
  rs_ns dig @127.0.0.1 -p 5335 +time=20 +tries=1 "$@"
}

# ─────────────────────────── cases: config and control ───────────────────────

t_effective_config_uses_persistent_anchor_and_socket() {
  rs_setup
  rs_running_product
  rs_exec unbound unbound-checkconf
  assert_rc 0 "$RS_RC" "unbound-checkconf in the running image: $RS_OUT"
  assert_match 'no errors' "$RS_OUT" "checkconf reports no errors"
  rs_exec unbound unbound-checkconf -o auto-trust-anchor-file
  assert_eq "$RS_ANCHOR" "$RS_OUT" "effective auto-trust-anchor-file is the persistent path"
  rs_exec unbound unbound-checkconf -o module-config
  assert_match '(^| )validator( |$)' "$RS_OUT" "validator module enabled"
  rs_exec unbound unbound-checkconf -o control-enable
  assert_eq yes "$RS_OUT" "control enabled"
  rs_exec unbound unbound-checkconf -o control-interface
  assert_eq "$RS_SOCK" "$RS_OUT" "the only control interface is the Unix socket"
  # checkconf cannot print control-use-cert; read the config the image runs.
  rs_exec unbound grep -E '^[[:space:]]*control-use-cert:[[:space:]]*no[[:space:]]*$' /etc/unbound/unbound.conf
  assert_rc 0 "$RS_RC" "control-use-cert: no (no key/certificate files for control)"
  rs_exec unbound grep -E '^[[:space:]]*(server|control)-(key|cert)-file:|^[[:space:]]*control-port:' /etc/unbound/unbound.conf
  assert_eq "" "$RS_OUT" "no control key/cert files or control port configured"
}

t_no_network_control_listener() {
  rs_setup
  rs_running_product
  rs_ns ss -Hlntu
  assert_match '127\.0\.0\.1:5335' "$RS_OUT" "resolver listener present (positive control)"
  assert_not_match ':8953([^0-9]|$)' "$RS_OUT" "no TCP/UDP listener on 8953"
  rs_ns ss -Hlx
  assert_match "$RS_SOCK" "$RS_OUT" "control socket is listening"
}

t_control_socket_mode_and_owner() {
  rs_setup
  rs_running_product
  rs_exec unbound stat -c '%A %U %G' "$RS_SOCK"
  assert_rc 0 "$RS_RC" "socket exists: $RS_OUT"
  assert_match '^s[rw-]{6}--- unbound unbound$' "$RS_OUT" "socket owned by unbound, no access for others"
  rs_exec unbound stat -c '%A %U %G' "$(dirname "$RS_SOCK")"
  assert_match '^d[rwx-]{6}--- unbound unbound$' "$RS_OUT" "socket directory owned by unbound, closed to others"
}

t_control_authorized_as_unbound_user() {
  rs_setup
  rs_running_product
  rs_exec unbound unbound-control status
  assert_rc 0 "$RS_RC" "unbound-control as the unbound user: $RS_OUT"
  assert_match 'is running' "$RS_OUT" "status reports running"
  rs_exec unbound unbound-control -s "$RS_SOCK" stats_noreset
  assert_rc 0 "$RS_RC" "explicit socket path works: $RS_OUT"
  assert_match '^total\.num\.queries=' "$RS_OUT" "stats readable"
}

t_control_denied_to_other_uids() {
  local u
  rs_setup
  rs_running_product
  for u in app nobody 1000:1000 65534:65534; do
    rs_exec "$u" unbound-control -s "$RS_SOCK" status
    assert_nonzero "$RS_RC" "uid $u must not control unbound through the socket: $RS_OUT"
    assert_match 'Permission denied' "$RS_OUT" "uid $u is refused by permissions"
    assert_not_match 'is running' "$RS_OUT" "uid $u got no status"
    # Whatever the effective config names as the control interface.
    rs_exec "$u" unbound-control status
    assert_nonzero "$RS_RC" "uid $u must not control unbound through the configured interface: $RS_OUT"
    assert_not_match 'is running' "$RS_OUT" "uid $u got no status via the configured interface"
  done
}

t_images_carry_no_private_keys() {
  local img
  rs_setup
  for img in "$RS_BASE_IMG" "$RS_IMG"; do
    rs_image_scan "$img"
    assert_rc 0 "$RS_RC" "image $img filesystem scanned: $RS_OUT"
    assert_not_match 'MOUNT-FAILED' "$RS_OUT" "image $img mounted"
    assert_eq "" "$RS_OUT" "image $img has no control key/cert files and no private key material"
  done
}

t_base_image_self_test_passes() {
  rs_setup
  [ -f "$RS_BASE_SRC/tests/image-test.sh" ] || fail "hardened-unbound has no tests/image-test.sh"
  CONTAINER_ENGINE=podman sh "$RS_BASE_SRC/tests/image-test.sh" "$RS_BASE_IMG" >"$CASE_DIR/image-test.log" 2>&1
  RS_RC=$?
  RS_OUT="$(grep -v -- "$RS_WARN" "$CASE_DIR/image-test.log")"
  assert_rc 0 "$RS_RC" "base image self-test exit status"
  assert_match 'image-test: PASS' "$RS_OUT" "base image self-test passes: $RS_OUT"
  assert_not_match 'FAIL' "$RS_OUT" "no base self-test failures"
}

# ─────────────────────────── cases: anchor state ─────────────────────────────

t_seed_anchor_carries_root_ksks() {
  local tags line tag digest
  rs_setup
  rs_pm run --rm --network none --entrypoint /bin/cat "$RS_IMG" "$RS_SEED"
  assert_rc 0 "$RS_RC" "seed anchor present in the image: $RS_OUT"
  printf '%s\n' "$RS_OUT" >"$CASE_DIR/seed"
  rs_pm run --rm --network none --entrypoint /bin/stat "$RS_IMG" -c '%a %U %G' "$RS_SEED"
  assert_eq '444 root root' "$RS_OUT" "seed is root-owned and read-only"
  rs_pm run --rm --network none --entrypoint /usr/sbin/unbound-anchor "$RS_IMG" -l
  printf '%s\n' "$RS_OUT" | grep -E '^\. IN DS ' >"$CASE_DIR/builtin-ds"
  tags="$(rs_keytags "$CASE_DIR/seed")"
  assert_match '^20326 257 8 ' "$tags" "seed carries KSK-2017 (tag computed on the host)"
  assert_match '^38696 257 8 ' "$tags" "seed carries KSK-2024 (tag computed on the host)"
  while read -r tag _ _ digest; do
    line="$(grep -E "^\\. IN DS $tag 8 2 " "$CASE_DIR/builtin-ds")"
    assert_eq ". IN DS $tag 8 2 $digest" "$line" "seed key $tag matches unbound-anchor's builtin DS"
  done <<EOF
$tags
EOF
}

# rs_build_seed <label> <src file> [env...]: run build-seed on a copy of the
# packaged keys; RS_OUT/RS_RC, and the seed it wrote in $CASE_DIR/seed-<label>.
rs_build_seed() {
  local label="$1" f="$2" out
  shift 2
  out="$CASE_DIR/out-$label"
  mkdir -p "$out" && chmod 777 "$out"
  rs_pm run --rm --network none --user 0 -v "$(dirname "$f"):/src:ro" -v "$out:/out" "$@" \
    --entrypoint "$RS_START" "$RS_IMG" build-seed "/src/$(basename "$f")" /out/seed
  if [ -f "$out/seed" ]; then cp "$out/seed" "$CASE_DIR/seed-$label"; else : >"$CASE_DIR/seed-$label"; fi
}

t_seed_builder_rejects_unverified_keys() {
  local src="$CASE_DIR/src" v
  rs_setup
  rs_pm run --rm --network none --entrypoint /bin/cat "$RS_IMG" /usr/share/dnssec-root/trusted-key.key
  assert_rc 0 "$RS_RC" "packaged root keys readable"
  mkdir -p "$src"
  printf '%s\n' "$RS_OUT" >"$src/good"
  sed 's/AwEAAaz\//AwEAAaz+/' "$src/good" >"$src/tampered-2017"  # alter one KSK-2017 byte
  printf 'garbage\n' >"$src/garbage"
  : >"$src/empty"
  chmod 644 "$src"/*
  rs_build_seed good "$src/good"
  assert_rc 0 "$RS_RC" "unmodified packaged keys build a seed (positive control): $RS_OUT"
  for v in tampered-2017 garbage empty; do
    assert_ne "$(cat "$src/good")" "$(cat "$src/$v")" "variant $v differs from the packaged keys"
    rs_build_seed "$v" "$src/$v"
    assert_nonzero "$RS_RC" "seed build must fail for $v: $RS_OUT"
    assert_match 'FATAL' "$RS_OUT" "$v refusal is explicit"
    assert_eq "" "$(cat "$CASE_DIR/seed-$v")" "$v wrote no seed"
  done
  # The required-tag list has a floor: an override cannot empty it.
  for v in "" " " "20326 x"; do
    rs_build_seed "tags" "$src/good" -e "REQUIRED_ROOT_KSK_TAGS=$v"
    assert_nonzero "$RS_RC" "seed build must fail for REQUIRED_ROOT_KSK_TAGS='$v': $RS_OUT"
    assert_match 'FATAL: REQUIRED_ROOT_KSK_TAGS' "$RS_OUT" "tag-list refusal is explicit ('$v')"
  done
  # A required tag that neither package nor builtin knows is refused.
  rs_build_seed unknown "$src/good" -e "REQUIRED_ROOT_KSK_TAGS=20326 12345"
  assert_nonzero "$RS_RC" "an unknown required tag must fail: $RS_OUT"
  assert_match 'FATAL: root KSK 12345 is neither' "$RS_OUT" "unknown-tag refusal is explicit"
}

t_seed_falls_back_to_builtin_ds() {
  # An older dnssec-root package carries only KSK-2017 (the published
  # sureserver/hardened-unbound:latest does). KSK-2024 then comes from
  # unbound-anchor's builtin DS line, verbatim.
  local src="$CASE_DIR/src" ds
  rs_setup
  rs_pm run --rm --network none --entrypoint /bin/cat "$RS_IMG" /usr/share/dnssec-root/trusted-key.key
  mkdir -p "$src"
  printf '%s\n' "$RS_OUT" >"$src/good"
  grep -v 'AwEAAa96' "$src/good" >"$src/missing-2024"
  assert_ne "$(cat "$src/good")" "$(cat "$src/missing-2024")" "the KSK-2024 DNSKEY line was removed"
  chmod 644 "$src"/*
  rs_build_seed missing-2024 "$src/missing-2024"
  assert_rc 0 "$RS_RC" "a package without KSK-2024 still builds a seed: $RS_OUT"
  assert_match '^20326 257 8 ' "$(rs_keytags "$CASE_DIR/seed-missing-2024")" "KSK-2017 kept as a verified DNSKEY"
  assert_not_match '^38696 ' "$(rs_keytags "$CASE_DIR/seed-missing-2024")" "no KSK-2024 DNSKEY was invented"
  rs_pm run --rm --network none --entrypoint /usr/sbin/unbound-anchor "$RS_IMG" -l
  ds="$(printf '%s\n' "$RS_OUT" | grep -E '^\. IN DS 38696 8 2 [0-9A-F]{64}$')"
  assert_ne "" "$ds" "unbound-anchor has a builtin DS for 38696"
  assert_match "^$(printf '%s' "$ds" | sed 's/\./\\./g') ; key tag 38696 \(builtin DS\)$" \
    "$(cat "$CASE_DIR/seed-missing-2024")" "KSK-2024 seeded as exactly the builtin DS line"
}

t_product_builds_on_published_base() {
  # The Containerfile's default BASE_IMAGE is the published base; installers
  # build with that default. It must still build and seed both KSKs.
  local pub=docker.io/sureserver/hardened-unbound:latest img
  rs_setup
  if ! podman image exists "$pub" 2>/dev/null; then
    podman pull -q "$pub" >"$CASE_DIR/pull.log" 2>&1 || fail "cannot pull $pub: $(tail -n 5 "$CASE_DIR/pull.log")"
  fi
  img="$RS_IMG-pubbase"
  podman build -t "$img" "$RS_PRODUCT_SRC" >"$CASE_DIR/build-pubbase.log" 2>&1
  RS_RC=$?
  assert_rc 0 "$RS_RC" "product builds FROM the default (published) base: $(tail -n 15 "$CASE_DIR/build-pubbase.log")"
  rs_pm run --rm --network none --entrypoint /bin/cat "$img" "$RS_SEED"
  podman rmi -f "$img" >/dev/null 2>&1
  printf '%s\n' "$RS_OUT" >"$CASE_DIR/seed-pubbase"
  assert_match '^20326 257 8 ' "$(rs_keytags "$CASE_DIR/seed-pubbase")" "seed on the published base carries KSK-2017"
  assert_match '(^|[[:space:]])38696([[:space:]]|$)' "$(sed 's/;.*//' "$CASE_DIR/seed-pubbase" | awk '$3 == "DS" || $3 == "DNSKEY" { print $4 }'; rs_keytags "$CASE_DIR/seed-pubbase" | cut -d' ' -f1)" \
    "seed on the published base carries KSK-2024 (DNSKEY or builtin DS)"
}

t_base_and_product_anchor_agree() {
  # The seed logic exists twice (base Dockerfile, product build-seed); on the
  # same base they must produce the same key set.
  rs_setup
  rs_pm run --rm --network none --entrypoint /bin/cat "$RS_BASE_IMG" /etc/unbound/root.key
  assert_rc 0 "$RS_RC" "base anchor readable: $RS_OUT"
  printf '%s\n' "$RS_OUT" | sed 's/[[:space:]]*;.*//' | grep . | LC_ALL=C sort >"$CASE_DIR/base-keys"
  rs_pm run --rm --network none --entrypoint /bin/cat "$RS_IMG" "$RS_SEED"
  printf '%s\n' "$RS_OUT" | sed 's/[[:space:]]*;.*//' | grep . | LC_ALL=C sort >"$CASE_DIR/product-keys"
  assert_ne "" "$(cat "$CASE_DIR/base-keys")" "base anchor has keys"
  assert_eq "$(cat "$CASE_DIR/base-keys")" "$(cat "$CASE_DIR/product-keys")" "base root.key and product seed carry the same records"
}

t_fresh_state_dir_is_seeded_and_persisted() {
  local st seed
  rs_setup
  rs_state_dir state; st="$RS_DIR"
  rs_running_product -v "$st:/var/lib/unbound"
  rs_pm unshare cat "$st/root.key"
  assert_rc 0 "$RS_RC" "anchor persisted in the mounted dir: $RS_OUT"
  printf '%s\n' "$RS_OUT" >"$CASE_DIR/persisted"
  seed="$(rs_keytags "$CASE_DIR/persisted")"
  assert_match '^20326 257 8 ' "$seed" "persisted anchor has the root KSK"
  rs_pm unshare stat -c '%u %a' "$st/root.key"
  assert_match '^100 6[0-4][0-4]$' "$RS_OUT" "persisted anchor owned by unbound, writable only by it"
  rs_pm logs "$RS_CTR"
  assert_match 'seeded' "$RS_OUT" "start logs that it seeded the anchor"
}

t_existing_valid_anchor_is_kept() {
  # An existing usable anchor holding only KSK-2017 must not be replaced by
  # the two-key seed (Unbound may rewrite the file, but offline it cannot
  # learn KSK-2024, so its presence would mean the seed overwrote state).
  local st tags
  rs_setup
  rs_state_dir state; st="$RS_DIR"
  rs_pm run --rm --network none --entrypoint /bin/cat "$RS_IMG" "$RS_SEED"
  printf '%s\n' "$RS_OUT" >"$CASE_DIR/seed"
  tags="$(rs_keytags "$CASE_DIR/seed")"
  assert_match '^38696 ' "$tags" "the seed carries KSK-2024 (so its absence below is meaningful)"
  rs_put "$st/root.key" "$(grep -v 'AwEAAa96' "$CASE_DIR/seed")
"
  rs_running_product -v "$st:/var/lib/unbound"
  rs_pm unshare cat "$st/root.key"
  printf '%s\n' "$RS_OUT" >"$CASE_DIR/kept"
  tags="$(rs_keytags "$CASE_DIR/kept")"
  assert_match '^20326 257 8 ' "$tags" "the operator's anchor is still there"
  assert_not_match '38696' "$tags" "the seed did not overwrite existing usable state"
}

t_unusable_anchor_file_refused() {
  local st v
  rs_setup
  rs_holder
  for v in empty garbage no-root-key revoked-only; do
    rs_state_dir "state-$v"; st="$RS_DIR"
    case "$v" in
      empty) rs_put "$st/root.key" "" ;;
      garbage) rs_put "$st/root.key" "this is not a trust anchor
" ;;
      no-root-key) rs_put "$st/root.key" "example. IN DS 12345 8 2 0000000000000000000000000000000000000000000000000000000000000000
" ;;
      revoked-only) rs_put "$st/root.key" ".	86400	IN	DNSKEY	385 3 8 AwEAAQ== ;{id = 1 (ksk), size = 8b} ;;state=4 [ REVOKED ] ;;count=0
" ;;
    esac
    rs_expect_refused "anchor-$v" "anchor $RS_ANCHOR is unusable" -v "$st:/var/lib/unbound"
  done
}

t_unwritable_anchor_dir_refused() {
  local st
  rs_setup
  rs_holder
  rs_state_dir state-rootowned 0:0 755; st="$RS_DIR"
  rs_expect_refused "dir-not-owned" "anchor directory /var/lib/unbound is not owned" -v "$st:/var/lib/unbound"
  rs_state_dir state-readonly; st="$RS_DIR"
  rs_expect_refused "dir-read-only-mount" "anchor directory /var/lib/unbound is not writable" -v "$st:/var/lib/unbound:ro"
}

t_read_only_anchor_file_refused() {
  # The directory is a writable volume but the anchor file itself is a
  # read-only mount: RFC 5011 updates could never be written.
  local st
  rs_setup
  rs_holder
  rs_state_dir state; st="$RS_DIR"
  rs_pm run --rm --network none --entrypoint /bin/cat "$RS_IMG" "$RS_SEED"
  rs_put "$CASE_DIR/ro-anchor" "$RS_OUT
" 100:100
  RS_OWNED="$RS_OWNED $CASE_DIR/ro-anchor"
  rs_put "$st/root.key" "$RS_OUT
"
  rs_expect_refused "file-read-only-mount" "anchor $RS_ANCHOR is not writable" \
    -v "$st:/var/lib/unbound" -v "$CASE_DIR/ro-anchor:$RS_ANCHOR:ro"
}

t_symlinked_anchor_state_refused() {
  local lib st
  rs_setup
  rs_holder
  rs_state_dir varlib 0:0 755; lib="$RS_DIR"
  podman unshare sh -c 'ln -s /tmp "$1/unbound"' sh "$lib" >/dev/null 2>&1
  rs_expect_refused "dir-symlink" "anchor directory /var/lib/unbound is a symlink" -v "$lib:/var/lib"
  rs_state_dir state-filelink; st="$RS_DIR"
  podman unshare sh -c 'ln -s /usr/share/nice-dns/root-anchor.seed "$1/root.key" && chown -h 100:100 "$1/root.key"' sh "$st" >/dev/null 2>&1
  rs_expect_refused "file-symlink" "anchor $RS_ANCHOR is a symlink" -v "$st:/var/lib/unbound"
}

t_unusable_runtime_dir_refused() {
  # A runtime that mounts a fresh root-owned /run leaves no /run/unbound and
  # no way for the unbound user to create it: the control socket cannot exist.
  rs_setup
  rs_holder
  # notmpcopyup: podman would otherwise copy the image's /run into the tmpfs.
  rs_expect_refused "fresh-run-tmpfs" "control socket directory /run/unbound is missing" --tmpfs /run:rw,mode=0755,notmpcopyup
}

# ─────────────────────────── cases: DNSSEC through the product image ─────────

t_signed_answer_validates_with_ad() {
  rs_setup
  rs_fixture_resolver
  rs_dig +adflag signed.fixture.test A
  assert_match 'status: NOERROR' "$RS_OUT" "signed name resolves"
  assert_match 'flags: qr rd ra ad;' "$RS_OUT" "AD set: validated by the product Unbound"
  assert_match 'signed\.fixture\.test\..*IN[[:space:]]+A[[:space:]]+192\.0\.2\.1' "$RS_OUT" "signed A record"
}

t_unsigned_answer_is_insecure_not_bogus() {
  rs_setup
  rs_fixture_resolver
  rs_dig +adflag host.unsigned.fixture.test A
  assert_match 'status: NOERROR' "$RS_OUT" "unsigned name still answers (insecure, not SERVFAIL)"
  assert_match 'flags: qr rd ra;' "$RS_OUT" "no AD for an insecure answer"
  assert_match 'host\.unsigned\.fixture\.test\..*IN[[:space:]]+A[[:space:]]+192\.0\.2\.7' "$RS_OUT" "unsigned A record"
}

t_bogus_answer_rejected_locally() {
  rs_setup
  rs_fixture_resolver
  rs_dig +adflag bogus.fixture.test A
  assert_match 'status: SERVFAIL' "$RS_OUT" "bogus answer rejected"
  assert_not_match '192\.0\.2\.66' "$RS_OUT" "bogus address never served"
  rs_dig +cd bogus.fixture.test A
  assert_match 'status: NOERROR' "$RS_OUT" "with +cd the data is retrievable"
  assert_match 'bogus\.fixture\.test\..*IN[[:space:]]+A[[:space:]]+192\.0\.2\.66' "$RS_OUT" \
    "the fixture delivered the record, so the SERVFAIL was local validation"
}
