# shellcheck shell=bash
# Group integration/release-inputs (Sub-plan 4, Task 1.3; ARCH-05, ARCH-08).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). The
# reviewed image inputs live in release/images.lock; the four entrypoints run
# in the installer fixture (tests/fixtures/install-fakes.sh) and must pull and
# build only the locked digests, refuse an unsupported platform, an image
# lacking an interface this tree requires, or a failed signature check, all
# before anything is interrupted, and record the provenance in the generation
# manifest. scripts/update-images-lock.sh runs against stub registry, podman
# and cosign commands. Nothing touches the host or the network.
#
# NICE_DNS_OPT_ENTRYPOINTS (--entrypoints ...) picks the entrypoints.

. "$NICE_DNS_ROOT/tests/fixtures/install-fakes.sh"

RI_LOCK="$NICE_DNS_ROOT/release/images.lock"

ri_row() { awk -F '\t' -v k="$1" -v r="$2" '$1 == k && $2 == r' "$3"; }
ri_field() { ri_row image "$1" "$2" | cut -f "$3"; }   # <role> <lock> <column>
ri_pinned() { printf '%s@%s\n' "$(ri_field "$1" "$2" 3)" "$(ri_field "$1" "$2" 5)"; }

t_lock_is_well_formed() {
  local role sup p missing
  assert_eq "$(printf 'schema\tnice-dns-images-lock/1')" "$(head -n 1 "$RI_LOCK")" "schema line"
  sup="$(awk -F '\t' '$1 == "supported" { print $2 }' "$RI_LOCK")"
  for p in linux/amd64 linux/arm64 linux/arm/v7 linux/riscv64; do
    assert_match "(^|,)$p(,|$)" "$sup" "the documented CPU support keeps $p"
  done
  for role in proxy-haproxy proxy-socat unbound-base pihole-base; do
    assert_match '^sha256:[0-9a-f]{64}$' "$(ri_field "$role" "$RI_LOCK" 5)" "$role: an index digest"
    missing=""
    for p in $(printf '%s' "$sup" | tr ',' ' '); do
      printf '%s' ",$(ri_field "$role" "$RI_LOCK" 6)," | grep -qF ",$p," || missing="$missing $p"
    done
    assert_eq "" "$missing" "$role: provides every supported platform"
    assert_ne "" "$(ri_field "$role" "$RI_LOCK" 7)" "$role: a source"
  done
  for role in proxy-haproxy proxy-socat unbound-base; do
    assert_match '^https://github\.com/sureserverman/[a-z-]+/\.github/workflows/main\.yml@refs/tags/v$' "$(ri_field "$role" "$RI_LOCK" 9)" "$role: a named signer"
    assert_match '^github\.com/sureserverman/[a-z-]+@[0-9a-f]{40}$' "$(ri_field "$role" "$RI_LOCK" 7)" "$role: source commit"
  done
  assert_eq none "$(ri_field pihole-base "$RI_LOCK" 9)" "pihole-base: upstream, no signer nice-dns can name"
  assert_ne "" "$(ri_row unpublished hardened-base "$RI_LOCK")" "the hardened base is declared unpublished"
  assert_eq "" "$(awk -F '\t' '/^#/ { next } $1 !~ /^(schema|supported|issuer|image|unpublished|provides|requires)$/ && NF' "$RI_LOCK")" "no unknown row kinds"
}

# ri_env <entrypoint>: the installer fixture with a hardened sibling.
ri_env() {
  ip_env "$1"
  mkdir -p "$IP_W/src/pi-hole-hardened"
  printf 'FROM alpine:3.21.3\n' >"$IP_W/src/pi-hole-hardened/Dockerfile"; : >"$IP_W/src/pi-hole-hardened/post-install.sh"
}

