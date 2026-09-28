# shellcheck shell=bash
# Group integration/lifecycle-transitions (Sub-plan 4, Task 2.2; ARCH-06,
# ARCH-08). Instance state across the installers' lifecycle, per entrypoint
# (--entrypoints ...), and the state volumes' behaviour on the real images.
#
# Instance state (design "Installers and persistence": preserve Tor state,
# the resolver's trust anchor, operator settings and credentials across
# repair and upgrade):
#   Tor state        Linux: podman volume nice-dns-tor-<proxy> at /app/data
#                    macOS: ~/.local/state/nice-dns/tor-<proxy> (bind, as before)
#   root anchor      volume nice-dns-unbound-anchor at /var/lib/unbound
#   Pi-hole lists    volume nice-dns-pihole-lists at /var/lib/nice-dns-pihole
#                    (gravity.db; the operator's allow/deny lists, groups,
#                    clients and added blocklists; user decision 2026-09-27:
#                    lists survive, configuration comes from the image)
#   admin password   ~/.local/state/nice-dns/secrets/pihole (Task 2.1)
# macOS creates its volumes and hands them to the image's user in the
# interruption window: Apple's `container` volumes are fresh root-owned ext4
# with no copy of the image's directory (mac target, container 1.4.1).
#
# Installer half, in the fixture (tests/fixtures/install-fakes.sh): every
# entrypoint runs fresh install, reinstall, proxy switch, Pi-hole image
# switch and back, failed image pull, failed bridge fetch (macOS; the Linux
# installer fetches none), failed readiness, interrupted cutover and an
# upgrade, then uninstall. After every step the instance state is intact
# (never removed, credential unchanged) and the host is pinned to a stack that
# answers; uninstall removes the instance state and gives back the DNS state
# recorded before the first install. The quadlets and both macOS launch
# paths mount the volumes; the installed bundle works after the checkout
# moves.
#
# Image half, real containers under Linux podman (--network none, test
# volumes nd-test-lt-<run>-*): the operator's lists survive a restart, a
# switch between the standard and hardened images and back (each switch is a
# new image seed, so the merge runs), and the anchor and Tor state volumes
# keep what their users wrote. Production volumes are never touched.

. "$NICE_DNS_ROOT/tests/fixtures/install-fakes.sh"
# shellcheck source=tests/fixtures/transport.sh
. "$NICE_DNS_ROOT/tests/fixtures/transport.sh"
# shellcheck source=tests/fixtures/pihole-image.sh
. "$NICE_DNS_ROOT/tests/fixtures/pihole-image.sh"
# shellcheck source=tests/fixtures/unbound-image.sh
. "$NICE_DNS_ROOT/tests/fixtures/unbound-image.sh"

LT_VOL_RM='^(podman volume (rm|remove|prune)|container volume (rm|delete|prune)|podman system reset)( |$)'
LT_LISTS=/var/lib/nice-dns-pihole

lt_other() { case "$1" in *-hardened) printf '%s\n' "${1%-hardened}" ;; *) printf '%s-hardened\n' "$1" ;; esac; }
lt_secret() { printf '%s/.local/state/nice-dns/secrets/pihole/pihole_webpassword\n' "$IP_HOME"; }

# lt_state_marks: marker files standing in for instance state the fixture
# cannot hold (volumes live in the runtime); the macOS Tor directories are
# real host paths, so their markers are real.
lt_marks() {
  local v
  if [ "$(ip_platform "$1")" = macos ]; then
    for v in haproxy socat; do
      mkdir -p "$IP_HOME/.local/state/nice-dns/tor-$v" && printf 'state %s\n' "$v" >"$IP_HOME/.local/state/nice-dns/tor-$v/state"
    done
  fi
}
lt_marks_intact() {
  local v
  [ "$(ip_platform "$1")" = macos ] || return 0
  for v in haproxy socat; do
    [ "$(cat "$IP_HOME/.local/state/nice-dns/tor-$v/state" 2>/dev/null)" = "state $v" ] || return 1
  done
}

