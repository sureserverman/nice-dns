# shellcheck shell=bash
# Group integration/install-prepare (Sub-plan 4, Task 1.1; ARCH-01, ARCH-03,
# ARCH-08; WF-DNS-003).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). Each
# public installer entrypoint runs against a private HOME, a copy of the
# checkout and PATH stubs for every external command it calls. The stubs log
# their argv to a calls log and never touch the host: sudo runs nothing,
# podman/container keep a fake image store, git clone copies a fixture tree.
# The copy's deb/persistent-podman.sh and mac/persist.sh are logging stubs:
# this group tests the installers' preparation and its order, not the
# persistence scripts. t_bash32_pure_functions runs lib/install.sh's data
# functions under docker.io/library/bash:3.2 (--rm, no network): the only
# use of the real container runtime.
#
# NICE_DNS_OPT_ENTRYPOINTS (--entrypoints all | comma list of install-deb,
# install-deb-hardened, install-mac, install-mac-hardened) picks the
# entrypoints.

. "$NICE_DNS_ROOT/tests/fixtures/install-fakes.sh"

# ───────────────────────────────── cases ─────────────────────────────────

t_entrypoints_option_is_validated() {
  local out rc
  out="$( (NICE_DNS_OPT_ENTRYPOINTS=install-deb,bogus; ip_entrypoints) 2>&1)"; rc=$?
  assert_nonzero "$rc" "an unknown --entrypoints value fails: $out"
  assert_match "unknown --entrypoints value 'bogus'" "$out" "it names the value"
  assert_eq "$IP_ALL" "$(NICE_DNS_OPT_ENTRYPOINTS=all ip_entrypoints)" "all selects the four entrypoints"
}

t_argument_surface_is_unchanged() {
  local ep m
  ip_select
  for ep in $IP_EPS; do
    (
      ip_env "$ep"
      # Root is refused before anything else; $EUID cannot be faked, so the
      # check is read from the source: it precedes the library and any call.
      # shellcheck disable=SC2016  # the literal source line
      assert_match '^if \[\[ \$EUID -eq 0 \]\]; then$' "$(grep -n 'EUID' "$IP_TREE/$ep.sh" | head -1 | cut -d: -f2-)" "$ep: refuses root"
      assert_eq 1 "$(awk '/EUID -eq 0/ { a = NR } /^\. ".*\/lib\/install\.sh"$/ && !b { b = NR } END { print (a && b && a < b) ? 1 : 0 }' "$IP_TREE/$ep.sh")" "$ep: the root check precedes loading the library"
      assert_match '^ +exit 1$' "$(grep -A3 'EUID -eq 0' "$IP_TREE/$ep.sh" | grep 'exit')" "$ep: root exits 1"
      ip_install "$ep" bogus
      assert_rc 1 "$IP_RC" "$ep: an unknown first argument exits 1"
      assert_match "^Unknown arg 'bogus'\. Use 'haproxy', 'socat', or 'uninstall'\.$" "$IP_OUT" "$ep: the existing message"
      assert_eq "" "$(cat "$FAKE_LOG")" "$ep: and calls nothing"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: default install: $IP_OUT"
      m="$(ip_manifest "$(ip_gen_current)")"
      assert_eq haproxy "$(ip_row "$m" variant)" "$ep: defaults to haproxy"
      assert_eq main "$(ip_row "$m" branch)" "$ep: defaults to main"
      assert_match '^(podman pull|container image pull) docker\.io/sureserver/tor-haproxy:latest$' "$(cat "$FAKE_LOG")" "$ep: pulls the haproxy proxy"
      : >"$FAKE_LOG"
      printf 'fedcba9876543210fedcba9876543210fedcba98\n' >"$FAKE/git_head"
      ip_install "$ep" socat dev
      assert_rc 0 "$IP_RC" "$ep: socat dev: $IP_OUT"
      m="$(ip_manifest "$(ip_gen_current)")"
      assert_eq socat "$(ip_row "$m" variant)" "$ep: socat is recorded"
      assert_eq dev "$(ip_row "$m" branch)" "$ep: the branch is recorded"
      assert_match '^(podman pull|container image pull) docker\.io/sureserver/tor-socat:latest$' "$(cat "$FAKE_LOG")" "$ep: pulls the socat proxy"
      assert_not_match 'tor-haproxy:latest$' "$(grep -E "$IP_BUILD_PULL" "$FAKE_LOG")" "$ep: and not the other one"
    ) || exit 1
  done
}

