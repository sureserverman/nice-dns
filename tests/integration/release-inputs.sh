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

# Either proxy may be chosen at install, so each `requires proxy` interface
# must be provided by both proxy rows; a lock pinned to a proxy release
# without one is refused at install. bridges-mode/1 (TOR_BRIDGES on|off,
# Sub-plan 2) is required so the bridges toggle never meets an older image.
t_every_required_proxy_interface_is_provided() {
  local i p
  assert_ne "" "$(awk -F '\t' '$1 == "requires" && $2 == "proxy" && $3 == "bridges-mode/1"' "$RI_LOCK")" "this tree requires bridges-mode/1"
  for i in $(awk -F '\t' '$1 == "requires" && $2 == "proxy" { print $3 }' "$RI_LOCK"); do
    for p in proxy-haproxy proxy-socat; do
      assert_ne "" "$(awk -F '\t' -v p="$p" -v i="$i" '$1 == "provides" && $2 == p && $3 == i' "$RI_LOCK")" "$p provides $i"
    done
  done
}

# A public resolver written into the product bypasses the host's resolver,
# and a VPN that confines DNS (Mullvad custom DNS) refuses it (BL-047,
# measured 2026-10-11). So each one is declared in release/bootstrap.tsv: a
# line matches a `literal` row (the same path, the row's anchored ERE), or,
# for a comment line, names a declared row ("literal <id>") and mentions only
# the resolvers that row's lines carry. Every hit counts, comment or not, and
# a row no line matches is stale. The scan covers every file the product
# ships (all but .git, .claude, tests, docs, proof and Markdown) for the
# well-known public resolvers, IPv4 and IPv6 (RI_PUBLIC_RESOLVERS); it is of
# the checkout under test ($NICE_DNS_ROOT: run a copy's tests/run.sh to scan
# the copy). A resolver outside that list, or one built at run time, is not
# seen.
RI_PUBLIC_V4='1\.1\.1\.1|1\.0\.0\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.(9|10|11)|149\.112\.112\.(112|10|11)|208\.67\.22[02]\.22[02]|94\.140\.1[45]\.1[45]|4\.2\.2\.[1-6]|8\.26\.56\.26|8\.20\.247\.20|84\.200\.(69\.80|70\.40)|64\.6\.6[45]\.6|185\.228\.16[89]\.9|76\.76\.(2|10)\.0'
RI_PUBLIC_RESOLVERS="(^|[^0-9.])($RI_PUBLIC_V4)([^0-9.]|\$)|2606:4700:4700:|2001:4860:4860:|2620:fe::|2620:119:(35|53)::|2a10:50c0::|2001:1608:10:25:"