# lt_step <ep> <label> <expect ok|fail> <args...>: one lifecycle step with
# the invariants every step keeps.
lt_step() {
  local ep="$1" label="$2" want="$3" pw deploy
  shift 3
  pw="$(cat "$(lt_secret)")"
  deploy="$(dt_deploy_state | grep -v '^stack answers$')"
  : >"$FAKE_LOG"
  # A new source commit per step: two installs of one commit in the same
  # second would share a generation id (the fixture's sleep returns at once).
  LT_N=$(( ${LT_N:-0} + 1 ))
  printf '%012x%s\n' "$LT_N" dddddddddddddddddddddddddddd >"$FAKE/git_head"
  ip_install "$ep" "$@"
  if [ "$want" = ok ]; then
    assert_rc 0 "$IP_RC" "$label: $IP_OUT"
  else
    assert_nonzero "$IP_RC" "$label fails: $IP_OUT"
    # Every restoration step ran: the deployment (units, agents, helpers, the
    # images :latest names) is the one from before the step.
    assert_eq "$deploy" "$(dt_deploy_state | grep -v '^stack answers$')" "$label: the previous deployment is back exactly"
  fi
  assert_eq "" "$(ip_lines "$FAKE_LOG" "$LT_VOL_RM")" "$label: no instance state volume is removed"
  lt_marks_intact "$ep" || fail "$label: the Tor state directories are intact"
  assert_eq "$pw" "$(cat "$(lt_secret)" 2>/dev/null)" "$label: the admin password is unchanged"
  dt_pinned || fail "$label: the host stays pinned to the stack: $(dt_dns_state)"
  [ -f "$FAKE/dns_up" ] || fail "$label: a stack answers after the step"
}

t_every_transition_keeps_the_instance_state() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local other before plat
      plat="$(ip_platform "$ep")"
      other="$(lt_other "$ep")"
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      # Both images' entrypoints run in the same world (the image switch).
      mkdir -p "$IP_W/src/pi-hole-hardened"
      printf 'FROM alpine:3.21.3\n' >"$IP_W/src/pi-hole-hardened/Dockerfile"; : >"$IP_W/src/pi-hole-hardened/post-install.sh"
      before="$(dt_dns_state)"
      ip_install "$ep" socat
      assert_rc 0 "$IP_RC" "$ep: fresh install: $IP_OUT"
      assert_file "$(lt_secret)" "$ep: the admin password exists"
      lt_marks "$ep"
      lt_step "$ep" "$ep: reinstall" ok socat
      lt_step "$ep" "$ep: proxy switch" ok haproxy
      lt_step "$other" "$ep: Pi-hole image switch ($other)" ok haproxy
      lt_step "$ep" "$ep: and back" ok haproxy
      printf '^(podman pull|container image pull) \n' >"$FAKE/fail"
      lt_step "$ep" "$ep: failed image pull" fail haproxy
      rm -f "$FAKE/fail"
      if [ "$plat" = macos ]; then
        mv "$IP_HOME/.config/nice-dns/bridges.env" "$IP_W/bridges.env.saved"
        lt_step "$ep" "$ep: failed bridge fetch" fail haproxy
        mv "$IP_W/bridges.env.saved" "$IP_HOME/.config/nice-dns/bridges.env"
      fi
      : >"$FAKE/never_ready"
      lt_step "$ep" "$ep: failed readiness (rolled back)" fail haproxy
      rm -f "$FAKE/never_ready"
      if [ "$plat" = linux ]; then printf '^podman pod rm -f nice-dns$\n' >"$FAKE/sigint"; else printf '^container stop pi-hole$\n' >"$FAKE/sigint"; fi
      lt_step "$ep" "$ep: interrupted cutover (rolled back)" fail haproxy
      rm -f "$FAKE/sigint"
      printf 'cccccccccccccccccccccccccccccccccccccccc\n' >"$FAKE/git_head"
      lt_step "$ep" "$ep: upgrade" ok haproxy

      : >"$FAKE_LOG"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep: uninstall: $IP_OUT"
      assert_eq "$before" "$(dt_dns_state)" "$ep: uninstall gives back the DNS state from before the first install"
      assert_no_path "$(dirname "$(lt_secret)")" "$ep: the admin password is gone"
      if [ "$plat" = linux ]; then
        for v in nice-dns-unbound-anchor nice-dns-pihole-lists nice-dns-tor-haproxy nice-dns-tor-socat; do
          assert_match "^podman volume rm (-f )?$v\$" "$(cat "$FAKE_LOG")" "$ep: uninstall removes the volume $v"
        done
      else
        for v in nice-dns-unbound-anchor nice-dns-pihole-lists; do
          assert_match "^container volume (rm|delete) $v\$" "$(cat "$FAKE_LOG")" "$ep: uninstall removes the volume $v"
        done
        assert_no_path "$IP_HOME/.local/state/nice-dns/tor-socat" "$ep: and the Tor state"
        assert_no_path "$IP_HOME/.local/state/nice-dns/tor-haproxy" "$ep: of both proxies"
      fi
    ) || exit 1
  done
}