t_installers_use_the_locked_digests() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local lock m proxy ub
      ri_env "$ep"
      lock="$IP_TREE/release/images.lock"
      ip_install "$ep" socat
      assert_rc 0 "$IP_RC" "$ep: $IP_OUT"
      proxy="$(ri_pinned proxy-socat "$lock")"; ub="$(ri_pinned unbound-base "$lock")"
      assert_match "^(podman pull|container image pull) $proxy\$" "$(cat "$FAKE_LOG")" "$ep: the proxy is pulled by its locked digest"
      assert_eq "" "$(grep -E '^(podman pull|container image pull) [^@ ]+$' "$FAKE_LOG" | grep -v 'alpine:3\.21\.3$')" "$ep: nothing is pulled by a floating tag (the sibling's own FROM aside)"
      if [ "$(ip_platform "$ep")" = linux ]; then
        assert_match "^podman build .*--build-arg BASE_IMAGE=$ub .*-t localhost/unbound:" "$(cat "$FAKE_LOG")" "$ep: unbound builds on the locked base"
        [ "$(ip_flavor "$ep")" = standard ] && assert_match "^podman build .*--build-arg BASE_IMAGE=$(ri_pinned pihole-base "$lock") .*-t localhost/pi-hole:" "$(cat "$FAKE_LOG")" "$ep: pi-hole builds on the locked base"
      else
        assert_match "^container image pull $ub\$" "$(cat "$FAKE_LOG")" "$ep: the unbound base is pulled by digest"
        assert_match '^container build .*--build-arg BASE_IMAGE=unbound-base:[^ ]+ .*-t unbound:' "$(cat "$FAKE_LOG")" "$ep: and built on under a plain local name"
        [ "$(ip_flavor "$ep")" = standard ] && assert_match '^container build .*--build-arg BASE_IMAGE=pihole-base:[^ ]+ .*-t pi-hole:' "$(cat "$FAKE_LOG")" "$ep: pi-hole too"
      fi
      m="$(ip_manifest "$(ip_gen_current)")"
      assert_match "$(printf 'locked\tproxy-socat\t')$proxy" "$(cat "$m")" "$ep: the manifest names the locked proxy"
      assert_match "$(printf 'lock\tsha256:')[0-9a-f]{64}" "$(cat "$m")" "$ep: and the lock it came from"
      assert_match "$(printf 'blocklist\tadlists\tsha256:')[0-9a-f]{64}" "$(cat "$m")" "$ep: the blocklist sources are recorded"
      [ "$(ip_flavor "$ep")" = hardened ] && assert_match "$(printf 'source\thardened-base\t')" "$(cat "$m")" "$ep: the sibling's commit is recorded"
      [ "$(ip_flavor "$ep")" = hardened ] && assert_match "$(printf 'image\tsibling-base\talpine:3\.21\.3\t')[0-9a-f]+" "$(cat "$m")" "$ep: and the local id of the base it names"
      true
    ) || exit 1
  done
}

# ri_refused <entrypoint> <what>: the install failed in preparation.
ri_refused() {
  assert_nonzero "$IP_RC" "$1: $2 refuses the install: $IP_OUT"
  ip_assert_untouched "$1 ($2)"
  assert_no_path "$IP_STATE/current" "$1 ($2): nothing is current"
}

t_unsupported_platform_is_refused() {
  local ep
  ip_select
  assert_ne "" "$IP_EPS" "an entrypoint is selected (the case applies to some of them only)"
  for ep in $IP_EPS; do
    [ "$(ip_platform "$ep")" = linux ] || continue   # macOS: check-runtime gates arm64
    (
      ri_env "$ep"
      IP_ARCH=s390x
      ip_install "$ep"
      ri_refused "$ep" "an s390x host"
      assert_match 'linux/s390x' "$IP_OUT" "$ep: it names the platform"
    ) || exit 1
  done
}