t_every_public_resolver_literal_is_declared() {
  local root="$NICE_DNS_ROOT" hits bad
  assert_eq "$(printf 'schema\tnice-dns-bootstrap/1')" "$(head -n 1 "$root/release/bootstrap.tsv")" "the inventory's schema"
  hits="$(cd "$root" && find . \( -path ./.git -o -path ./.claude -o -path ./tests -o -path ./docs -o -path ./proof \) -prune \
    -o -type f ! -name '*.md' -print | sed 's|^\./||' | sort | xargs grep -nIE -- "$RI_PUBLIC_RESOLVERS")"
  assert_ne "" "$hits" "the scan finds the declared literals"
  bad="$(printf '%s\n' "$hits" | RI_PUB="^($RI_PUBLIC_V4)\$" awk -F '\t' '
    BEGIN { pub = ENVIRON["RI_PUB"] }
    function ips(s, set,   n, t, i, k) {
      n = split(s, t, /[^0-9.]+/); k = 0
      for (i = 1; i <= n; i++) {
        sub(/\.+$/, "", t[i]); sub(/^\.+/, "", t[i])
        if (t[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && t[i] ~ pub) { set[t[i]] = 1; k++ }
      }
      return k
    }
    FNR == NR {
      if ($1 != "literal") next
      if (NF != 8 || $2 !~ /^[a-z0-9-]+$/ || $3 !~ /^(linux|macos|all)$/ || $4 == "" ||
          $5 !~ /^\^/ || $5 !~ /\$$/ || $6 !~ /^(preparation|interruption|runtime)$/ ||
          $7 !~ /^(host|own|builder|none)$/ || $8 == "") {
        print "bootstrap.tsv:" FNR ": a malformed literal row"; next
      }
      n++; rid[n] = $2; rpath[n] = $4; rere[n] = $5; known[$2] = 1
      next
    }
    {
      line = $0
      p = line; sub(/:.*/, "", p); rest = substr(line, length(p) + 2)
      ln = rest; sub(/:.*/, "", ln); text = substr(rest, length(ln) + 2)
      ok = 0
      for (i = 1; i <= n; i++) if (rpath[i] == p && text ~ rere[i]) {
        ok = 1; used[i] = 1
        split("", s); ips(text, s); for (a in s) carries[rid[i] SUBSEP a] = 1
      }
      if (ok) next
      if (text ~ /^[ \t]*#/) { nc++; cwhere[nc] = p ":" ln; ctext[nc] = text; next }
      print p ":" ln ": undeclared: " text
    }
    END {
      for (c = 1; c <= nc; c++) {
        named = 0; split("", s); ips(ctext[c], s)
        for (id in known) {
          t = ctext[c]
          if (!match(t, "literal " id "([^a-z0-9-]|$)")) continue
          named = 1
          for (a in s) if (!((id SUBSEP a) in carries)) print cwhere[c] ": comment mentions " a ", which literal " id " does not carry: " ctext[c]
        }
        if (!named) print cwhere[c] ": undeclared (a comment naming no literal row): " ctext[c]
      }
      for (i = 1; i <= n; i++) if (!(i in used)) print "bootstrap.tsv: literal " rid[i] " (" rpath[i] ") matches no line: stale"
    }' "$root/release/bootstrap.tsv" -)"
  assert_eq "" "$bad" "every public resolver literal is declared in release/bootstrap.tsv"
  assert_match '^literal	' "$(cat "$root/release/bootstrap.tsv")" "the literals are declared as rows"
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
      sed -i '/^image\tproxy-haproxy\t/ s/sha256:[0-9a-f][0-9a-f]/sha256:ZZ/' "$IP_TREE/release/images.lock"
      assert_match 'sha256:ZZ' "$(cat "$IP_TREE/release/images.lock")" "$ep: the lock really carries the malformed digest"
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
  local w="$CASE_DIR/refresh" b out rc st
  b="$w/bin"; mkdir -p "$b" "$w/fake"
  export FAKE="$w/fake" FAKE_LOG="$w/fake/calls.log"
  : >"$FAKE_LOG"
  cp "$RI_LOCK" "$w/images.lock"
  st="$(awk -F '\t' '$1 == "image" && $2 == "proxy-socat" { print $4 }' "$RI_LOCK")"
  cat >"$b/curl" <<'STUB'
#!/bin/sh
printf 'curl %s\n' "$*" >>"$FAKE_LOG"
case "$*" in
  *auth.docker.io*) echo '{"token":"t"}' ;;
  *registry-1.docker.io/v2/sureserver/tor-socat/manifests/*) printf 'HTTP/2 200\r\ndocker-content-digest: sha256:%064d\r\n\r\n' 7 ;;
  *registry-1.docker.io/v2/*/manifests/*)
    r="$(printf '%s' "$*" | sed -E 's|.*/v2/(.+)/manifests/.*|\1|')"
    d="$(awk -F '\t' -v r="docker.io/$r" '$1 == "image" && $3 == r { print $5 }' "$LOCK")"
    printf 'HTTP/2 200\r\ndocker-content-digest: %s\r\n\r\n' "$d" ;;
esac
STUB
  cat >"$b/podman" <<'STUB'
#!/bin/sh
printf 'podman %s\n' "$*" >>"$FAKE_LOG"
[ -f "$FAKE/podman_fail" ] && { echo 'Error: cannot set up namespace' >&2; exit 125; }
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
  assert_match "$(printf 'image\tproxy-socat\tdocker.io/sureserver/tor-socat\t%s\tsha256:' "$st")0{63}7" "$(cat "$w/images.lock")" "--write records the new digest"
  assert_eq "$(grep -v 'proxy-socat' "$RI_LOCK")" "$(grep -v 'proxy-socat' "$w/images.lock")" "and nothing else"
  : >"$FAKE/cosign_fail"
  cp "$RI_LOCK" "$w/images.lock"
  out="$(LOCK="$w/images.lock" PATH="$b:$PATH" bash "$NICE_DNS_ROOT/scripts/update-images-lock.sh" --lock "$w/images.lock" --write 2>&1)"; rc=$?
  assert_nonzero "$rc" "a failed signature refuses --write: $out"
  assert_eq "$(cat "$RI_LOCK")" "$(cat "$w/images.lock")" "and leaves the lock as it was"
  # Why: podman fails from a shell without a usable user namespace; the
  # script must say the listing failed, not that every build is missing.
  rm -f "$FAKE/cosign_fail"
  : >"$FAKE/podman_fail"
  cp "$RI_LOCK" "$w/images.lock"
  out="$(LOCK="$w/images.lock" PATH="$b:$PATH" bash "$NICE_DNS_ROOT/scripts/update-images-lock.sh" --lock "$w/images.lock" --write 2>&1)"; rc=$?
  assert_nonzero "$rc" "a failed platform listing refuses --write: $out"
  assert_match 'cannot list the platforms of docker.io/sureserver/tor-haproxy' "$out" "it says the listing failed"
  assert_eq "" "$(printf '%s\n' "$out" | grep -E 'Traceback|has no linux/')" "and does not report missing builds"
  assert_eq "$(cat "$RI_LOCK")" "$(cat "$w/images.lock")" "and leaves the lock as it was"
}

# The release assets lock (Sub-plan 5 Task 2.4): its grammar, under gawk and
# under mawk 1.3.4 (the awk of mint and Ubuntu 24.04), when that is here.
t_assets_lock_grammar_is_enforced() {
  local a ok_lock="$CASE_DIR/ok.lock" bad n sha url gurl out awks=awk
  command -v mawk >/dev/null 2>&1 && awks="awk mawk"
  sha="$(printf 'nice-dns-helper' | sha256sum | cut -d' ' -f1)"
  url=https://github.com/sureserverman/nice-dns/releases/download/v1.0.0/nice-dns-helper-linux-amd64
  gurl=https://github.com/sureserverman/nice-dns/releases/download/v1.0.0/nice-dns-gui-linux-amd64.tar.gz
  # A helper and a GUI (Sub-plan 6 Task 2.1) for the same host are two assets.
  printf 'schema\tnice-dns-assets-lock/1\n# a comment\nrelease\tv1.0.0\nasset\thelper\tlinux\tamd64\t%s\t%s\nasset\tgui\tlinux\tamd64\t%s\t%s\n' "$url" "$sha" "$gurl" "$sha" >"$ok_lock"
  for a in $awks; do
    mkdir -p "$CASE_DIR/bin-$a"; ln -sf "$(command -v "$a")" "$CASE_DIR/bin-$a/awk"
    for f in "$NICE_DNS_ROOT/release/assets.lock" "$ok_lock"; do
      out="$(PATH="$CASE_DIR/bin-$a:$PATH" bash -c '. "$1/lib/install.sh" && _nd_inst_assets_check "$2"' x "$NICE_DNS_ROOT" "$f" 2>&1)"
      assert_rc 0 "$?" "$a: $(basename "$f") is well formed: $out"
    done
    n=0
    while IFS= read -r bad; do
      n=$((n + 1))
      printf '%b' "$bad" >"$CASE_DIR/bad$n.lock"
      out="$(PATH="$CASE_DIR/bin-$a:$PATH" bash -c '. "$1/lib/install.sh" && _nd_inst_assets_check "$2"' x "$NICE_DNS_ROOT" "$CASE_DIR/bad$n.lock" 2>&1)"
      assert_rc 1 "$?" "$a: malformed lock $n is refused: $bad"
      assert_match 'release/assets.lock|assets-lock|malformed' "$out" "$a: lock $n: says why"
    done <<LOCKS
schema\tnice-dns-images-lock/1\nrelease\tnone\n
schema\tnice-dns-assets-lock/1\n
schema\tnice-dns-assets-lock/1\nrelease\tnone\nrelease\tv1.0.0\n
schema\tnice-dns-assets-lock/1\nrelease\t1.0\n
schema\tnice-dns-assets-lock/1\nrelease\tv1.0.0\nasset\thelper\tlinux\tamd64\t$url\t${sha%?}\n
schema\tnice-dns-assets-lock/1\nrelease\tv1.0.0\nasset\thelper\tlinux\tamd64\t$url\t$(printf '%s' "$sha" | tr a-f A-F)\n
schema\tnice-dns-assets-lock/1\nrelease\tv1.0.0\nasset\thelper\tlinux\tamd64\thttps://example.com/nice-dns-helper\t$sha\n
schema\tnice-dns-assets-lock/1\nrelease\tv1.0.0\nasset\thelper\tlinux\tamd64\thttps://github.com/sureserverman/nice-dns/releases/download/v1.0.0/../x\t$sha\n
schema\tnice-dns-assets-lock/1\nrelease\tv1.0.0\nasset\thelper\twindows\tamd64\t$url\t$sha\n
schema\tnice-dns-assets-lock/1\nrelease\tv1.0.0\nasset\tother\tlinux\tamd64\t$url\t$sha\n
schema\tnice-dns-assets-lock/1\nrelease\tv1.0.0\nasset\thelper\tlinux\tamd64\t$url\t$sha\nasset\thelper\tlinux\tamd64\t$url\t$sha\n
schema\tnice-dns-assets-lock/1\nrelease\tv1.0.0\nimage\tx\n
schema\tnice-dns-assets-lock/1\nrelease\tv1.0.0\nasset\tgui\tlinux\tamd64\t$gurl\t$sha\nasset\tgui\tlinux\tamd64\t$gurl\t$sha\n
LOCKS
    assert_eq 13 "$n" "$a: every malformed lock was tried"
  done
  # An install from a tree with a malformed assets lock is refused before it
  # changes anything.
  ri_env install-deb
  printf 'schema\tnice-dns-assets-lock/1\nrelease\tlatest\n' >"$IP_TREE/release/assets.lock"
  ip_install install-deb
  ri_refused install-deb "a malformed assets lock"
}

t_assets_refresh_script_checks_and_writes() {
  local w="$CASE_DIR/assets" b out rc n
  b="$w/bin"; mkdir -p "$b" "$w/rel/v1.0.0"
  for n in linux-amd64 linux-arm64 macos-arm64; do
    printf 'helper %s\n' "$n" >"$w/rel/v1.0.0/nice-dns-helper-$n"
    (cd "$w/rel/v1.0.0" && sha256sum "nice-dns-helper-$n" >"nice-dns-helper-$n.sha256")
  done
  # The Linux GUI's tarballs (Sub-plan 6 Task 2.1).
  for n in linux-amd64 linux-arm64; do
    printf 'gui %s\n' "$n" >"$w/rel/v1.0.0/nice-dns-gui-$n.tar.gz"
    (cd "$w/rel/v1.0.0" && sha256sum "nice-dns-gui-$n.tar.gz" >"nice-dns-gui-$n.tar.gz.sha256")
  done
  # The macOS app's zip (Sub-plan 7 Task 2.1).
  printf 'gui macos\n' >"$w/rel/v1.0.0/nice-dns-gui-macos-arm64.zip"
  (cd "$w/rel/v1.0.0" && sha256sum nice-dns-gui-macos-arm64.zip >nice-dns-gui-macos-arm64.zip.sha256)
  # The release as GitHub serves it: the latest tag, and each download.
  cat >"$b/curl" <<STUB
#!/bin/sh
o="" u=""
while [ \$# -gt 0 ]; do case "\$1" in -o) o="\$2"; shift ;; https://*) u="\$1" ;; esac; shift; done
case "\$u" in
  https://api.github.com/repos/sureserverman/nice-dns/releases/latest) printf '{\n  "tag_name": "v1.0.0",\n  "name": "v1.0.0"\n}\n' ;;
  https://github.com/sureserverman/nice-dns/releases/download/*) f="$w/rel/\${u#https://github.com/sureserverman/nice-dns/releases/download/}"; [ -f "\$f" ] || exit 22; cp "\$f" "\$o" ;;
  *) exit 22 ;;
esac
STUB
  chmod 755 "$b/curl"
  cp "$NICE_DNS_ROOT/release/assets.lock" "$w/assets.lock"
  out="$(PATH="$b:$PATH" bash "$NICE_DNS_ROOT/scripts/update-assets-lock.sh" --lock "$w/assets.lock" 2>&1)"; rc=$?
  assert_rc 1 "$rc" "a lock behind the release is drift: $out"
  assert_eq "$(cat "$NICE_DNS_ROOT/release/assets.lock")" "$(cat "$w/assets.lock")" "without --write the lock is untouched"
  out="$(PATH="$b:$PATH" bash "$NICE_DNS_ROOT/scripts/update-assets-lock.sh" --lock "$w/assets.lock" --write 2>&1)"; rc=$?
  assert_rc 0 "$rc" "--write: $out"
  assert_eq 6 "$(grep -c '^asset' "$w/assets.lock")" "--write records the six assets"
  assert_match "$(printf 'asset\tgui\tmacos\tarm64\thttps://github.com/sureserverman/nice-dns/releases/download/v1.0.0/nice-dns-gui-macos-arm64.zip\t')$(cut -d' ' -f1 "$w/rel/v1.0.0/nice-dns-gui-macos-arm64.zip.sha256")$" "$(cat "$w/assets.lock")" "and the macOS app's row"
  assert_match "$(printf 'asset\tgui\tlinux\tamd64\thttps://github.com/sureserverman/nice-dns/releases/download/v1.0.0/nice-dns-gui-linux-amd64.tar.gz\t')$(cut -d' ' -f1 "$w/rel/v1.0.0/nice-dns-gui-linux-amd64.tar.gz.sha256")$" "$(cat "$w/assets.lock")" "and the GUI's rows"
  assert_match "$(printf '^release\tv1\\.0\\.0$')" "$(cat "$w/assets.lock")" "and the release"
  assert_match "$(printf 'asset\thelper\tmacos\tarm64\thttps://github.com/sureserverman/nice-dns/releases/download/v1.0.0/nice-dns-helper-macos-arm64\t')$(cut -d' ' -f1 "$w/rel/v1.0.0/nice-dns-helper-macos-arm64.sha256")$" "$(cat "$w/assets.lock")" "each row is the asset's url and sha256"
  assert_eq "$(grep '^#' "$NICE_DNS_ROOT/release/assets.lock")" "$(grep '^#' "$w/assets.lock")" "the comments are kept"
  out="$(PATH="$b:$PATH" bash -c '. "$1/lib/install.sh" && _nd_inst_assets_check "$2"' x "$NICE_DNS_ROOT" "$w/assets.lock" 2>&1)"
  assert_rc 0 "$?" "the written lock is one an install reads: $out"
  out="$(PATH="$b:$PATH" bash "$NICE_DNS_ROOT/scripts/update-assets-lock.sh" --lock "$w/assets.lock" 2>&1)"; rc=$?
  assert_rc 0 "$rc" "then the lock matches: $out"
  # A binary whose bytes are not its .sha256's: an error, nothing written.
  printf 'tampered\n' >"$w/rel/v1.0.0/nice-dns-helper-linux-arm64"
  cp "$w/assets.lock" "$w/before.lock"
  out="$(PATH="$b:$PATH" bash "$NICE_DNS_ROOT/scripts/update-assets-lock.sh" --lock "$w/assets.lock" --write 2>&1)"; rc=$?
  assert_rc 2 "$rc" "a tampered asset is an error: $out"
  assert_match "nice-dns-helper-linux-arm64's bytes do not match its .sha256" "$out" "it names the asset"
  assert_eq "$(cat "$w/before.lock")" "$(cat "$w/assets.lock")" "nothing is written"
}