t_builds_and_pulls_precede_the_interruption() {
  local ep sib
  ip_select
  for ep in $IP_EPS; do
    for sib in no yes; do
      [ "$sib" = yes ] && [ "$(ip_flavor "$ep")" = standard ] && continue
      (
        local first last_bp stop n
        ip_env "$ep"
        if [ "$sib" = yes ]; then mkdir -p "$IP_W/src/pi-hole-hardened"; printf 'FROM alpine:3.21.3\n' >"$IP_W/src/pi-hole-hardened/Dockerfile"; : >"$IP_W/src/pi-hole-hardened/post-install.sh"; fi
        ip_install "$ep"
        assert_rc 0 "$IP_RC" "$ep (sibling=$sib): $IP_OUT"
        first="$(ip_first "$FAKE_LOG" "$IP_DISRUPTIVE")"
        assert_ne "" "$first" "$ep: the install does interrupt the stack (teardown), after preparation"
        n="$(ip_lines "$FAKE_LOG" "$IP_BUILD_PULL" | grep -c .)"
        assert_ne 0 "$n" "$ep: images are built or pulled"
        if [ "$(ip_platform "$ep")" = linux ]; then
          last_bp="$(ip_last "$FAKE_LOG" "$IP_BUILD_PULL")"
          assert_eq 1 "$((last_bp < first))" "$ep (sibling=$sib): every build/pull (last at line $last_bp) precedes the first disruptive call (line $first):
$(cat -n "$FAKE_LOG")"
          assert_match '^podman build .*-t localhost/unbound:' "$(cat "$FAKE_LOG")" "$ep: unbound is built"
          assert_match '^podman build .*-t localhost/pi-hole:' "$(cat "$FAKE_LOG")" "$ep: pi-hole is built"
          if [ "$sib" = yes ]; then
            assert_match '^podman build .*pi-hole-hardened-base:' "$(sed -n "1,${first}p" "$FAKE_LOG")" "$ep: the sibling hardened base is built before the interruption"
          fi
        else
          last_bp="$(ip_last "$FAKE_LOG" '^container image pull ')"
          assert_eq 1 "$((last_bp < first))" "$ep: every pull precedes the first disruptive call:
$(cat -n "$FAKE_LOG")"
          # The macOS exception: `container build` wedges a running dnsnet, so
          # local builds run only once the stack's containers are stopped.
          stop="$(ip_last "$FAKE_LOG" '^container stop (pi-hole|unbound|tor-haproxy|tor-socat)$')"
          assert_ne "" "$stop" "$ep: the stack's containers are stopped"
          assert_eq "" "$(ip_lines "$FAKE_LOG" '^container build ' | awk -F: -v s="$stop" '$1 < s')" "$ep (sibling=$sib): no local build before the stack is stopped (line $stop):
$(cat -n "$FAKE_LOG")"
          assert_match '^container build .*-t unbound:' "$(cat "$FAKE_LOG")" "$ep: unbound is built"
          assert_match '^container build .*-t pi-hole:' "$(cat "$FAKE_LOG")" "$ep: pi-hole is built"
          assert_eq 1 "$(( $(ip_first "$FAKE_LOG" '^container build ') > $(ip_last "$FAKE_LOG" '^container image pull ') ))" "$ep: pulls happen in preparation, builds after"
        fi
        assert_eq "" "$(sed -n "1,${first}p" "$FAKE_LOG" | grep -E '^podman system migrate|^brew upgrade( --formula)? container')" "$ep: podman system migrate / brew upgrade container stay out of preparation"
      ) || exit 1
    done
  done
}

# ip_injections <entrypoint>: one preparation failure per line.
ip_injections() {
  if [ "$(ip_platform "$1")" = linux ]; then
    printf '%s\n' 'podman build .*unbound' 'podman build .*pi-hole' 'podman pull docker\.io/sureserver/tor-' 'git clone' 'sudo apt-get install'
    [ "$(ip_flavor "$1")" = hardened ] && printf '%s\n' 'podman pull docker\.io/sureserver/pi-hole-hardened'
  else
    printf '%s\n' 'container image pull docker\.io/sureserver/tor-' 'git clone' 'bridges' 'brew install'
    [ "$(ip_flavor "$1")" = hardened ] && printf '%s\n' 'container image pull docker\.io/sureserver/pi-hole-hardened'
  fi
  return 0
}