t_missing_interface_is_refused() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      ri_env "$ep"
      awk -F '\t' '!($1 == "provides" && $2 == "proxy-haproxy" && $3 == "route-probe/1")' "$IP_TREE/release/images.lock" >"$IP_W/lock" \
        && cat "$IP_W/lock" >"$IP_TREE/release/images.lock"
      ip_install "$ep"
      ri_refused "$ep" "a proxy without route-probe/1"
      assert_match 'route-probe/1' "$IP_OUT" "$ep: it names the interface"
    ) || exit 1
  done
}

t_malformed_lock_is_refused() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      ri_env "$ep"
      sed -i 's/sha256:973e5082/sha256:ZZ3e5082/' "$IP_TREE/release/images.lock"
      ip_install "$ep"
      ri_refused "$ep" "a malformed digest"
    ) || exit 1
  done
}

t_signatures_are_verified_when_cosign_is_present() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local lock m first ver
      ri_env "$ep"
      lock="$IP_TREE/release/images.lock"
      ln -s fakecmd "$IP_BIN/cosign"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: $IP_OUT"
      ver="$(grep '^cosign verify ' "$FAKE_LOG")"
      assert_match "--certificate-identity-regexp \\^https://github\\\\.com/sureserverman/tor-haproxy/\\\\.github/workflows/main\\\\.yml@refs/tags/v --certificate-oidc-issuer https://token\\.actions\\.githubusercontent\\.com $(ri_pinned proxy-haproxy "$lock")\$" "$ver" "$ep: the proxy's signer is checked on its digest"
      assert_match "$(ri_pinned unbound-base "$lock")\$" "$ver" "$ep: and the unbound base's"
      assert_not_match 'pihole/pihole' "$ver" "$ep: no check is invented for an unsigned upstream"
      first="$(ip_first "$FAKE_LOG" "$IP_DISRUPTIVE")"
      assert_eq 1 "$(( $(ip_last "$FAKE_LOG" '^cosign verify ') < first ))" "$ep: before any interruption"
      m="$(ip_manifest "$(ip_gen_current)")"
      assert_match "$(printf 'signature\tproxy-haproxy\tverified')" "$(cat "$m")" "$ep: recorded verified"
      if [ "$(ip_flavor "$ep")" = standard ]; then
        assert_match "$(printf 'signature\tpihole-base\tunsigned')" "$(cat "$m")" "$ep: an unsigned input is recorded unsigned"
      fi
    ) || exit 1
    (
      ri_env "$ep"
      ln -s fakecmd "$IP_BIN/cosign"; : >"$FAKE/cosign_fail"
      ip_install "$ep"
      ri_refused "$ep" "a failed signature check"
    ) || exit 1
    (
      ri_env "$ep"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep without cosign: $IP_OUT"
      assert_match 'not verified' "$IP_OUT" "$ep: says the signatures were not verified"
      assert_match "$(printf 'signature\tproxy-haproxy\tunverified-no-cosign')" "$(cat "$(ip_manifest "$(ip_gen_current)")")" "$ep: and records it"
    ) || exit 1
    (
      ri_env "$ep"
      ND_INST_REQUIRE_SIGNATURES=1 ip_install "$ep"
      ri_refused "$ep" "ND_INST_REQUIRE_SIGNATURES=1 without cosign"
    ) || exit 1
  done
}

t_hardened_needs_its_sibling() {
  local ep
  ip_select
  # Why: the lock declares the hardened base unpublished (nothing to pull).
  assert_match '^unpublished'"$(printf '\t')"'hardened-base' "$(cat "$RI_LOCK")" "the lock declares the hardened base unpublished"
  for ep in $IP_EPS; do
    [ "$(ip_flavor "$ep")" = hardened ] || continue
    (
      IP_NO_SIBLING=1 ip_env "$ep"
      ip_install "$ep"
      ri_refused "$ep" "a hardened install without the sibling checkout"
      assert_match 'pi-hole-hardened' "$IP_OUT" "$ep: it says what is missing"
      assert_eq "" "$(grep -E 'pull .*pi-hole-hardened' "$FAKE_LOG")" "$ep: no unpublished image is pulled"
    ) || exit 1
  done
}