# ─────────────────────────── the mounts ─────────────────────────────────────

lt_generated() {
  local q
  for q in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet; do [ -x "$q" ] && break; done
  [ -x "$q" ] || fail "no quadlet generator on this host"
  QUADLET_UNIT_DIRS="$2" "$q" -dryrun -user 2>/dev/null \
    | awk -v u="---$1---" '$0 == u { f = 1; next } /^---.*---$/ { f = 0 } f && /^ExecStart=/ { sub(/^ExecStart=/, ""); print }'
}
lt_mounts() { printf '%s\n' "$1" | tr ' ' '\n' | awk 'p { print; p = 0; next } $0 == "-v" || $0 == "--volume" { p = 1 } /^--volume=/ { print substr($0, 10) }'; }

t_linux_quadlets_mount_the_instance_state() {
  local v q gen
  for v in haproxy socat; do
    (
      local f
      dt_world install-deb resolved
      mkdir -p "$IP_W/real"
      for f in deb mac scripts health lib routes; do cp -R "$NICE_DNS_ROOT/$f" "$IP_W/real/"; done
      mkdir -p "$IP_W/run/systemd/generator" && : >"$IP_W/run/systemd/generator/nice-dns-pod.service"
      : >"$FAKE_ROOT/.systemd/NetworkManager-wait-online.unit"
      ip_run "$IP_W/real/deb/persistent-podman.sh" "$v" standard
      assert_rc 0 "$IP_RC" "persistent-podman.sh $v: $IP_OUT"
      q="$IP_HOME/.config/containers/systemd"
      gen="$(lt_generated "tor-$v.service" "$q")"
      assert_match "^nice-dns-tor-$v:/app/data\$" "$(lt_mounts "$gen")" "$v: Tor keeps its data directory in a volume"
      assert_match '^DataDirectory /app/data/' "$(cat "$TP_SIBS/tor-$v/torrc")" "$v: which holds the image's DataDirectory"
      gen="$(lt_generated unbound.service "$q")"
      assert_match '^nice-dns-unbound-anchor:/var/lib/unbound$' "$(lt_mounts "$gen")" "$v: Unbound keeps its trust anchor in a volume"
      gen="$(lt_generated pi-hole.service "$q")"
      assert_match "^nice-dns-pihole-lists:$LT_LISTS\$" "$(lt_mounts "$gen")" "$v: Pi-hole keeps its lists in a volume"
    ) || exit 1
  done
}

