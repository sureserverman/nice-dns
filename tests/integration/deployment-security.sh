# shellcheck shell=bash
# Group integration/deployment-security (Sub-plan 4, Task 2.1; ARCH-06).
#
# Pi-hole admin authentication, listener exposure and runtime permissions for
# both images (--pihole standard,hardened | all) on both platforms
# (--platforms linux,macos | all). Sourced by tests/run.sh (assert_* helpers;
# NICE_DNS_ROOT, CASE_DIR, RUN_ID). Two halves:
#
#   Installers, in the installer fixture (tests/fixtures/install-fakes.sh):
#   every entrypoint provisions one private admin password per deployment
#   under ~/.local/state/nice-dns/secrets/pihole, keeps it across reinstalls,
#   refuses unsafe credential state before anything is interrupted, removes
#   it on uninstall, and never puts it in a command argument or its output.
#   Linux hands it to podman as a secret; macOS mounts its directory
#   read-only at /run/secrets, because Apple's `container` 1.4.1 cannot mount
#   a single file ("path ... is not a directory", mac target 2026-09-27).
#   Both images read it through WEBPASSWORD_FILE, Pi-hole's documented Docker
#   secret contract (https://docs.pi-hole.net/docker/configuration/).
#
#   Images, as real containers under Linux podman: the real
#   deb/persistent-podman.sh installs the flavor's quadlets, `quadlet -dryrun`
#   generates the units, and the candidate image runs with exactly the
#   generated secret, environment, capability and no-new-privileges flags in
#   a --network none namespace. The admin API must refuse anonymous and
#   wrong-password requests and accept the deployment password; pihole-FTL
#   runs non-root with only the declared capabilities, answers on :53 and
#   :80, listens on nothing else and can write its state; the password never
#   reaches a log, an argument or `podman inspect`. On macOS the same images
#   run under Apple's runtime; that is qualified live (Task 2.3). Here the
#   macOS cells check that both launch paths (the installer and the
#   start-container agent) pass the same secret mount, environment and
#   capabilities.
#
# Safety: test containers are named nd-test-tp-<run>-<case>-*, join a
# --network none namespace and publish nothing; the test secret is named
# nd-test-ds-<run>-*. The production pod, its secret and its images are never
# touched. Image builds are the declared bootstrap exception, as in
# tests/fixtures/pihole-image.sh.

. "$NICE_DNS_ROOT/tests/fixtures/install-fakes.sh"
# shellcheck source=tests/fixtures/transport.sh
. "$NICE_DNS_ROOT/tests/fixtures/transport.sh"
# shellcheck source=tests/fixtures/pihole-image.sh
. "$NICE_DNS_ROOT/tests/fixtures/pihole-image.sh"

DS_SECRET=nice-dns-pihole-webpassword
DS_FILE=pihole_webpassword
# The minimum each image was shown to need (Task 2.1 experiments, podman
# 5.8.1): the standard image's root entrypoint chowns, setcaps pihole-FTL,
# drops to the pihole user and signals it on stop; the hardened image starts
# as the pihole user with a file capability to bind :53 and :80.
DS_CAPS_STANDARD="CHOWN DAC_OVERRIDE FOWNER KILL NET_BIND_SERVICE SETFCAP SETGID SETPCAP SETUID"
DS_CAPS_HARDENED="NET_BIND_SERVICE"