t_failed_preparation_touches_nothing() {
  local ep pat
  ip_select
  for ep in $IP_EPS; do
    while IFS= read -r pat; do
      (
        local script
        ip_env "$ep"
        script="$IP_TREE/$ep.sh"
        case "$pat" in
          'git clone')
            # The `bash <(curl …)` path: the entrypoint alone, no checkout.
            mkdir -p "$IP_W/solo" && cp "$IP_TREE/$ep.sh" "$IP_W/solo/" && script="$IP_W/solo/$ep.sh"
            printf '^git clone\n' >"$FAKE/fail" ;;
          bridges) rm -f "$IP_HOME/.config/nice-dns/bridges.env" ;;   # and Moat (curl) fails
          'brew install') sed -i '/^container$/d' "$FAKE/brew_installed"; printf '^brew install\n' >"$FAKE/fail" ;;
          *) printf '^%s\n' "$pat" >"$FAKE/fail" ;;
        esac
        ip_run "$script"
        assert_nonzero "$IP_RC" "$ep: a failed '$pat' fails the install: $IP_OUT"
        ip_assert_untouched "$ep ($pat)"
        assert_no_path "$IP_STATE/current" "$ep ($pat): nothing is marked current"
      ) || exit 1
    done <<EOF
$(ip_injections "$ep")
EOF
  done
}

t_prepare_manifest_is_owned_and_complete() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local g m role
      ip_env "$ep"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: $IP_OUT"
      g="$(ip_gen_current)"
      assert_match '^[0-9]{8}T[0-9]{6}Z-0123456789ab$' "$g" "$ep: the generation id is sortable and names the source commit"
      m="$(ip_manifest "$g")"
      assert_file "$m" "$ep: prepare.tsv"
      assert_eq 600 "$(ip_mode "$m")" "$ep: prepare.tsv is 0600"
      assert_eq 700 "$(ip_mode "$IP_STATE")" "$ep: the state dir is 0700"
      assert_eq 700 "$(ip_mode "$IP_STATE/generations/$g")" "$ep: the generation dir is 0700"
      assert_eq 700 "$(ip_mode "$IP_HOME/.config/nice-dns")" "$ep: ~/.config/nice-dns exists, 0700"
      assert_eq "$(printf 'schema\tnice-dns-install-prepare/1')" "$(head -n 1 "$m")" "$ep: first line is the schema"
      assert_eq "$g" "$(ip_row "$m" generation)" "$ep: generation"
      assert_match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$(ip_row "$m" created)" "$ep: created (UTC ISO-8601)"
      assert_eq "$(ip_platform "$ep")" "$(ip_row "$m" platform)" "$ep: platform"
      assert_eq "$ep.sh" "$(ip_row "$m" entrypoint)" "$ep: entrypoint"
      assert_eq "$(ip_flavor "$ep")" "$(ip_row "$m" pihole)" "$ep: pihole"
      assert_eq checkout "$(ip_row "$m" source_origin)" "$ep: source_origin"
      assert_eq 0123456789abcdef0123456789abcdef01234567 "$(ip_row "$m" source_commit)" "$ep: source_commit"
      assert_eq 0 "$(ip_row "$m" source_dirty)" "$ep: source_dirty"
      assert_eq none "$(ip_row "$m" previous)" "$ep: a first install has no previous generation"
      assert_eq "$(printf 'none')" "$(ip_row "$m" rollback)" "$ep: and no rollback"
      for role in unbound pi-hole proxy; do
        assert_match "^image	$role	[^	]+	[0-9a-f]{12,}$" "$(grep "^image	$role	" "$m")" "$ep: an image row for $role with its local id"
      done
      if [ "$(ip_flavor "$ep")" = hardened ]; then
        assert_match "^image	hardened-base	[^	]+	[0-9a-f]{12,}$" "$(grep "^image	hardened-base	" "$m")" "$ep: an image row for the hardened base"
      else
        assert_eq "" "$(grep "^image	hardened-base	" "$m")" "$ep: no hardened base on standard"
      fi
      assert_file "$IP_STATE/generations/$g/activated" "$ep: the generation is marked activated"
      # A dirty tree and a tree without git are recorded as such.
      printf ' M unbound/etc/unbound.conf\n' >"$FAKE/git_status"
      printf '1111111111112222222222223333333333334444\n' >"$FAKE/git_head"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep dirty: $IP_OUT"
      assert_eq 1 "$(ip_row "$(ip_manifest "$(ip_gen_current)")" source_dirty)" "$ep: a dirty tree is recorded"
      rm -f "$FAKE/git_head" "$FAKE/git_status"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep nogit: $IP_OUT"
      assert_match '^[0-9]{8}T[0-9]{6}Z-nogit0000000$' "$(ip_gen_current)" "$ep: no git: nogit generation"
      assert_eq unknown "$(ip_row "$(ip_manifest "$(ip_gen_current)")" source_commit)" "$ep: no git: commit unknown"
    ) || exit 1
    (
      ip_env "$ep"
      mkdir -p "$IP_W/elsewhere" "$(dirname "$IP_STATE")"
      ln -s "$IP_W/elsewhere" "$IP_STATE"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep: a symlinked state dir is refused: $IP_OUT"
      assert_match 'symlink' "$IP_OUT" "$ep: it says why"
      ip_assert_untouched "$ep (symlinked state dir)"
      assert_eq "" "$(ls -A "$IP_W/elsewhere")" "$ep: nothing is written through the link"
    ) || exit 1
    (
      ip_env "$ep"
      mkdir -p "$IP_STATE" "$IP_W/elsewhere"
      ln -s "$IP_W/elsewhere" "$IP_STATE/generations"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep: a symlinked generations dir is refused: $IP_OUT"
      ip_assert_untouched "$ep (symlinked generations dir)"
    ) || exit 1
    (
      # current is data: a malformed one is refused, never executed.
      ip_env "$ep"
      mkdir -p "$IP_STATE" && chmod 700 "$IP_STATE"
      # shellcheck disable=SC2016  # a hostile literal, never expanded
      printf '$(touch %s/pwned)\n' "$IP_W" >"$IP_STATE/current"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep: a malformed current file is refused: $IP_OUT"
      assert_no_path "$IP_W/pwned" "$ep: its contents never run"
      ip_assert_untouched "$ep (malformed current)"
    ) || exit 1
  done
}