# The refresh script: registry digests and platforms, signatures, and a
# lock rewritten only with --write.
t_refresh_script_checks_and_writes() {
  local w="$CASE_DIR/refresh" b out rc
  b="$w/bin"; mkdir -p "$b" "$w/fake"
  export FAKE="$w/fake" FAKE_LOG="$w/fake/calls.log"
  : >"$FAKE_LOG"
  cp "$RI_LOCK" "$w/images.lock"
  cat >"$b/curl" <<'STUB'
#!/bin/sh
printf 'curl %s\n' "$*" >>"$FAKE_LOG"
case "$*" in
  *auth.docker.io*) echo '{"token":"t"}' ;;
  *registry-1.docker.io/v2/sureserver/tor-socat/manifests/v2.10*) printf 'HTTP/2 200\r\ndocker-content-digest: sha256:%064d\r\n\r\n' 7 ;;
  *registry-1.docker.io/v2/*/manifests/*)
    r="$(printf '%s' "$*" | sed -E 's|.*/v2/(.+)/manifests/.*|\1|')"
    d="$(awk -F '\t' -v r="docker.io/$r" '$1 == "image" && $3 == r { print $5 }' "$LOCK")"
    printf 'HTTP/2 200\r\ndocker-content-digest: %s\r\n\r\n' "$d" ;;
esac
STUB
  cat >"$b/podman" <<'STUB'
#!/bin/sh
printf 'podman %s\n' "$*" >>"$FAKE_LOG"
echo '{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}},{"platform":{"os":"linux","architecture":"arm","variant":"v7"}},{"platform":{"os":"linux","architecture":"riscv64"}},{"platform":{"os":"unknown","architecture":"unknown"}}]}'
STUB
  cat >"$b/cosign" <<'STUB'
#!/bin/sh
printf 'cosign %s\n' "$*" >>"$FAKE_LOG"
[ -f "$FAKE/cosign_fail" ] && exit 1
exit 0
STUB
  chmod 755 "$b"/*
  out="$(LOCK="$w/images.lock" PATH="$b:$PATH" bash "$NICE_DNS_ROOT/scripts/update-images-lock.sh" --lock "$w/images.lock" 2>&1)"; rc=$?
  assert_rc 1 "$rc" "a registry digest that moved is reported as drift: $out"
  assert_match 'proxy-socat.*sha256:0{63}7' "$out" "it names the new digest"
  assert_eq "$(cat "$RI_LOCK")" "$(cat "$w/images.lock")" "without --write the lock is untouched"
  assert_match 'cosign verify .*tor-socat@sha256:0{63}7$' "$(cat "$FAKE_LOG")" "the moved image's signature is checked on the new digest"
  out="$(LOCK="$w/images.lock" PATH="$b:$PATH" bash "$NICE_DNS_ROOT/scripts/update-images-lock.sh" --lock "$w/images.lock" --write 2>&1)"; rc=$?
  assert_rc 0 "$rc" "--write: $out"
  assert_match "$(printf 'image\tproxy-socat\tdocker.io/sureserver/tor-socat\tv2.10\tsha256:')0{63}7" "$(cat "$w/images.lock")" "--write records the new digest"
  assert_eq "$(grep -v 'proxy-socat' "$RI_LOCK")" "$(grep -v 'proxy-socat' "$w/images.lock")" "and nothing else"
  : >"$FAKE/cosign_fail"
  cp "$RI_LOCK" "$w/images.lock"
  out="$(LOCK="$w/images.lock" PATH="$b:$PATH" bash "$NICE_DNS_ROOT/scripts/update-images-lock.sh" --lock "$w/images.lock" --write 2>&1)"; rc=$?
  assert_nonzero "$rc" "a failed signature refuses --write: $out"
  assert_eq "$(cat "$RI_LOCK")" "$(cat "$w/images.lock")" "and leaves the lock as it was"
}