ds_pihole() {
  local p="${NICE_DNS_OPT_PIHOLE:-all}" x out=""
  [ "$p" = all ] && { printf 'standard hardened\n'; return 0; }
  for x in $(printf '%s' "$p" | tr ',' ' '); do
    case "$x" in standard|hardened) out="$out $x" ;; *) fail "unknown --pihole value '$x' (all, standard, hardened)" ;; esac
  done
  printf '%s\n' "$out"
}
# ds_select: DS_CELLS, "platform:flavor" words; a narrower selection fails the
# cases that need an unselected cell (a missing cell is never green).
ds_select() {
  local p f plats fl
  plats="$(dt_platforms)" || exit 1
  fl="$(ds_pihole)" || exit 1
  DS_CELLS=""
  for p in $plats; do for f in $fl; do DS_CELLS="$DS_CELLS $p:$f"; done; done
  [ -n "$DS_CELLS" ] || fail "no cell selected"
}
ds_need() {
  case " $DS_CELLS " in *" $1 "*) ;; *) fail "cell $1 is not selected (--platforms ${NICE_DNS_OPT_PLATFORMS:-all} --pihole ${NICE_DNS_OPT_PIHOLE:-all}); an unselected cell is not a pass" ;; esac
}
ds_ep() {
  local e
  if [ "${1%%:*}" = linux ]; then e=install-deb; else e=install-mac; fi
  if [ "${1#*:}" = hardened ]; then printf '%s-hardened\n' "$e"; else printf '%s\n' "$e"; fi
}

ds_secret_dir() { printf '%s/.local/state/nice-dns/secrets/pihole\n' "$IP_HOME"; }

# ds_leaks <password> <what>: the password appears nowhere in the world except
# its own file: not in any logged call, not in the installer's output, not in
# a manifest, receipt or unit.
ds_leaks() {
  local pw="$1" what="$2" f
  assert_eq "" "$(grep -F -- "$pw" "$FAKE_LOG")" "$what: no logged command carries the password"
  assert_eq "" "$(printf '%s\n' "$IP_OUT" | grep -F -- "$pw")" "$what: the installer output does not print it"
  f="$(grep -rlF -- "$pw" "$IP_W" 2>/dev/null | grep -vxF "$(ds_secret_dir)/$DS_FILE")"
  assert_eq "" "$f" "$what: no other file holds it"
}

# ─────────────────────────── installers (fixture) ───────────────────────────

t_installers_provision_a_private_credential() {
  local c ep pw first d
  ds_select
  for c in $DS_CELLS; do
    (
      ep="$(ds_ep "$c")"
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      ip_install "$ep" socat
      assert_rc 0 "$IP_RC" "$c: install: $IP_OUT"
      d="$(ds_secret_dir)"
      assert_file "$d/$DS_FILE" "$c: the admin password file exists"
      [ -L "$d" ] && fail "$c: the secret directory is a symlink"
      assert_eq 700 "$(ip_mode "$d")" "$c: the secret directory is private"
      assert_eq 600 "$(ip_mode "$d/$DS_FILE")" "$c: the password file is private"
      assert_eq "$DS_FILE" "$(ls -A "$d")" "$c: the mounted directory holds only the password"
      pw="$(cat "$d/$DS_FILE")"
      assert_match '^[A-Za-z0-9]{32,}$' "$pw" "$c: a long random password, one line"
      assert_match "$(printf 'credential\tpihole-admin\t')" "$(cat "$(ip_manifest "$(ip_gen_current)")")" "$c: the manifest records the credential (by path)"
      assert_match "$d/$DS_FILE" "$IP_OUT" "$c: the installer says where the password is"
      ds_leaks "$pw" "$c"
      if [ "${c%%:*}" = linux ]; then
        assert_match "^persistent-podman\\.sh socat ${c#*:}\$" "$(cat "$FAKE_LOG")" "$c: the quadlets are installed for this image (its capability drop-in)"
        assert_match "^podman secret create --replace $DS_SECRET $d/$DS_FILE\$" "$(cat "$FAKE_LOG")" "$c: podman gets the password as a secret, by file"
        assert_ne "" "$(ip_first "$FAKE_LOG" "^podman secret create ")" "$c: (secret created)"
        [ -z "$(ip_first "$FAKE_LOG" "$IP_DISRUPTIVE")" ] || [ "$(ip_first "$FAKE_LOG" "^podman secret create ")" -lt "$(ip_first "$FAKE_LOG" "$IP_DISRUPTIVE")" ] \
          || fail "$c: the secret is in place before the stack is interrupted"
      else
        assert_match "^container run -d --name pi-hole .* -v $d:/run/secrets:ro .*-e WEBPASSWORD_FILE=$DS_FILE " "$(cat "$FAKE_LOG")" "$c: Pi-hole mounts the secret directory read-only and names the file"
      fi
      printf '%s\n' "$pw" >"$CASE_DIR/pw-$c"
    ) || exit 1
  done
  # One password per deployment: two worlds never share one.
  for c in $DS_CELLS; do
    [ -n "${first:-}" ] && assert_ne "$first" "$(cat "$CASE_DIR/pw-$c")" "$c: a different deployment gets a different password"
    first="$(cat "$CASE_DIR/pw-$c")"
  done
}