t_standard_and_hardened_share_build_flags() {
  local ep plat want flags
  ip_select
  for ep in $IP_EPS; do
    (
      plat="$(ip_platform "$ep")"
      ip_env "$ep"
      mkdir -p "$IP_W/src/pi-hole-hardened"; printf 'FROM alpine:3.21.3\n' >"$IP_W/src/pi-hole-hardened/Dockerfile"; : >"$IP_W/src/pi-hole-hardened/post-install.sh"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: $IP_OUT"
      # macOS builds take no --pull: they run while host DNS is pinned to the
      # stopped stack, and their bases were pulled in preparation (Task 1.2).
      if [ "$plat" = linux ]; then want='--pull=newer --no-cache --dns 1.1.1.1'; else want='--no-cache --dns 1.1.1.1'; fi
      # Each build's policy flags, with the recipe selectors (-t, -f,
      # --build-arg) and the context removed.
      flags="$(grep -E '^(podman|container) build ' "$FAKE_LOG" | awk '{
        out = ""
        for (i = 3; i <= NF; i++) {
          if ($i == "-t" || $i == "-f" || $i == "--build-arg" || $i == "--tag" || $i == "--file") { i++; continue }
          if (i == NF) continue
          out = out (out == "" ? "" : " ") $i
        }
        print out }' | sort -u)"
      assert_eq "$want" "$flags" "$ep: every build (unbound, pi-hole and any base) uses exactly [$want]:
$(grep -E '^(podman|container) build ' "$FAKE_LOG")"
      assert_eq "$([ "$(ip_flavor "$ep")" = hardened ] && echo 3 || echo 2)" "$(grep -cE '^(podman|container) build ' "$FAKE_LOG")" "$ep: the expected number of builds"
    ) || exit 1
  done
}

# A host where the user has no subordinate ids yet (a first install): the
# ranges usermod adds reach podman only through `podman system migrate`, so it
# runs right after usermod and before the builds, which need the ranges.
# With ranges present it stays in the interruption window.
t_new_subids_are_migrated_before_the_builds() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    [ "$(ip_platform "$ep")" = linux ] || continue
    (
      local um mig b first
      ip_env "$ep"
      : >"$IP_W/etc/subuid"; : >"$IP_W/etc/subgid"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: $IP_OUT"
      um="$(ip_last "$FAKE_LOG" '^sudo usermod --add-sub[ug]ids ')"
      mig="$(ip_first "$FAKE_LOG" '^podman system migrate')"
      b="$(ip_first "$FAKE_LOG" '^podman build ')"
      assert_ne "" "$um" "$ep: the missing ranges are added"
      assert_ne "" "$mig" "$ep: podman is migrated"
      assert_eq 1 "$((um < mig && mig < b))" "$ep: usermod (line $um), then migrate (line $mig), then the first build (line $b):
$(cat -n "$FAKE_LOG")"
    ) || exit 1
    (
      ip_env "$ep"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: $IP_OUT"
      assert_eq "" "$(ip_lines "$FAKE_LOG" '^sudo usermod ')" "$ep: existing ranges are kept"
      first="$(ip_first "$FAKE_LOG" '^podman system migrate')"
      assert_eq 1 "$((first > $(ip_last "$FAKE_LOG" '^podman build ')))" "$ep: with ranges present, migrate waits for the interruption"
    ) || exit 1
  done
}