# lt_agent_args <container>: the start-container agent's arguments for it.
lt_agent_args() {
  local f="$NICE_DNS_ROOT/mac/start-container.sh" snip
  snip="$(awk -v c="$1" '/^(PIHOLE_SECRET_DIR|TOR_STATE_DIR|TOR_CONTAINER|TOR_IMAGE|VARIANT|ND_ANCHOR_VOLUME|ND_LISTS_VOLUME)=/ { print }
    $0 ~ "^[[:space:]]*ensure_container " c "( |\\\\|$)" { f = 1 } f { print } f && !/\\$/ { exit }' "$f")"
  [ -n "$snip" ] || fail "no $1 launch in $f"
  env -i HOME="$IP_HOME" PATH="$PATH" bash -c 'BRIDGE_ARGS=(); ensure_container() { shift; printf "%s\n" "$@"; }; set -- socat; '"$snip"
}
t_macos_launch_paths_mount_the_instance_state() {
  local ep
  for ep in install-mac install-mac-hardened; do
    (
      local line got name cre ini run
      dt_world "$ep" fresh
      ip_install "$ep" socat
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      for name in unbound pi-hole; do
        line="$(grep -E "^container run -d --name $name " "$FAKE_LOG" | tail -n 1)"
        got="$(printf '%s\n' "${line#container run -d --name "$name" --network dnsnet }" | tr ' ' '\n')"
        assert_eq "$(lt_agent_args "$name")" "$got" "$ep: the agent recreates $name exactly as the installer started it"
      done
      line="$(grep -E '^container run -d --name tor-socat ' "$FAKE_LOG" | tail -n 1)"
      assert_match " -v $IP_HOME/.local/state/nice-dns/tor-socat:/app/data " "$line" "$ep: Tor state as before"
      assert_match " -v nice-dns-unbound-anchor:/var/lib/unbound " "$(grep -E '^container run -d --name unbound ' "$FAKE_LOG")" "$ep: Unbound mounts the anchor volume"
      assert_match " -v nice-dns-pihole-lists:$LT_LISTS " "$(grep -E '^container run -d --name pi-hole ' "$FAKE_LOG")" "$ep: Pi-hole mounts the lists volume"
      for name in nice-dns-unbound-anchor nice-dns-pihole-lists; do
        cre="$(ip_first "$FAKE_LOG" "^container volume create $name\$")"
        ini="$(ip_first "$FAKE_LOG" "^container run --rm --user 0 -v $name:/mnt ")"
        run="$(ip_first "$FAKE_LOG" '^container run -d --name pi-hole ')"
        assert_ne "" "$cre" "$ep: $name is created"
        assert_ne "" "$ini" "$ep: and handed to the image's user"
        assert_eq 1 "$(( cre < ini && ini < run ))" "$ep: before the stack starts (lines $cre, $ini, $run)"
      done
      # Live 2026-09-28: containers on the default network (buildkit, the
      # volume hand-over) wedge dnsnet; the stack starts on a restarted runtime.
      ini="$(ip_last "$FAKE_LOG" '^container run --rm --user 0 ')"
      cre="$(ip_last "$FAKE_LOG" '^container system stop$')"
      run="$(ip_last "$FAKE_LOG" '^container system start$')"
      assert_ne "" "$cre" "$ep: the runtime is stopped"
      assert_eq 1 "$(( ini < cre && cre < run && run < $(ip_first "$FAKE_LOG" '^container network create ') ))" "$ep: after the last default-network container and before dnsnet and the stack (lines $ini, $cre, $run)"
      assert_match "^container run --rm --user 0 -v nice-dns-unbound-anchor:/mnt .*chown unbound:unbound /mnt" "$(cat "$FAKE_LOG")" "$ep: the anchor volume belongs to unbound"
      assert_match "^container run --rm --user 0 -v nice-dns-pihole-lists:/mnt .*chown pihole:pihole /mnt" "$(cat "$FAKE_LOG")" "$ep: the lists volume belongs to pihole"
    ) || exit 1
  done
}

t_installed_bundle_works_after_the_checkout_moves() {
  (
    local f q
    dt_world install-deb resolved
    mkdir -p "$IP_W/real"
    for f in deb mac scripts health lib routes; do cp -R "$NICE_DNS_ROOT/$f" "$IP_W/real/"; done
    mkdir -p "$IP_W/run/systemd/generator" && : >"$IP_W/run/systemd/generator/nice-dns-pod.service"
    : >"$FAKE_ROOT/.systemd/NetworkManager-wait-online.unit"
    ip_run "$IP_W/real/deb/persistent-podman.sh" socat standard
    assert_rc 0 "$IP_RC" "persistent-podman.sh: $IP_OUT"
    mv "$IP_W/real" "$IP_W/moved"
    q="$(grep -rlF "$IP_W/real" "$IP_HOME" "$FAKE_ROOT" 2>/dev/null)"
    assert_eq "" "$q" "no installed file refers to the checkout"
    f="$(awk -F '\t' '$1 == "entrypoint" { print $2; exit }' "$IP_HOME/.local/share/nice-dns-health/install.tsv")"
    assert_file "$f" "the installed controller entrypoint"
    IP_OUT="$(env -i HOME="$IP_HOME" PATH="$IP_BIN" FAKE_UNAME=Linux FAKE_ARCH=x86_64 XDG_STATE_HOME="$IP_HOME/.local/state" XDG_CONFIG_HOME="$IP_HOME/.config" \
      XDG_DATA_HOME="$IP_HOME/.local/share" XDG_RUNTIME_DIR="$IP_W/run" FAKE="$FAKE" FAKE_LOG="$FAKE_LOG" bash "$f" self-check 2>&1)"
    assert_rc 0 "$?" "the installed controller passes its self-check with the checkout gone: $IP_OUT"
  ) || exit 1
}

# ─────────────────────────── images (real containers) ───────────────────────

LT_PW="lt-test-password-$$"

# lt_ph <flavor> <volume>: Pi-hole on the lists volume, in a fresh namespace.
lt_ph() {
  local i=0
  TP_PFX="nd-test-tp-$RUN_ID-lt-$1-$(date +%s%N | cut -c10-16)"
  TP_CTRS="" TP_SOCKS_WRAP="" TP_NSPID="" TP_SOCKS=""
  ph_image "$1"
  TP_IMG="$PH_IMG"
  tp_holder
  tp_run ph -v "$2:$LT_LISTS" -e "FTLCONF_webserver_api_password=$LT_PW" -e TZ=Europe/London -e DISABLE_GITHUB_UPDATES=true "$PH_IMG"
  until [ "$(lt_http_code http://127.0.0.1/api/info/login)" = 200 ]; do
    i=$((i + 1))
    [ "$i" -le 180 ] || fail "Pi-hole ($1) never served its API: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
    [ "$(podman inspect -f '{{.State.Running}}' "$TP_CTR" 2>/dev/null)" = true ] || fail "Pi-hole ($1) exited: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
    sleep 0.5
  done
  printf '{"password":"%s"}' "$LT_PW" >"$CASE_DIR/auth.json"
  tp_ns curl -s -m 10 --data "@$CASE_DIR/auth.json" http://127.0.0.1/api/auth
  LT_SID="$(printf '%s\n' "$TP_OUT" | sed -n 's/.*"sid":"\([^"]*\)".*/\1/p')"
  [ -n "$LT_SID" ] || fail "no API session: $TP_OUT"
}
lt_http_code() { tp_ns curl -s -m 5 -o /dev/null -w '%{http_code}' "$@"; printf '%s\n' "$TP_OUT"; }
lt_api() { tp_ns curl -s -m 10 -H "X-FTL-SID: $LT_SID" "$@"; printf '%s\n' "$TP_OUT"; }
# lt_write <curl args>: an API write that must report no error; LT_OUT.
lt_write() {
  LT_OUT="$(lt_api "$@")"
  assert_match '"success":\[\{' "$LT_OUT" "API write $*"
  assert_match '"errors":\[\]' "$LT_OUT" "API write $* reports no error"
}
lt_sql() { tp_pm exec "$TP_CTR" pihole-FTL sqlite3 -ni "$LT_LISTS/gravity.db" "$1"; printf '%s\n' "$TP_OUT"; }
lt_dig() { tp_ns dig @127.0.0.1 +time=3 +tries=1 +short "$1" A; printf '%s\n' "$TP_OUT"; }

# lt_operator_state: the operator's rows, canonical (ids are not compared).
lt_operator_state() {
  lt_sql "SELECT 'domain', type, domain, enabled, IFNULL(comment,'') FROM domainlist WHERE domain LIKE '%operator%' OR domain LIKE '%opregex%' ORDER BY 2, 3;
          SELECT 'group', name, enabled FROM \"group\" WHERE id != 0 ORDER BY 2;
          SELECT 'client', ip, (SELECT group_concat(g.name) FROM client_by_group cg JOIN \"group\" g ON g.id = cg.group_id WHERE cg.client_id = client.id) FROM client ORDER BY 2;
          SELECT 'member', d.domain, g.name FROM domainlist_by_group dg JOIN domainlist d ON d.id = dg.domainlist_id JOIN \"group\" g ON g.id = dg.group_id WHERE d.domain LIKE '%operator%' ORDER BY 2, 3;
          SELECT 'adlist', address, enabled FROM adlist WHERE address LIKE '%operator%' ORDER BY 2;
          SELECT 'listed', g.domain FROM gravity g JOIN adlist a ON a.id = g.adlist_id WHERE a.address LIKE '%operator%' ORDER BY 2;"
}

t_pihole_lists_survive_restart_image_switch_and_back() {
  local vol="nd-test-lt-$RUN_ID-lists" want seed_allow seed_lists ops
  podman volume rm -f "$vol" >/dev/null 2>&1
  podman volume create "$vol" >/dev/null 2>&1 || fail "cannot create the test volume"
  trap 'tp_cleanup; podman volume rm -f "'"$vol"'" >/dev/null 2>&1' EXIT
  seed_allow="$(grep -vE '^[[:space:]]*(#|$)' "$NICE_DNS_ROOT/pihole/custom-allowlist.txt" | head -n 1)"
  seed_lists="$(grep -cvE '^[[:space:]]*(#|$)' "$NICE_DNS_ROOT/pihole/adlists-default.txt")"

  lt_ph standard "$vol"
  # The operator's changes, through the admin API as the UI makes them; each
  # write must succeed (a discarded failure made this case flaky).
  lt_write -X POST --data '{"name":"ops"}' http://127.0.0.1/api/groups
  ops="$(printf '%s\n' "$LT_OUT" | sed -n 's/.*"name":"ops"[^}]*"id":\([0-9]*\).*/\1/p')"
  assert_match '^[0-9]+$' "$ops" "the group has an id: $LT_OUT"
  lt_write -X POST --data '{"domain":"operator-allow.example","comment":"op"}' http://127.0.0.1/api/domains/allow/exact
  lt_write -X POST --data "{\"domain\":\"operator-deny.example\",\"comment\":\"op\",\"groups\":[0,$ops]}" http://127.0.0.1/api/domains/deny/exact
  lt_write -X POST --data '{"domain":"(^|\\.)opregex\\.example$","comment":"op"}' http://127.0.0.1/api/domains/deny/regex
  lt_write -X POST --data "{\"client\":\"192.0.2.77\",\"comment\":\"op\",\"groups\":[$ops]}" http://127.0.0.1/api/clients
  lt_write -X POST --data '{"address":"https://lists.example/operator.txt","comment":"op"}' 'http://127.0.0.1/api/lists?type=block'
  # A downloaded list stands in for `pihole -g`, which needs the network. Pi-hole
  # may hold the database for a moment after an API write: retry, and check.
  local n=0
  until [ "$(lt_sql "INSERT INTO gravity (domain, adlist_id) SELECT 'operator-listed.example', id FROM adlist WHERE address = 'https://lists.example/operator.txt';
                     SELECT COUNT(*) FROM gravity WHERE domain = 'operator-listed.example';")" = 1 ]; do
    n=$((n + 1)); [ "$n" -le 20 ] || fail "cannot write the downloaded list: $TP_OUT"; sleep 0.5
  done
  want="$(lt_operator_state)"
  assert_match 'operator-deny\.example' "$want" "the operator's rows were written"
  assert_match 'listed.operator-listed\.example' "$want" "and a list's downloaded domain"
  assert_match '192\.0\.2\.77.*ops' "$want" "and a client in a group"

  local step
  for step in "standard restart" "hardened switch" "standard back"; do
    tp_cleanup
    lt_ph "${step%% *}" "$vol"
    assert_eq "$want" "$(lt_operator_state)" "$step: the operator's lists are all there"
    assert_match '0\.0\.0\.0' "$(lt_dig operator-deny.example)" "$step: the operator's deny rule blocks"
    assert_match '0\.0\.0\.0' "$(lt_dig operator-listed.example)" "$step: the operator's list blocks"
    assert_match '0\.0\.0\.0' "$(lt_dig www.opregex.example)" "$step: the operator's regex blocks"
    assert_eq 1 "$(lt_sql "SELECT COUNT(*) FROM domainlist WHERE domain = '$seed_allow' AND type = 0")" "$step: the image's allowlist is present"
    assert_eq "$seed_lists" "$(lt_sql "SELECT COUNT(*) FROM adlist WHERE address NOT LIKE '%operator%'")" "$step: the image's blocklists are present"
    assert_eq "$(tp_pm exec "$TP_CTR" cat /usr/share/nice-dns/pihole/seed-id; printf '%s' "$TP_OUT")" \
      "$(tp_pm exec "$TP_CTR" cat "$LT_LISTS/seed-id"; printf '%s' "$TP_OUT")" "$step: the volume is on this image's seed"
    lt_api -X POST --data "{\"domain\":\"operator-added-$(printf '%s' "$step" | tr ' ' '-').example\"}" http://127.0.0.1/api/domains/deny/exact >/dev/null
    assert_match 'operator-added' "$(lt_sql "SELECT domain FROM domainlist WHERE domain LIKE 'operator-added-$(printf '%s' "$step" | tr ' ' '-')%'")" "$step: and the lists stay writable"
    want="$(lt_operator_state)"
  done
}

t_anchor_and_tor_volumes_keep_their_state() {
  local av="nd-test-lt-$RUN_ID-anchor" tv="nd-test-lt-$RUN_ID-tor" i
  podman volume rm -f "$av" "$tv" >/dev/null 2>&1
  { podman volume create "$av" && podman volume create "$tv"; } >/dev/null 2>&1 || fail "cannot create the test volumes"
  trap 'tp_cleanup; podman volume rm -f "'"$av"'" "'"$tv"'" >/dev/null 2>&1' EXIT
  ub_images
  TP_PFX="nd-test-tp-$RUN_ID-lt-anchor" TP_CTRS="" TP_SOCKS_WRAP="" TP_NSPID="" TP_SOCKS=""
  TP_IMG="$UB_IMG"
  tp_holder
  for i in 1 2; do
    tp_run "ub$i" -v "$av:/var/lib/unbound" "$UB_IMG"
    sleep 3
    assert_eq true "$(podman inspect -f '{{.State.Running}}' "$TP_CTR" 2>/dev/null)" "run $i: Unbound accepts the volume: $(podman logs "$TP_CTR" 2>&1 | tail -n 5)"
    tp_pm exec "$TP_CTR" sh -c 'ls /var/lib/unbound/root.key && id -un'
    assert_rc 0 "$TP_RC" "run $i: the anchor is in the volume: $TP_OUT"
    if [ "$i" = 1 ]; then
      tp_pm exec "$TP_CTR" sh -c 'echo kept >/var/lib/unbound/.nd-lt-marker'
      assert_rc 0 "$TP_RC" "Unbound's user writes the volume: $TP_OUT"
      podman rm -f -t 0 "$TP_CTR" >/dev/null 2>&1
    else
      tp_pm exec "$TP_CTR" cat /var/lib/unbound/.nd-lt-marker
      assert_eq kept "$TP_OUT" "a new container keeps what the old one wrote"
    fi
  done
  tp_cleanup
  tp_setup tor-socat
  TP_PFX="nd-test-tp-$RUN_ID-lt-tor"
  for i in 1 2; do
    tp_pm run --rm --health-interval=disable --network none -v "$tv:/app/data" --entrypoint /bin/sh "$TP_IMG" -c \
      'id -un; if [ -f /app/data/.nd-lt-marker ]; then cat /app/data/.nd-lt-marker; else echo kept >/app/data/.nd-lt-marker && echo wrote; fi'
    assert_rc 0 "$TP_RC" "run $i: the Tor image's user writes its data volume: $TP_OUT"
    if [ "$i" = 1 ]; then assert_match wrote "$TP_OUT" "run 1 writes"; else assert_match kept "$TP_OUT" "run 2 finds it"; fi
  done
}