t_reinstall_keeps_the_credential() {
  local c ep pw
  ds_select
  for c in $DS_CELLS; do
    (
      ep="$(ds_ep "$c")"
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      dt_installed "$ep"
      assert_file "$(ds_secret_dir)/$DS_FILE" "$c: the first install provisioned the password"
      pw="$(cat "$(ds_secret_dir)/$DS_FILE")"
      ip_install "$ep" haproxy
      assert_rc 0 "$IP_RC" "$c: reinstall (proxy switch): $IP_OUT"
      assert_eq "$pw" "$(cat "$(ds_secret_dir)/$DS_FILE")" "$c: the reinstall keeps the admin password"
      assert_match "$(printf 'credential\tpihole-admin\t[^\t]*\tkept')" "$(cat "$(ip_manifest "$(ip_gen_current)")")" "$c: and records it as kept"
      ds_leaks "$pw" "$c: reinstall"
    ) || exit 1
  done
}

t_unsafe_credential_state_is_refused() {
  local c ep d k before
  ds_select
  for c in $DS_CELLS; do
    for k in dir-symlink file-symlink empty two-lines foreign-mode; do
      (
        ep="$(ds_ep "$c")"
        dt_world "$ep" "$(dt_fresh_state "$ep")"
        d="$(ds_secret_dir)"
        mkdir -p "$IP_W/elsewhere" "$(dirname "$d")"
        printf 'decoy-not-ours\n' >"$IP_W/elsewhere/$DS_FILE"
        case "$k" in
          dir-symlink) ln -s "$IP_W/elsewhere" "$d" ;;
          file-symlink) mkdir -m 700 "$d"; ln -s "$IP_W/elsewhere/$DS_FILE" "$d/$DS_FILE" ;;
          empty) mkdir -m 700 "$d"; : >"$d/$DS_FILE"; chmod 600 "$d/$DS_FILE" ;;
          two-lines) mkdir -m 700 "$d"; printf 'abcdefghijklmnopqrstuvwxyz012345\nsecond\n' >"$d/$DS_FILE"; chmod 600 "$d/$DS_FILE" ;;
          foreign-mode) mkdir -m 700 "$d"; printf 'abcdefghijklmnopqrstuvwxyz012345\n' >"$d/$DS_FILE"; chmod 644 "$d/$DS_FILE" ;;
        esac
        before="$(ls -la "$d" "$IP_W/elsewhere" 2>/dev/null; cat "$d/$DS_FILE" "$IP_W/elsewhere/$DS_FILE" 2>/dev/null)"
        ip_install "$ep" socat
        assert_nonzero "$IP_RC" "$c/$k: refused: $IP_OUT"
        assert_match 'pihole_webpassword|secrets/pihole' "$IP_OUT" "$c/$k: the refusal names the credential"
        ip_assert_untouched "$c/$k"
        assert_eq "$before" "$(ls -la "$d" "$IP_W/elsewhere" 2>/dev/null; cat "$d/$DS_FILE" "$IP_W/elsewhere/$DS_FILE" 2>/dev/null)" "$c/$k: nothing was rewritten (a credential is never silently reset)"
        assert_eq "" "$(grep -E '^podman secret ' "$FAKE_LOG")" "$c/$k: no secret reached podman"
      ) || exit 1
    done
  done
}