t_reinstall_keeps_the_previous_generation() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local g1 g2 g3 m2 m3 r
      ip_env "$ep"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep 1: $IP_OUT"
      g1="$(ip_gen_current)"
      : >"$FAKE_LOG"
      printf 'aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddd\n' >"$FAKE/git_head"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep 2: $IP_OUT"
      g2="$(ip_gen_current)"
      assert_ne "$g1" "$g2" "$ep: a new generation"
      assert_eq 1 "$([ "$g1" \< "$g2" ] && echo 1 || echo 0)" "$ep: generation ids sort in install order"
      m2="$(ip_manifest "$g2")"
      assert_eq "$g1" "$(ip_row "$m2" previous)" "$ep: previous names the prior generation"
      assert_eq "$(printf '%s\tavailable' "$g1")" "$(ip_row "$m2" rollback)" "$ep: and its images are available for rollback"
      for r in $(ip_refs "$(ip_manifest "$g1")"); do
        assert_eq 0 "$(grep -cE "^(podman|container) (image rm|rmi|image delete)( .*)? $r( |$)" "$FAKE_LOG")" "$ep: reinstall does not remove $r"
        ip_has_image "$r" || fail "$ep: previous generation image $r is gone after reinstall"
      done
      assert_eq 0 "$(grep -cE '^(podman|container) (image rm|rmi|image delete)( -f)? (unbound|pi-hole|localhost/unbound|localhost/pi-hole|docker\.io/sureserver/tor-(haproxy|socat):latest)$' "$FAKE_LOG")" "$ep: teardown no longer removes the stack's images"
      if [ "$(ip_platform "$ep")" = linux ]; then
        assert_match '^podman tag localhost/unbound:'"$g2"' localhost/unbound:latest$' "$(cat "$FAKE_LOG")" "$ep: :latest follows the activated generation"
      else
        assert_match '^container image tag unbound:'"$g2"' unbound:latest$' "$(cat "$FAKE_LOG")" "$ep: :latest follows the activated generation"
      fi
      : >"$FAKE_LOG"
      printf 'eeeeeeeeeeeeffffffffffff0000000000001111\n' >"$FAKE/git_head"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep 3: $IP_OUT"
      g3="$(ip_gen_current)"
      m3="$(ip_manifest "$g3")"
      assert_eq "$(printf '%s\tavailable' "$g2")" "$(ip_row "$m3" rollback)" "$ep: the third install can roll back to the second"
      for r in $(ip_refs "$m2"); do ip_has_image "$r" || fail "$ep: $r (previous) was pruned"; done
      for r in $(ip_refs "$m3"); do ip_has_image "$r" || fail "$ep: $r (current) is missing"; done
      for r in $(ip_refs "$(ip_manifest "$g1")"); do
        if ip_has_image "$r"; then fail "$ep: $r is older than the previous generation and was kept"; fi
      done
      assert_ne 0 "$(grep -cE '^(podman image rm|container image (rm|delete))' "$FAKE_LOG")" "$ep: the oldest generation was pruned"
      # A previous generation whose images were removed is not rollback capacity.
      for r in $(ip_refs "$m3"); do awk -v r="$r" '$1 != r' "$FAKE/images" >"$FAKE/images.t" && mv "$FAKE/images.t" "$FAKE/images"; done
      printf '2222222222223333333333334444444444445555\n' >"$FAKE/git_head"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep 4: $IP_OUT"
      assert_eq "$(printf '%s\tmissing' "$g3")" "$(ip_row "$(ip_manifest "$(ip_gen_current)")" rollback)" "$ep: rollback is missing when the previous images are gone"
    ) || exit 1
  done
}