t_uninstall_removes_the_credential() {
  local c ep
  ds_select
  for c in $DS_CELLS; do
    (
      ep="$(ds_ep "$c")"
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      dt_installed "$ep"
      assert_file "$(ds_secret_dir)/$DS_FILE" "$c: the install provisioned the password"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$c: uninstall: $IP_OUT"
      assert_no_path "$(ds_secret_dir)" "$c: the admin password is gone with the deployment"
      [ "${c%%:*}" = linux ] && assert_match "^podman secret rm $DS_SECRET\$" "$(cat "$FAKE_LOG")" "$c: and podman's copy"
      :
    ) || exit 1
  done
}

# The two macOS launch paths: the installer's first run (lib/install.sh) and
# the start-container agent's recreate (mac/start-container.sh) must start
# Pi-hole with the same arguments.
ds_mac_agent_args() {
  local f="$NICE_DNS_ROOT/mac/start-container.sh" snip
  snip="$(awk '/^PIHOLE_SECRET_DIR=/ { print } /^[[:space:]]*ensure_container pi-hole( |\\|$)/ { f = 1 } f { print } f && /pi-hole:latest/ { exit }' "$f")"
  [ -n "$snip" ] || fail "no Pi-hole launch in $f"
  env -i HOME="$IP_HOME" PATH="$PATH" bash -c 'ensure_container() { shift; printf "%s\n" "$@"; }; '"$snip"
}
t_macos_launch_paths_agree() {
  local c flav line got want
  ds_select
  for flav in standard hardened; do
    c="macos:$flav"
    ds_need "$c"
    (
      dt_world "$(ds_ep "$c")" fresh
      ip_install "$(ds_ep "$c")" socat
      assert_rc 0 "$IP_RC" "$c: install: $IP_OUT"
      line="$(grep -E '^container run -d --name pi-hole ' "$FAKE_LOG" | tail -n 1)"
      assert_ne "" "$line" "$c: the installer starts Pi-hole"
      got="$(printf '%s\n' "${line#container run -d --name pi-hole --network dnsnet }" | tr ' ' '\n')"
      want="$(ds_mac_agent_args)"
      assert_eq "$want" "$got" "$c: the agent recreates Pi-hole exactly as the installer started it"
      assert_match "^-v\$" "$got" "$c: (a mount)"
      assert_match "^$(ds_secret_dir):/run/secrets:ro\$" "$got" "$c: the secret directory, read-only"
      assert_match "^WEBPASSWORD_FILE=$DS_FILE\$" "$got" "$c: named for both images"
      assert_eq "--cap-drop ALL" "$(printf '%s\n' "$got" | awk '$0 == "--cap-drop" { getline v; print "--cap-drop " v }')" "$c: every capability dropped"
      assert_eq "$(for x in $DS_CAPS_STANDARD; do printf 'CAP_%s\n' "$x"; done)" \
        "$(printf '%s\n' "$got" | awk '$0 == "--cap-add" { getline v; print v }' | LC_ALL=C sort)" "$c: then only the proven set added back"
      assert_eq "" "$(printf '%s\n' "$got" | grep -E '^FTLCONF_webserver_api_password')" "$c: never the password itself in the environment"
    ) || exit 1
  done
}

# ─────────────────────────── images (real containers) ───────────────────────

# ds_quadlets <flavor>: the real deb/persistent-podman.sh in the installer
# fixture, as integration/installers-persistence runs it; DS_QDIR is the
# installed quadlet directory.
ds_quadlets() {
  local f
  dt_world install-deb resolved
  mkdir -p "$IP_W/real"
  for f in deb mac scripts health lib routes; do cp -R "$NICE_DNS_ROOT/$f" "$IP_W/real/"; done
  mkdir -p "$IP_W/run/systemd/generator" && : >"$IP_W/run/systemd/generator/nice-dns-pod.service"
  : >"$FAKE_ROOT/.systemd/NetworkManager-wait-online.unit"
  ip_run "$IP_W/real/deb/persistent-podman.sh" socat "$1"
  assert_rc 0 "$IP_RC" "persistent-podman.sh socat $1: $IP_OUT"
  DS_QDIR="$IP_HOME/.config/containers/systemd"
  assert_file "$DS_QDIR/pi-hole.container.d/50-nice-dns-caps.conf" "$1: the image's capability drop-in is installed"
  assert_eq "$(cat "$NICE_DNS_ROOT/deb/quadlet/pi-hole-$1.conf")" "$(cat "$DS_QDIR/pi-hole.container.d/50-nice-dns-caps.conf")" "$1: and it is this image's"
}

# ds_generated <unit>: the Exec lines of <unit> as quadlet generates them (a
# pod's --publish flags are on its ExecStartPre, `podman pod create`).
ds_generated() {
  local q
  for q in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet; do [ -x "$q" ] && break; done
  [ -x "$q" ] || fail "no quadlet generator on this host"
  QUADLET_UNIT_DIRS="$DS_QDIR" "$q" -dryrun -user 2>/dev/null \
    | awk -v u="---$1---" '$0 == u { f = 1; next } /^---.*---$/ { f = 0 } f && /^ExecStart(Pre)?=/ { sub(/^ExecStart(Pre)?=/, ""); print }'
}

# ds_flags <execstart>: the security-relevant flags, one "flag value" per line.
ds_flags() {
  printf '%s\n' "$1" | tr ' ' '\n' | awk '
    prev != "" { print prev " " $0; prev = ""; next }
    $0 == "--secret" || $0 == "--cap-drop" || $0 == "--cap-add" || $0 == "--env" || $0 == "--publish" || $0 == "-p" { prev = $0; next }
    $0 ~ /^--security-opt=/ { print "--security-opt " substr($0, 16) }
    $0 ~ /^--(secret|cap-drop|cap-add|env|publish)=/ { i = index($0, "="); print substr($0, 1, i - 1) " " substr($0, i + 1) }'
}

# ds_capmask <names...>: the kernel capability bitmask, lower-case hex, 16 digits.
ds_capmask() {
  local m=0 n b
  for n in "$@"; do
    case "$(printf '%s' "${n#CAP_}" | tr '[:lower:]' '[:upper:]')" in
      CHOWN) b=0 ;; DAC_OVERRIDE) b=1 ;; FOWNER) b=3 ;; FSETID) b=4 ;; KILL) b=5 ;; SETGID) b=6 ;;
      SETUID) b=7 ;; SETPCAP) b=8 ;; NET_BIND_SERVICE) b=10 ;; NET_RAW) b=13 ;; SYS_CHROOT) b=18 ;;
      MKNOD) b=27 ;; AUDIT_WRITE) b=29 ;; SETFCAP) b=31 ;;
      *) fail "ds_capmask: unknown capability $n" ;;
    esac
    m=$((m | (1 << b)))
  done
  printf '%016x\n' "$m"
}

ds_ftl_status() {
  # shellcheck disable=SC2016  # expanded in the container
  tp_pm exec "$1" sh -c 'for x in /proc/[0-9]*; do [ "$(cat "$x/comm" 2>/dev/null)" = pihole-FTL ] && { cat "$x/status"; exit 0; }; done; exit 1'
  printf '%s\n' "$TP_OUT"
}
ds_field() { printf '%s\n' "$2" | awk -v k="$1:" '$1 == k { print $2; exit }'; }

# ds_ports <ctr> <tcp|udp>: local ports under 1024 bound in the namespace
# (TCP: listening; UDP: unconnected). Ephemeral forwarding sockets are
# above 1023 and are not listeners.
ds_ports() {
  local f
  if [ "$2" = tcp ]; then f="/proc/net/tcp /proc/net/tcp6"; else f="/proc/net/udp /proc/net/udp6"; fi
  tp_pm exec "$1" sh -c "cat $f 2>/dev/null"
  printf '%s\n' "$TP_OUT" | awk -v p="$2" 'NR > 0 && $2 ~ /:/ && $1 ~ /^[0-9]+:$/ {
      split($2, a, ":"); split($3, r, ":")
      if (p == "tcp" && $4 != "0A") next
      if (p == "udp" && r[2] != "0000") next
      print a[2] }' | while IFS= read -r h; do printf '%d\n' "0x$h"; done | awk '$1 < 1024' | LC_ALL=C sort -n -u | tr '\n' ' ' | sed 's/ $//'
}