t_uninstall_still_removes_the_stack() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      ip_env "$ep"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: $IP_OUT"
      : >"$FAKE_LOG"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep uninstall: $IP_OUT"
      assert_match '^nice-dns uninstalled\.$' "$IP_OUT" "$ep: the existing message"
      if [ "$(ip_platform "$ep")" = linux ]; then
        assert_match '^podman rm -f pi-hole$' "$(cat "$FAKE_LOG")" "$ep: containers removed"
        # Since Task 1.2 the helper gives back the recorded DNS state.
        assert_match '^sudo bash .*/deb/custom-dns-deb restore$' "$(cat "$FAKE_LOG")" "$ep: the recorded DNS state is restored"
        assert_match '^sudo rm -f /usr/bin/custom-dns-deb$' "$(cat "$FAKE_LOG")" "$ep: the pin helper is removed"
      else
        assert_match '^container rm pi-hole$' "$(cat "$FAKE_LOG")" "$ep: containers removed"
        assert_match '^launchctl unload .*org\.nice-dns\.bridge-eval\.plist$' "$(cat "$FAKE_LOG")" "$ep: the shared agent list includes bridge-eval"
        assert_match '^sudo bash .*/mac/start-container-root\.sh restore$' "$(cat "$FAKE_LOG")" "$ep: the recorded DNS state is restored"
        assert_not_match 'setdnsservers' "$(cat "$FAKE_LOG")" "$ep: the installer itself sets no DNS servers"
      fi
      assert_eq "" "$(grep -E 'unbound|pi-hole|tor-' "$FAKE/images")" "$ep: every nice-dns image, generation tags included, is removed:
$(cat "$FAKE/images")"
      assert_eq "" "$(grep -E "$IP_BUILD_PULL" "$FAKE_LOG")" "$ep: uninstall builds and pulls nothing"
    ) || exit 1
  done
}

t_checkout_is_used_without_a_clone() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local m
      ip_env "$ep"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: $IP_OUT"
      assert_eq "" "$(grep '^git clone' "$FAKE_LOG")" "$ep: run from a checkout, it does not clone"
      m="$(ip_manifest "$(ip_gen_current)")"
      assert_eq checkout "$(ip_row "$m" source_origin)" "$ep: source_origin checkout"
      if [ "$(ip_platform "$ep")" = macos ]; then
        # Apple's builder VM cannot read $TMPDIR: the build tree is a copy
        # under $HOME, and the macOS rewrites apply to the copy only.
        assert_eq "" "$(grep -v "^$IP_HOME/\\.nice-dns-install\\.[A-Za-z0-9]*/nice-dns\$" "$FAKE/build-cwd")" "$ep: builds run in a copy under \$HOME:
$(cat "$FAKE/build-cwd")"
        assert_eq "$(cat "$NICE_DNS_ROOT/unbound/etc/unbound.conf")" "$(cat "$IP_TREE/unbound/etc/unbound.conf")" "$ep: the checkout's unbound.conf is untouched"
        assert_eq "$(cat "$NICE_DNS_ROOT/unbound/route/forward-route.conf")" "$(cat "$IP_TREE/unbound/route/forward-route.conf")" "$ep: the checkout's route include is untouched"
        assert_eq "" "$(ls -d "$IP_HOME"/.nice-dns-install.* 2>/dev/null)" "$ep: the private copy is removed afterwards"
      else
        assert_eq "" "$(grep -v "^$IP_TREE\$" "$FAKE/build-cwd")" "$ep: builds run in the checkout"
      fi
      # Without a checkout (bash <(curl …)) the branch is cloned first.
      rm -rf "$IP_W/solo"; mkdir -p "$IP_W/solo" && cp "$IP_TREE/$ep.sh" "$IP_W/solo/"
      : >"$FAKE_LOG"; : >"$FAKE/build-cwd"
      printf '9999999999998888888888887777777777776666\n' >"$FAKE/git_head"
      ip_run "$IP_W/solo/$ep.sh" haproxy dev
      assert_rc 0 "$IP_RC" "$ep solo: $IP_OUT"
      assert_match '^git clone (-q )?-b dev https://github\.com/sureserverman/nice-dns\.git ' "$(cat "$FAKE_LOG")" "$ep: clones the branch"
      assert_eq clone "$(ip_row "$(ip_manifest "$(ip_gen_current)")" source_origin)" "$ep: source_origin clone"
      assert_eq 1 "$(( $(ip_first "$FAKE_LOG" '^git clone') < $(ip_first "$FAKE_LOG" "$IP_BUILD_PULL") ))" "$ep: the source is staged before any image work"
    ) || exit 1
  done
}