# ds_start <flavor> [podman run args]: the candidate image in a fresh namespace.
ds_start() {
  local flavor="$1"
  shift
  TP_PFX="nd-test-tp-$RUN_ID-$(basename "$CASE_DIR" | tr '_' '-')-$flavor"
  TP_CTRS="" TP_SOCKS_WRAP="" TP_NSPID="" TP_SOCKS=""
  ph_image "$flavor"
  TP_IMG="$PH_IMG"
  tp_holder
  tp_run ph "$@" -e TZ=Europe/London -e DISABLE_GITHUB_UPDATES=true "$PH_IMG"
}
ds_http() { tp_ns curl -s -m 5 -o /dev/null -w '%{http_code}' "$@"; printf '%s\n' "$TP_OUT"; }
ds_wait_web() {
  local i=0
  while [ "$(ds_http http://127.0.0.1/api/info/login)" != 200 ]; do
    i=$((i + 1))
    [ "$i" -le 180 ] || fail "Pi-hole ($1) never served its API: $(podman logs "$TP_CTR" 2>&1 | tail -n 15)"
    [ "$(podman inspect -f '{{.State.Running}}' "$TP_CTR" 2>/dev/null)" = true ] \
      || fail "Pi-hole ($1) exited: $(podman logs "$TP_CTR" 2>&1 | tail -n 15)"
    sleep 0.5
  done
}

t_images_enforce_the_deployment_password() {
  local flav c gen flags secret f pw sname st uid eff bnd want n ps
  ds_select
  for flav in standard hardened; do
    c="linux:$flav"
    ds_need "$c"
    (
      ds_quadlets "$flav"
      # Listener exposure: the pod publishes on the host loopback only.
      gen="$(ds_generated nice-dns-pod.service)"
      assert_ne "" "$gen" "$c: quadlet generates the pod"
      assert_eq "127.0.0.1:53:53/tcp 127.0.0.1:53:53/udp 127.0.0.1:8880:80" \
        "$(ds_flags "$gen" | awk '$1 == "--publish" || $1 == "-p" { print $2 }' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "$c: DNS and the admin UI are published on 127.0.0.1 only"
      gen="$(ds_generated pi-hole.service)"
      assert_ne "" "$gen" "$c: quadlet generates Pi-hole"
      flags="$(ds_flags "$gen")"
      secret="$(printf '%s\n' "$flags" | awk '$1 == "--secret" { print $2 }')"
      assert_match "^$DS_SECRET,type=mount,target=$DS_FILE,uid=1000,gid=1000,mode=0?400\$" "$secret" "$c: the deployment secret, readable by the pihole user only"
      assert_match "^--env WEBPASSWORD_FILE=$DS_FILE\$" "$flags" "$c: named through WEBPASSWORD_FILE"
      assert_not_match '^--env FTLCONF_webserver_api_password' "$flags" "$c: never the password itself"
      assert_eq "--cap-drop all" "$(printf '%s\n' "$flags" | awk '$1 == "--cap-drop"' | tr '[:upper:]' '[:lower:]')" "$c: every capability dropped"
      if [ "$flav" = standard ]; then want="$DS_CAPS_STANDARD"; else want="$DS_CAPS_HARDENED"; fi
      # shellcheck disable=SC2086,SC2046  # capability lists split on purpose
      assert_eq "$(ds_capmask $want)" "$(ds_capmask $(printf '%s\n' "$flags" | awk '$1 == "--cap-add" { print $2 }' | tr ',' ' '))" "$c: then only the proven set ($want)"
      if [ "$flav" = hardened ]; then
        assert_match '^--security-opt no-new-privileges' "$flags" "$c: no-new-privileges (proven with the port binding below)"
      else
        assert_not_match 'no-new-privileges' "$flags" "$c: no no-new-privileges: the entrypoint setcaps pihole-FTL"
      fi

      # The image, with exactly those flags and a test copy of the secret.
      pw="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
      ( umask 077 && printf '%s\n' "$pw" >"$CASE_DIR/pw-$flav" ) || fail "cannot write the test password"
      sname="nd-test-ds-$RUN_ID-$flav"
      podman secret rm "$sname" >/dev/null 2>&1
      podman secret create "$sname" "$CASE_DIR/pw-$flav" >/dev/null 2>&1 || fail "cannot create the test secret"
      trap 'tp_cleanup; podman secret rm "'"$sname"'" >/dev/null 2>&1' EXIT
      set --
      while IFS=' ' read -r f n; do
        case "$f" in
          --secret) set -- "$@" --secret "$sname,${n#*,}" ;;
          --env) case "$n" in WEBPASSWORD_FILE=*) set -- "$@" -e "$n" ;; esac ;;
          --cap-drop|--cap-add) set -- "$@" "$f" "$n" ;;
          --security-opt) set -- "$@" --security-opt "$n" ;;
        esac
      done <<EOF
$flags
EOF
      ds_start "$flav" "$@"
      ds_wait_web "$c"

      # Admin authentication, through the real API.
      assert_eq 401 "$(ds_http http://127.0.0.1/api/stats/summary)" "$c: an anonymous API request is refused"
      printf '{"password":"wrong-%s"}' "$RUN_ID" >"$CASE_DIR/auth-wrong.json"
      tp_ns curl -s -m 10 --data "@$CASE_DIR/auth-wrong.json" http://127.0.0.1/api/auth
      assert_match '"valid":false' "$TP_OUT" "$c: a wrong password is refused"
      ( umask 077 && printf '{"password":"%s"}' "$pw" >"$CASE_DIR/auth.json" ) || fail "cannot write the auth request"
      tp_ns curl -s -m 10 --data "@$CASE_DIR/auth.json" http://127.0.0.1/api/auth
      assert_match '"valid":true' "$TP_OUT" "$c: the deployment password opens a session"
      rm -f "$CASE_DIR/auth.json"

      # Port binding under those capabilities, and nothing else listening.
      tp_ns dig @127.0.0.1 -p 53 +time=3 +tries=1 pi.hole A
      assert_match 'status: NOERROR' "$TP_OUT" "$c: DNS answers on :53"
      assert_eq "53 80 443" "$(ds_ports "$TP_CTR" tcp)" "$c: TCP listeners are DNS and the admin UI only"
      assert_eq "53" "$(ds_ports "$TP_CTR" udp)" "$c: UDP listens on DNS only (no NTP server)"

      # Non-root, with only the declared capabilities, and writable state.
      st="$(ds_ftl_status "$TP_CTR")"
      uid="$(ds_field Uid "$st")"
      assert_match '^[1-9][0-9]*$' "$uid" "$c: pihole-FTL runs as a non-root user"
      bnd="$(ds_field CapBnd "$st")"
      # shellcheck disable=SC2086
      assert_eq "$(ds_capmask $want)" "$bnd" "$c: the bounding set is the declared one"
      eff="$(ds_field CapEff "$st")"
      assert_eq "$(ds_capmask NET_BIND_SERVICE)" "$(printf '%016x' $((0x$eff & 0x$(ds_capmask NET_BIND_SERVICE))))" "$c: pihole-FTL holds CAP_NET_BIND_SERVICE"
      assert_eq 0 "$((0x$eff & ~0x$bnd))" "$c: and nothing outside the bounding set"
      [ "$flav" = hardened ] && assert_eq 1 "$(ds_field NoNewPrivs "$st")" "$c: no-new-privileges holds for pihole-FTL"
      # shellcheck disable=SC2016
      tp_pm exec --user "$uid" "$TP_CTR" sh -c 'f=/etc/pihole/.nd-ds-write; : >"$f" && rm -f "$f"'
      assert_rc 0 "$TP_RC" "$c: pihole-FTL's user can write /etc/pihole: $TP_OUT"

      # The password reaches no log, argument or inspect output.
      assert_eq "" "$(podman logs "$TP_CTR" 2>&1 | grep -F -- "$pw")" "$c: not in the container log"
      assert_eq "" "$(podman logs "$TP_CTR" 2>&1 | grep -i 'random password')" "$c: no random password is printed"
      assert_eq "" "$(podman inspect "$TP_CTR" 2>&1 | grep -F -- "$pw")" "$c: not in podman inspect"
      tp_pm exec "$TP_CTR" sh -c 'cat /proc/[0-9]*/cmdline | tr "\0" " "'
      assert_eq "" "$(printf '%s\n' "$TP_OUT" | grep -F -- "$pw")" "$c: not in any process's arguments"
      ps="$(podman logs "$TP_CTR" 2>&1 | grep -ciE 'permission denied|operation not permitted' || true)"
      assert_eq 0 "$ps" "$c: the entrypoint hit no permission error under these capabilities: $(podman logs "$TP_CTR" 2>&1 | grep -iE 'permission denied|operation not permitted' | head -n 5)"
    ) || exit 1
  done
}