t_mac_rewrites_are_portable_and_exact() {
  # The macOS unbound.conf / route include rewrites run in lib/install.sh
  # without `sed -i ''`, so they run (and are tested) on either platform.
  local d="$CASE_DIR/rw" out
  mkdir -p "$d/unbound/etc" "$d/unbound/route"
  cp "$NICE_DNS_ROOT/unbound/etc/unbound.conf" "$d/unbound/etc/"
  cp "$NICE_DNS_ROOT/unbound/route/forward-route.conf" "$d/unbound/route/"
  # shellcheck source=/dev/null
  out="$( . "$NICE_DNS_ROOT/lib/install.sh" && nd_install_macos_rewrite_tree "$d" 2>&1)"
  assert_rc 0 "$?" "rewrite: $out"
  assert_match '^    interface: 0\.0\.0\.0$' "$(cat "$d/unbound/etc/unbound.conf")" "unbound listens on dnsnet"
  assert_not_match '^    interface: 127\.0\.0\.1$' "$(cat "$d/unbound/etc/unbound.conf")" "not only on loopback"
  assert_eq "$(printf '    access-control: 127.0.0.0/8 allow\n    access-control: 172.31.240.248/29 allow')" "$(grep -A1 '^    access-control: 127\.0\.0\.0/8 allow$' "$d/unbound/etc/unbound.conf")" "dnsnet peers are allowed"
  assert_match '^    forward-addr: 172\.31\.240\.252@853#tor\.cloudflare-dns\.com$' "$(cat "$d/unbound/route/forward-route.conf")" "the default route forwards to the proxy container"
  assert_not_match '127\.0\.0\.1@' "$(cat "$d/unbound/route/forward-route.conf")" "no loopback forwarder is left"
  assert_eq "$(sed -e 's|^    interface: 127\.0\.0\.1$|    interface: 0.0.0.0|' "$NICE_DNS_ROOT/unbound/etc/unbound.conf" | wc -l | tr -d ' ')" "$(( $(wc -l <"$d/unbound/etc/unbound.conf") - 1 ))" "exactly one line is added to unbound.conf"
}

t_bash32_pure_functions() {
  local w="$CASE_DIR/b32" img=docker.io/library/bash:3.2 out
  if ! podman image exists "$img" 2>/dev/null; then
    fail "image $img is not available locally; the Bash 3.2 proof cannot run (pull it: podman pull $img)"
  fi
  mkdir -p "$w"
  cat >"$w/inner.sh" <<'INNER'
set -u
case "$BASH_VERSION" in 3.2.*) ;; *) echo "not bash 3.2: $BASH_VERSION"; exit 90 ;; esac
. /src/lib/install.sh || { echo "source=1"; exit 1; }
echo "source=0"
g="$(nd_install_generation_id 0123456789abcdef0123456789abcdef01234567 20260927T101112Z)"; echo "gen=$g"
g2="$(nd_install_generation_id unknown 20260927T101112Z)"; echo "gen2=$g2"
nd_install_generation_id 'x;y' 20260927T101112Z >/dev/null 2>&1; echo "badcommit=$?"
nd_install_valid_generation "$g"; echo "valid=$?"
nd_install_valid_generation '$(touch /tmp/pwned)'; echo "invalid=$?"
s=/tmp/state; mkdir -p "$s/generations/$g"; chmod 700 "$s" "$s/generations" "$s/generations/$g"
m="$s/generations/$g/prepare.tsv"
_nd_inst_manifest_init "$m"; echo "init=$?"
_nd_inst_manifest_row "$m" generation "$g"
_nd_inst_manifest_row "$m" branch 'feat/x y'
_nd_inst_manifest_row "$m" image unbound localhost/unbound:"$g" abcdef0123456789
_nd_inst_manifest_row "$m" image proxy localhost/tor-haproxy:"$g" 0123456789abcdef
_nd_inst_manifest_row "$m" branch "$(printf 'a\tb')" 2>/dev/null; echo "tabrow=$?"
echo "mode=$(ls -l "$m" | cut -c1-10)"
echo "branch=$(nd_install_manifest_get "$m" branch)"
echo "images=$(nd_install_manifest_images "$m" | tr '\t\n' ',;')"
printf '%s\n' "$g" >"$s/current"; chmod 600 "$s/current"
echo "current=$(nd_install_read_current "$s")"
printf '$(touch /tmp/pwned)\n' >"$s/current"
nd_install_read_current "$s" >/dev/null 2>&1; echo "badcurrent=$?"
printf 'schema\tsomething-else/1\nbranch\tx\n' >/tmp/other.tsv
nd_install_manifest_get /tmp/other.tsv branch >/dev/null 2>&1; echo "badschema=$?"
[ -e /tmp/pwned ] && echo pwned || echo clean
INNER
  out="$(podman run --rm --network none --pull=never -v "$NICE_DNS_ROOT:/src:ro" -v "$w:/work:ro" "$img" bash /work/inner.sh 2>&1)"
  assert_match '^source=0$' "$out" "bash 3.2 loads lib/install.sh: $out"
  assert_match '^gen=20260927T101112Z-0123456789ab$' "$out" "generation id"
  assert_match '^gen2=20260927T101112Z-nogit0000000$' "$out" "generation id without git"
  assert_match '^badcommit=[1-9]' "$out" "a malformed commit is refused"
  assert_match '^valid=0$' "$out" "a generation id validates"
  assert_match '^invalid=[1-9]' "$out" "a hostile string does not"
  assert_match '^init=0$' "$out" "manifest init"
  assert_match '^tabrow=[1-9]' "$out" "a value with a tab is refused"
  assert_match '^mode=-rw-------$' "$out" "the manifest is 0600"
  assert_match '^branch=feat/x y$' "$out" "a row reads back as data"
  assert_match '^images=unbound,localhost/unbound:20260927T101112Z-0123456789ab,abcdef0123456789;proxy,localhost/tor-haproxy:20260927T101112Z-0123456789ab,0123456789abcdef;$' "$out" "image rows read back"
  assert_match '^current=20260927T101112Z-0123456789ab$' "$out" "current reads back"
  assert_match '^badcurrent=[1-9]' "$out" "a malformed current is refused"
  assert_match '^badschema=[1-9]' "$out" "a manifest with another schema is refused"
  assert_match '^clean$' "$out" "nothing in the data was executed"
}

t_bash32_runs_the_mac_entrypoints() {
  # The macOS entrypoints run under /bin/bash 3.2: run each end to end, with
  # the same stubs, inside docker.io/library/bash:3.2 (--rm, no network). The
  # world is mounted read-only, copied to its own path inside the container
  # and run by an unprivileged user there (the entrypoints refuse root); the
  # results come back on stdout.
  local ep img=docker.io/library/bash:3.2 n=0
  if ! podman image exists "$img" 2>/dev/null; then
    fail "image $img is not available locally; the Bash 3.2 proof cannot run (pull it: podman pull $img)"
  fi
  ip_select
  for ep in $IP_EPS; do
    [ "$(ip_platform "$ep")" = macos ] || continue
    n=$((n + 1))
    (
      local out
      ip_env "$ep"
      # The image's own tools, not the host's.
      find "$IP_BIN" -type l ! -lname fakecmd -delete
      cat >"$IP_W/inner.sh" <<INNER
set -u
case "\$BASH_VERSION" in 3.2.*) ;; *) echo "not bash 3.2: \$BASH_VERSION"; exit 90 ;; esac
adduser -D -s /bin/sh tester >/dev/null 2>&1 || exit 91
mkdir -p "$IP_W" && cp -a /world/. "$IP_W/" && chown -R tester "$IP_W" || exit 92
su -s /bin/sh tester -c 'cd "$IP_W" && env -i HOME="$IP_HOME" USER=tester PATH="$IP_BIN:/usr/local/bin:/usr/bin:/bin" TMPDIR="$IP_W/tmp" XDG_STATE_HOME="$IP_HOME/.local/state" XDG_CONFIG_HOME="$IP_HOME/.config" FAKE="$FAKE" FAKE_LOG="$FAKE_LOG" FAKE_UNAME=Darwin FAKE_ARCH=arm64 bash "$IP_TREE/$ep.sh" socat >"$IP_W/out" 2>&1; echo "rc=\$?"'
sed 's/^/out: /' "$IP_W/out"
sed 's/^/log: /' "$FAKE_LOG"
g="\$(cat "$IP_STATE/current")"
sed 's/^/manifest: /' "$IP_STATE/generations/\$g/prepare.tsv"
INNER
      out="$(podman run --rm --network none --pull=never -v "$IP_W:/world:ro" "$img" bash /world/inner.sh 2>&1)"
      assert_match '^rc=0$' "$out" "$ep under bash 3.2: $out"
      assert_match '^manifest: variant	socat$' "$out" "$ep under bash 3.2: the manifest records the install"
      assert_match '^log: container run -d --name tor-socat --network dnsnet -c 1 -m 512M -e BRIDGE1=obfs4 .* -e BRIDGE5=obfs4 .* docker\.io/sureserver/tor-socat:latest$' "$out" "$ep under bash 3.2: every bridge reaches the proxy"
      assert_match '^log: container build --no-cache --dns 1\.1\.1\.1 -t unbound:' "$out" "$ep under bash 3.2: images are built"
    ) || exit 1
  done
  [ "$n" -gt 0 ] || assert_eq 0 0 "no macOS entrypoint selected"
}