# The hardened image is also a published base for other consumers: without
# a configured password it must never serve an open admin API.
t_hardened_image_never_serves_an_open_admin() {
  local c=linux:hardened
  ds_select
  ds_need "$c"
  (
    # A subshell starts without the case's EXIT trap: without its own, a
    # failed assertion leaves the containers running.
    trap tp_cleanup EXIT
    ds_start hardened
    ds_wait_web "$c (no password configured)"
    assert_eq 401 "$(ds_http http://127.0.0.1/api/stats/summary)" "$c: with no password configured the API still requires one"
    assert_eq "" "$(podman logs "$TP_CTR" 2>&1 | grep -iE 'password: *[A-Za-z0-9]')" "$c: and the one it set is not printed"
    tp_cleanup
  ) || exit 1
}

# Both images: a named secret that is unusable stops the container rather
# than starting it with an empty password (upstream serves the admin API with
# no login then) or a random one printed to the log (upstream, missing file).
# The installer refuses these at install time, but the macOS agent recreates
# Pi-hole later from the live file.
t_images_refuse_an_unusable_secret() {
  local flav c i st
  ds_select
  for flav in standard hardened; do
    c="linux:$flav"
    ds_need "$c"
    # missing: no such file; a/b and . : not a name in /run/secrets; empty: a
    # readable file with nothing in it (an empty password means none at all).
    for i in missing 'a/b' '' empty; do
      (
        trap tp_cleanup EXIT
        if [ "$i" = empty ]; then
          # Readable by the pihole user: the directory too (the runner's umask
          # makes it 0700, and inside the container it belongs to root).
          mkdir -p "$CASE_DIR/empty-secret" && : >"$CASE_DIR/empty-secret/pw" && chmod 755 "$CASE_DIR/empty-secret" && chmod 644 "$CASE_DIR/empty-secret/pw"
          ds_start "$flav" -v "$CASE_DIR/empty-secret:/run/secrets:ro" -e WEBPASSWORD_FILE=pw
        else
          ds_start "$flav" -e "WEBPASSWORD_FILE=${i:-.}"
        fi
        st=""
        for _ in $(seq 1 60); do
          st="$(podman inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$TP_CTR" 2>/dev/null)"
          case "$st" in exited*) break ;; esac
          [ "$(ds_http http://127.0.0.1/api/info/login)" = 200 ] && fail "$c: WEBPASSWORD_FILE=${i:-.} (unusable) still served the admin API"
          sleep 0.5
        done
        assert_match '^exited [1-9]' "$st" "$c: WEBPASSWORD_FILE=${i:-.} it cannot use stops the container"
        assert_match 'WEBPASSWORD_FILE' "$(podman logs "$TP_CTR" 2>&1)" "$c: and says why"
        assert_eq "" "$(podman logs "$TP_CTR" 2>&1 | grep -i 'random password')" "$c: no random password is printed"
        tp_cleanup
      ) || exit 1
    done
  done
}
