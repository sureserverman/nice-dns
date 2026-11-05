# shellcheck shell=bash
# nice-dns recovery policy (ARCH-02 policy.sh, ARCH-03 decide, ARCH-04,
# ARCH-07). Sourced; Bash 3.2 compatible (macOS /bin/bash), safe under set -u.
#
#   nd_policy_decide <observations> <state> <now_epoch> <boot_id>
#
# Pure: it reads the three files with the shell's own `read` (the route table
# is ND_ROUTES_FILE, default routes/providers.tsv next to lib/), runs no
# command and writes nothing; lib/state.sh commits what it returns and
# lib/recovery.sh carries out the action. <observations> is lib/health.sh's
# output (nice-dns-observations/1); <state> is nd_state_load's output, or an
# empty file for a first run.
#
# stdout, tab-separated data:
#   schema  nice-dns-decision/1
#   action  no-op | switch-route | refresh-bridges | restart-component |
#           repair-runtime | escalate
#   target  a route id (switch-route), tor, proxy, unbound, pi-hole or stack
#           (restart-component), the runtime
#           fault (repair-runtime: runtime-down, containers-missing or
#           containers-paused), or -
#   reason  one line
# followed by the proposed next state (nice-dns-controller-state/1, without a
# generation row). Exit 0; 2 on a bad argument or route table.
# refresh-bridges is part of the vocabulary but no rule here selects it: the
# outage re-evaluation is health/nice-dns-health's refresh_bridges_on_outage
# (before the pass observes), and the daily one is its own schedule.
#
# Rules, in order (tunables in seconds unless noted):
#   * Unreadable observations escalate; the state is only time-stamped.
#   * A new boot restarts the startup allowance, the outage clock, the restart
#     count, the cooldown and every streak. A wall clock that moved back (now <
#     updated) restarts the allowance and the outage clock, and restarts the
#     cooldown at now (never shortens it).
#   * A fresh proxy (Sub-plan 5 Task 1.3, ARCH-04: an authenticated exit while
#     the onion is cold): a new boot, or a proxy observation whose generation
#     differs from the recorded proxy_gen (the first one seen included),
#     restarts every streak, and a selected *-onion route is dropped, so the
#     selection below takes the preferred healthy exit and the onion returns
#     only once sustained. An exit route stays selected. Measured on mint
#     2026-09-28: cold names after a restart took p50 691 ms on the kept onion
#     against 309 ms on the exit. No proxy record, or an indeterminate one,
#     is no evidence of a restart.
#   * Streaks: a healthy route observation adds to ok and clears fail, an
#     unhealthy one the reverse; an indeterminate or missing one changes
#     neither. unknown counts consecutive observations that were not healthy
#     (unhealthy, indeterminate or missing) and a healthy one clears it. Only
#     class "identity" routes count (DEC-005: the compat route is never
#     selected).
#   * runtime cli-missing escalates. runtime-down or containers-missing is
#     repaired (repair-runtime) after the startup allowance and outside the
#     cooldown, when the platform can repair it (ND_POLICY_RUNTIME_REPAIRS,
#     default both; the tick sets it from nd_platform_runtime_repairs);
#     otherwise it escalates. An indeterminate runtime is no evidence of a
#     fault.
#     After ND_POLICY_RUNTIME_REPAIR_MAX (3) repairs of containers-missing with
#     no healthy reading, whatever the routes say, the stack restarts: at once,
#     then every ND_POLICY_RETRY_S, escalating on the passes between. runtime-down
#     keeps its repair, because a stack restart needs the runtime.
#   * A paused container (a container:<name> record "paused restarts N") in
#     ND_POLICY_PAUSED_PASSES (2) consecutive passes, outside the cooldown, is
#     unpaused (repair-runtime containers-paused, the names in the reason), so a
#     deliberate short pause is not undone within a minute. A record of the
#     container running or failing otherwise clears its count; indeterminate or
#     absent holds it. Where the platform lists no such repair (macOS has no
#     pause) the policy escalates with the reason. It comes after the runtime
#     faults and before Unbound's and Pi-hole's rules, whose checks a paused
#     container fails too. After ND_POLICY_PAUSED_MAX_REPAIRS (2) unpauses with a
#     container still read paused, the unpause retries every ND_POLICY_RETRY_S;
#     the passes between leave the other rules free to act (a Pi-hole or stack
#     restart recreates the container) and escalate when nothing else acts.
#     paused_repairs counts them; a pass with no container read paused and one
#     read otherwise clears it.
#   * A crash loop is held, not fought. Each container:<name> record ends with
#     the unit's restart count ("restarts N"; Linux NRestarts). A count above the
#     last one kept (restart_seen_<c>) is a restart that already happened: the
#     cooldown restarts from it, and while a rise is under ND_POLICY_CRASH_WINDOW_S
#     (600) old nothing restarts that container (pi-hole: pi-hole; unbound:
#     unbound; the proxy: tor and proxy; any: the stack, and a containers-missing
#     start of it). ND_POLICY_CRASH_BURST (3) rises inside the window escalate
#     "crash-loop: <c>", at most once per ND_POLICY_RETRY_S; the first escalation
#     of a loop says so and the CLI writes one failure dump for it. A count stable
#     for the window clears the loop. A lower count (a manual start resets
#     NRestarts), a first reading and a new boot are baselines, never rises. The
#     unit's own back-off (RestartSteps=) is what slows the loop on Linux; Apple
#     containers do not restart themselves, so on macOS the count stays 0 and the
#     repair cap is the back-off.
#   * Unbound's own health, after runtime faults and before route selection. An
#     unbound observation with a control: reason counts always; a route: reason
#     counts only with an identity route healthy in the same pass, since otherwise
#     the probe is telling the truth about the upstream. Indeterminate or absent
#     changes nothing and acts on nothing. Healthy clears unbound_fail, and clears
#     unbound_restarts once ND_POLICY_RETRY_S has passed since the last restart. At
#     ND_POLICY_UNBOUND_FAILS (3) in a row, outside the startup allowance and the
#     cooldown, Unbound restarts (target unbound). After
#     ND_POLICY_UNBOUND_MAX_RESTARTS (2) it retries every ND_POLICY_RETRY_S (1800).
#     Past the ladder's cap in a full outage the stack restart covers it instead.
#     The controller owns this restart: no quadlet restarts on health, since a
#     health-triggered restart looped and wiped Tor's bootstrap.
#   * Pi-hole's own health, after Unbound's and in the same shape (DEC-021). A
#     pass fails Pi-hole when container:pi-hole or local-service is unhealthy; it
#     is healthy when neither is unhealthy and one is healthy. Indeterminate or
#     absent changes nothing and acts on nothing. Healthy clears pihole_fail, and
#     clears pihole_restarts once ND_POLICY_RETRY_S has passed since the last
#     restart. At ND_POLICY_PIHOLE_FAILS (3) in a row, outside the startup
#     allowance and the cooldown, Pi-hole restarts (target pi-hole). After
#     ND_POLICY_PIHOLE_MAX_RESTARTS (2) it retries every ND_POLICY_RETRY_S. Past
#     the ladder's cap in a full outage the stack restart covers it instead. The
#     controller owns this restart on both platforms: pi-hole.container is
#     HealthOnFailure=none.
#   * Route selection, when an identity route is healthy: the current route
#     stays while its fail streak is under ND_POLICY_DEMOTE (2) and its
#     unknown streak under ND_POLICY_STALE (5): a route without evidence is
#     not kept for ever. A route healthy in this observation with a healthy
#     streak of ND_POLICY_PROMOTE (5) that is preferred to it (table order) is
#     promoted; an old streak is not current evidence. Without a usable current route the most preferred
#     sustained route is chosen, else the most preferred healthy one with
#     routes named *-onion last: the onion is used only once sustained.
#   * A healthy identity or compat route means Tor works: the outage clock
#     clears and Tor is never restarted.
#   * Full outage: no route healthy and at least one identity route
#     unhealthy. Indeterminate-only observations hold the clock but never
#     act: a restart needs the outage observed in the same pass. Tor is
#     restarted once the outage has lasted ND_POLICY_GRACE_S (300) counted
#     from the later of its start and the end of the startup allowance
#     (ND_POLICY_STARTUP_S, 120), outside the cooldown (ND_POLICY_COOLDOWN_S,
#     300 after the last restart or repair), at most ND_POLICY_MAX_RESTARTS (2)
#     times per outage. Past that the whole stack restarts (target stack) every
#     ND_POLICY_RETRY_S, and the passes between escalate: DEC-021 replaced the
#     end of DEC-007's ladder, where it only escalated and a host stayed without
#     DNS until a reboot. The first restart of an outage is
#     Tor's (target tor: the image's in-image restart, falling back to the
#     service); a later one is the proxy's (target proxy: the service restart
#     directly), since the outage outlived a Tor restart. That later step also
#     waits ND_POLICY_LADDER_S (660) after the first: the first restart's
#     readiness window (lib/recovery.sh ND_RECOVERY_READY_S, 600 s from the
#     acknowledgement) plus a minute for the acknowledgement, so it never
#     lands on a Tor that is still bootstrapping.

ND_POLICY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

_nd_p_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 15 ]; }

nd_policy_decide() {
  local obs="${1:-}" stf="${2:-}" now="${3:-}" boot="${4:-}"
  local startup="${ND_POLICY_STARTUP_S:-120}" grace="${ND_POLICY_GRACE_S:-300}" cool="${ND_POLICY_COOLDOWN_S:-300}"
  local promote="${ND_POLICY_PROMOTE:-5}" demote="${ND_POLICY_DEMOTE:-2}" maxr="${ND_POLICY_MAX_RESTARTS:-2}"
  local stale="${ND_POLICY_STALE:-5}" ladder="${ND_POLICY_LADDER_S:-660}"
  local ubfails="${ND_POLICY_UNBOUND_FAILS:-3}" ubmax="${ND_POLICY_UNBOUND_MAX_RESTARTS:-2}" retry="${ND_POLICY_RETRY_S:-1800}"
  local rtmax="${ND_POLICY_RUNTIME_REPAIR_MAX:-3}" s_rtrep=0
  local repairs=" ${ND_POLICY_RUNTIME_REPAIRS:-runtime-down containers-missing containers-paused} "
  local routes="${ND_ROUTES_FILE:-$ND_POLICY_LIB_DIR/../routes/providers.tsv}"
  local tab=$'\t' cr=$'\r' a b c d e rest i j n=0 v
  local -a rid=() rok=() rfail=() runk=() robs=()
  local s_boot=- s_updated=- s_started=- s_route=- s_out=- s_rest=0 s_la=- s_laat=- s_rec=- s_pgen=- p_gen="" fresh=0
  local s_ubfail=0 s_ubrest=0 ub=- ub_reason="" ub_due=0
  local phfails="${ND_POLICY_PIHOLE_FAILS:-3}" phmax="${ND_POLICY_PIHOLE_MAX_RESTARTS:-2}"
  local s_phfail=0 s_phrest=0 ph_ct=- ph_ls=- ph_reason="" ph_due=0
  local pzpasses="${ND_POLICY_PAUSED_PASSES:-2}" pzmax="${ND_POLICY_PAUSED_MAX_REPAIRS:-2}" pz_names="" pz="" s_pzrep=0 pz_any=0 pz_read=0
  # The stack's containers (the observation validator's names), their paused
  # counts and this pass's reading: p paused, r running or failing otherwise.
  local -a cn=(pi-hole unbound tor-haproxy tor-socat) cpz=(0 0 0 0) cobs=(- - - -)
  # Crash loops: the last count kept, this pass's count, the rise epochs inside
  # the window ("e1,e2"), the last escalation.
  local cwin="${ND_POLICY_CRASH_WINDOW_S:-600}" cburst="${ND_POLICY_CRASH_BURST:-3}"
  local -a cseen=(0 0 0 0) ccnt=(- - - -) crise=(- - - -) cesc=(- - - -) crn=(0 0 0 0)
  local held=" " cr_due=-1 cr_first=0 boot_new=0
  local rt=- rt_reason="" compat_ok=0 valid=1 why="" notes=""
  local action=no-op target=- reason=""

  _nd_p_num "$now" || { printf 'policy: now must be an epoch, got %s\n' "$now" >&2; return 2; }
  case "$boot" in ''|*[!A-Za-z0-9._-]*) printf 'policy: bad boot id %s\n' "$boot" >&2; return 2 ;; esac
  [ "${#boot}" -le 64 ] || { printf 'policy: boot id longer than 64 characters\n' >&2; return 2; }
  [ -r "$obs" ] && [ -r "$stf" ] && [ -r "$routes" ] || { printf 'policy: unreadable input\n' >&2; return 2; }

  # Identity routes, in table order (preference order).
  local compat_ids=" "
  while IFS="$tab" read -r a b c d e rest || [ -n "$a" ]; do
    case "$a" in ''|'#'*|schema) continue ;; esac
    # Route ids as lib/state.sh accepts them (it validates the next state).
    case "$a" in *[!a-z0-9-]*|-*|*-|*--*) printf 'policy: bad route id %s\n' "$a" >&2; return 2 ;; esac
    [ "${#a}" -le 64 ] || { printf 'policy: route id %s is too long\n' "$a" >&2; return 2; }
    case "$e" in
      identity) rid[n]="$a"; rok[n]=0; rfail[n]=0; runk[n]=0; robs[n]=-; n=$((n + 1)) ;;
      compat) compat_ids="$compat_ids$a " ;;
      *) printf 'policy: bad route table row %s\n' "$a" >&2; return 2 ;;
    esac
  done <"$routes"
  [ "$n" -gt 0 ] || { printf 'policy: no identity route in %s\n' "$routes" >&2; return 2; }

  # Prior state (validated by nd_state_load; unknown rows are ignored). An
  # empty file is a first run; anything else must carry the state schema.
  if [ -s "$stf" ]; then
    IFS= read -r v <"$stf" || v=""
    [ "$v" = "schema${tab}nice-dns-controller-state/1" ] || { printf 'policy: %s is not controller state\n' "$stf" >&2; return 2; }
  fi
  while IFS="$tab" read -r a b c d e rest || [ -n "$a" ]; do
    case "$a" in
      boot_id) s_boot="$b" ;; updated) s_updated="$b" ;; started) s_started="$b" ;;
      route) s_route="$b" ;; outage_since) s_out="$b" ;; outage_restarts) s_rest="$b" ;;
      proxy_gen) s_pgen="$b" ;;
      unbound_fail) s_ubfail="$b" ;; unbound_restarts) s_ubrest="$b" ;; runtime_repairs) s_rtrep="$b" ;;
      pihole_fail) s_phfail="$b" ;; pihole_restarts) s_phrest="$b" ;; paused_repairs) s_pzrep="$b" ;;
      restart_seen_*|crash_esc_*|crash_*)
        i=0
        while [ "$i" -lt 4 ]; do
          case "$a" in
            "restart_seen_${cn[i]}") _nd_p_num "$b" && cseen[i]="$b" ;;
            "crash_esc_${cn[i]}") _nd_p_num "$b" && cesc[i]="$b" ;;
            "crash_${cn[i]}") case "$b" in ''|*[!0-9,]*|,*|*,|*,,*) ;; *) crise[i]="$b" ;; esac ;;
          esac
          i=$((i + 1))
        done ;;
      paused_*)
        i=0
        while [ "$i" -lt 4 ]; do
          [ "paused_${cn[i]}" = "$a" ] && _nd_p_num "$b" && cpz[i]="$b"
          i=$((i + 1))
        done ;;
      last_action) s_la="$b" ;; last_action_at) s_laat="$b" ;; recovery_at) s_rec="$b" ;;
      streak)
        i=0
        while [ "$i" -lt "$n" ]; do
          if [ "${rid[i]}" = "$b" ] && _nd_p_num "$c" && _nd_p_num "$d" && _nd_p_num "$e"; then rok[i]="$c"; rfail[i]="$d"; runk[i]="$e"; fi
          i=$((i + 1))
        done ;;
    esac
  done <"$stf"
  _nd_p_num "$s_rest" || s_rest=0
  _nd_p_num "$s_ubfail" || s_ubfail=0
  _nd_p_num "$s_ubrest" || s_ubrest=0
  _nd_p_num "$s_phfail" || s_phfail=0
  _nd_p_num "$s_phrest" || s_phrest=0
  _nd_p_num "$s_pzrep" || s_pzrep=0

  # Observations.
  local first=1
  while IFS= read -r v || [ -n "$v" ]; do
    case "$v" in *"$cr"*) valid=0; why="carriage return in observations"; break ;; esac
    if [ "$first" = 1 ]; then
      first=0
      [ "$v" = "schema${tab}nice-dns-observations/1" ] || { valid=0; why="observations lack the nice-dns-observations/1 schema"; break; }
      continue
    fi
    # Split on tabs by expansion (a here-document would write a temp file).
    a="" b="" c="" d="" e="" rest="" j=0 i="$v"
    while :; do
      case "$i" in *"$tab"*) v="${i%%"$tab"*}"; i="${i#*"$tab"}" ;; *) v="$i"; i="" ;; esac
      case "$j" in 0) a="$v" ;; 1) b="$v" ;; 2) c="$v" ;; 3) d="$v" ;; 4) e="$v" ;; *) rest=x ;; esac
      j=$((j + 1))
      [ -n "$i" ] || break
    done
    if [ "$a" != obs ] || [ "$j" -ne 5 ] || [ -z "$e" ]; then valid=0; why="malformed observation line"; break; fi
    case "$c" in healthy|unhealthy|indeterminate) ;; *) valid=0; why="unknown observation state '$c' for $b"; break ;; esac
    case "$b" in
      runtime) rt="$c"; rt_reason="$e" ;;
      proxy) case "$c:$e" in healthy:generation:*) p_gen="${e#generation:}" ;; esac ;;
      unbound) ub="$c"; ub_reason="$e" ;;
      container:pi-hole) ph_ct="$c"; [ "$c" != unhealthy ] || ph_reason="container: $e" ;;
      local-service) ph_ls="$c"; [ "$c" != unhealthy ] || [ -n "$ph_reason" ] || ph_reason="local-service: $e" ;;
    esac
    case "$b" in
      container:*)
        i=0
        while [ "$i" -lt 4 ]; do
          if [ "container:${cn[i]}" = "$b" ]; then
            # The count is the reason's last word (a check output may hold "restarts").
            v="${e##* restarts }"
            [ "$v" != "$e" ] && _nd_p_num "$v" && ccnt[i]="$v"
            case "$c:$e" in
              "unhealthy:paused restarts "*) cobs[i]=p ;;
              indeterminate:*) ;;
              *) cobs[i]=r ;;
            esac
          fi
          i=$((i + 1))
        done ;;
      route:*)
        i=0
        while [ "$i" -lt "$n" ]; do
          [ "route:${rid[i]}" = "$b" ] && robs[i]="$c"
          i=$((i + 1))
        done
        case "$compat_ids" in *" ${b#route:} "*) [ "$c" = healthy ] && compat_ok=1 ;; esac ;;
    esac
  done <"$obs"
  [ "$first" = 0 ] || { valid=0; why="empty observations"; }

  # Boot and clock.
  if [ "$s_boot" != "$boot" ]; then
    [ "$s_boot" = - ] || notes="boot changed; timers restart; "
    s_boot="$boot" s_started="$now" s_out=- s_rest=0 s_rec=- s_laat=- s_ubfail=0 s_ubrest=0 s_phfail=0 s_phrest=0
    cpz=(0 0 0 0) cseen=(0 0 0 0) crise=(- - - -) cesc=(- - - -) boot_new=1 s_pzrep=0
    [ "$s_la" = - ] || s_la=-
    i=0; while [ "$i" -lt "$n" ]; do rok[i]=0; rfail[i]=0; runk[i]=0; i=$((i + 1)); done
    fresh=1
  elif _nd_p_num "$s_updated" && [ "$now" -lt "$s_updated" ]; then
    notes="clock moved back; timers restart; "
    s_started="$now" s_out=-
    [ "$s_rec" = - ] || s_rec="$now"
  fi
  # A fresh proxy: its circuits are cold (see the rules above).
  # Exactly the shape lib/state.sh accepts (the tick acts before it commits,
  # so a value the commit refuses would desync the action from the state).
  case "$p_gen" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) p_gen="" ;; esac
  if [ -n "$p_gen" ] && [ "$p_gen" != "$s_pgen" ]; then
    notes="${notes}fresh proxy (generation $p_gen); streaks restart; "
    i=0; while [ "$i" -lt "$n" ]; do rok[i]=0; rfail[i]=0; runk[i]=0; i=$((i + 1)); done
    fresh=1
  fi
  [ -n "$p_gen" ] && s_pgen="$p_gen"
  if [ "$fresh" = 1 ]; then
    case "$s_route" in *-onion)
      notes="${notes}the onion is re-promoted once sustained (ARCH-04); "
      s_route=- ;;
    esac
  fi
  _nd_p_num "$s_started" || s_started="$now"
  s_updated="$now"

  if [ "$valid" = 0 ]; then
    action=escalate reason="${notes}observations unusable: $why"
  else
    # Streaks.
    local healthy_now=0 unhealthy_now=0
    i=0
    while [ "$i" -lt "$n" ]; do
      case "${robs[i]}" in
        healthy) rok[i]=$((rok[i] + 1)); rfail[i]=0; runk[i]=0; healthy_now=1 ;;
        unhealthy) rfail[i]=$((rfail[i] + 1)); rok[i]=0; runk[i]=$((runk[i] + 1)); unhealthy_now=1 ;;
        *) runk[i]=$((runk[i] + 1)) ;;
      esac
      i=$((i + 1))
    done
    # Restart counts: a rise is a restart the unit already made.
    local rises w k
    i=0
    while [ "$i" -lt 4 ]; do
      if [ "${ccnt[i]}" != - ]; then
        if [ "$boot_new" = 0 ] && [ "${ccnt[i]}" -gt "${cseen[i]}" ]; then
          if [ "${crise[i]}" = - ]; then crise[i]="$now"; else crise[i]="${crise[i]},$now"; fi
          s_rec="$now"
          notes="${notes}${cn[i]} restart count rose to ${ccnt[i]}; "
        fi
        cseen[i]="${ccnt[i]}"
      fi
      # Keep the rises inside the window (at most 8; a moved-back clock keeps them).
      rises="" k=0
      if [ "${crise[i]}" != - ]; then
        # Only digits and commas reach here (the load checks it), so the
        # unquoted split cannot glob.
        for w in ${crise[i]//,/ }; do
          if [ $((now - w)) -lt "$cwin" ]; then rises="$rises${rises:+,}$w"; k=$((k + 1)); fi
        done
      fi
      while [ "$k" -gt 8 ]; do rises="${rises#*,}"; k=$((k - 1)); done
      crn[i]="$k"
      if [ -z "$rises" ]; then
        crise[i]=- cesc[i]=-
      else
        crise[i]="$rises"
        case "${cn[i]}" in tor-*) held="${held}tor proxy stack ${cn[i]} " ;; *) held="${held}${cn[i]} stack " ;; esac
        if [ "$k" -ge "$cburst" ] && [ "$cr_due" -lt 0 ] \
           && { [ "${cesc[i]}" = - ] || [ $((now - cesc[i])) -ge "$retry" ] || [ "$now" -lt "${cesc[i]}" ]; }; then
          cr_due="$i"; [ "${cesc[i]}" = - ] && cr_first=1
        fi
      fi
      i=$((i + 1))
    done

    local in_startup=0 in_cool=0
    [ $((now - s_started)) -lt "$startup" ] && in_startup=1
    if _nd_p_num "$s_rec" && [ $((now - s_rec)) -lt "$cool" ]; then in_cool=1; fi

    if [ "$healthy_now" = 1 ] || [ "$compat_ok" = 1 ]; then
      s_out=- s_rest=0
    elif [ "$unhealthy_now" = 1 ] && [ "$s_out" = - ]; then
      s_out="$now"
    fi

    # Unbound's own health. A control failure is always its own; a route failure
    # is its own only while an identity route answers (Unbound never selects
    # compat), since otherwise the probe is telling the truth about the upstream.
    # Indeterminate or absent changes nothing and acts on nothing. A healthy
    # reading ends the streak; the restart count ends only a retry interval after
    # the last restart, or a flapping probe would defeat the cap.
    local ub_seen=0
    case "$ub:$ub_reason" in
      healthy:*)
        s_ubfail=0
        if ! _nd_p_num "$s_rec" || [ $((now - s_rec)) -ge "$retry" ]; then s_ubrest=0; fi ;;
      unhealthy:control:*) s_ubfail=$((s_ubfail + 1)) ub_seen=1 ;;
      unhealthy:route:*) if [ "$healthy_now" = 1 ]; then s_ubfail=$((s_ubfail + 1)) ub_seen=1; fi ;;
    esac
    if [ "$ub_seen" = 1 ] && [ "$s_ubfail" -ge "$ubfails" ]; then
      if [ "${held#* unbound }" != "$held" ]; then
        notes="${notes}Unbound failed $s_ubfail checks in a row; it is restarting on its own (crash-loop hold); "
      elif [ "$in_startup" = 1 ] || [ "$in_cool" = 1 ]; then
        notes="${notes}Unbound failed $s_ubfail checks in a row, inside the startup allowance or cooldown; "
      elif [ "$healthy_now" != 1 ] && [ "$unhealthy_now" = 1 ] && [ "$s_rest" -ge "$maxr" ]; then
        # Past the ladder's cap the stack restart below covers Unbound as well.
        # Both would be due at the same moment, and Unbound's would reset the timer.
        notes="${notes}Unbound failed $s_ubfail checks in a row; the stack restart covers it; "
      elif [ "$s_ubrest" -lt "$ubmax" ] || ! _nd_p_num "$s_rec" || [ $((now - s_rec)) -ge "$retry" ]; then
        ub_due=1
      else
        notes="${notes}Unbound failed $s_ubfail checks in a row after $s_ubrest restarts; next restart ${retry} s after the last ($((now - s_rec)) s so far); "
      fi
    fi

    # Paused containers: two passes in a row, then the unpause.
    i=0
    while [ "$i" -lt 4 ]; do
      case "${cobs[i]}" in p) cpz[i]=$((cpz[i] + 1)) pz_any=1 ;; r) cpz[i]=0 pz_read=1 ;; esac
      [ "${cobs[i]}" = p ] && [ "${cpz[i]}" -ge "$pzpasses" ] && pz_names="$pz_names${pz_names:+ }${cn[i]}"
      i=$((i + 1))
    done
    [ "$pz_any" = 1 ] || [ "$pz_read" = 0 ] || s_pzrep=0
    if [ -n "$pz_names" ]; then
      if [ "${repairs#* containers-paused }" = "$repairs" ]; then pz=escalate
      elif [ "$in_cool" = 1 ]; then notes="${notes}paused: $pz_names, inside the recovery cooldown; "
      elif [ "$s_pzrep" -lt "$pzmax" ] || ! _nd_p_num "$s_rec" || [ $((now - s_rec)) -ge "$retry" ]; then pz=repair
      else pz=held
      fi
    fi

    # Pi-hole's own health, the same shape as Unbound's: either record failing
    # counts, indeterminate or absent changes nothing.
    local ph_seen=0
    if [ "$ph_ct" = unhealthy ] || [ "$ph_ls" = unhealthy ]; then
      s_phfail=$((s_phfail + 1)) ph_seen=1
    elif [ "$ph_ct" = healthy ] || [ "$ph_ls" = healthy ]; then
      s_phfail=0
      if ! _nd_p_num "$s_rec" || [ $((now - s_rec)) -ge "$retry" ]; then s_phrest=0; fi
    fi
    if [ "$ph_seen" = 1 ] && [ "$s_phfail" -ge "$phfails" ]; then
      if [ "${held#* pi-hole }" != "$held" ]; then
        notes="${notes}Pi-hole failed $s_phfail checks in a row; it is restarting on its own (crash-loop hold); "
      elif [ "$in_startup" = 1 ] || [ "$in_cool" = 1 ]; then
        notes="${notes}Pi-hole failed $s_phfail checks in a row, inside the startup allowance or cooldown; "
      elif [ "$healthy_now" != 1 ] && [ "$unhealthy_now" = 1 ] && [ "$s_rest" -ge "$maxr" ]; then
        notes="${notes}Pi-hole failed $s_phfail checks in a row; the stack restart covers it; "
      elif [ "$s_phrest" -lt "$phmax" ] || ! _nd_p_num "$s_rec" || [ $((now - s_rec)) -ge "$retry" ]; then
        ph_due=1
      else
        notes="${notes}Pi-hole failed $s_phfail checks in a row after $s_phrest restarts; next restart ${retry} s after the last ($((now - s_rec)) s so far); "
      fi
    fi

    local rt_fault=""
    [ "$rt" != healthy ] || s_rtrep=0
    if [ "$rt" = unhealthy ]; then
      case "$rt_reason" in
        cli-missing:*) rt_fault=cli-missing ;;
        runtime-down:*) rt_fault=runtime-down ;;
        containers-missing:*) rt_fault=containers-missing ;;
      esac
    fi

    # A missing container that is restarting on its own is not started by name.
    local rt_held=""
    if [ "$rt_fault" = containers-missing ]; then
      for v in ${rt_reason#containers-missing: }; do
        case "$v" in "(running:"*) break ;; esac
        [ "${held#* "$v" }" = "$held" ] || rt_held="$rt_held${rt_held:+ }$v"
      done
    fi

    if [ "$rt_fault" = cli-missing ]; then
      action=escalate reason="runtime CLI is missing: $rt_reason"
    elif [ -n "$rt_fault" ] && [ "${repairs#* "$rt_fault" }" = "$repairs" ]; then
      action=escalate reason="runtime fault ($rt_fault) has no repair on this platform: $rt_reason"
    elif [ "$cr_due" -ge 0 ]; then
      v=""; [ "$cr_first" = 1 ] && v="; first escalation of this loop"
      # Leads with crash-loop: (the CLI's dump reads it there); the notes follow.
      action=escalate reason="crash-loop: ${cn[cr_due]} restarted ${crn[cr_due]} times in ${cwin} s (restarts ${cseen[cr_due]}); the controller adds no restart$v${notes:+; ${notes%; }}"
      cesc[cr_due]="$now" notes=""
    elif [ -n "$rt_held" ]; then
      reason="${notes}runtime fault ($rt_fault) held: $rt_held is restarting on its own (crash-loop hold)"; notes=""
    elif [ -n "$rt_fault" ]; then
      if [ "$in_startup" = 1 ]; then reason="runtime fault ($rt_fault) inside the startup allowance"
      elif [ "$in_cool" = 1 ]; then reason="runtime fault ($rt_fault) inside the recovery cooldown"
      elif [ "$rt_fault" = containers-missing ] && [ "$s_rtrep" -ge "$rtmax" ] && [ "$held" != " " ]; then
        reason="containers stay missing after $rtmax repairs; the stack restart is held: a container is restarting on its own (crash-loop hold:$held)"
      elif [ "$rt_fault" = containers-missing ] && [ "$s_rtrep" -ge "$rtmax" ]; then
        # Repairing by name for ever kept the stack restart below from ever being
        # due: each repair resets recovery_at. The first restart comes at once,
        # then one every $retry s, and the passes between journal the escalation.
        if [ "$s_rtrep" -eq "$rtmax" ] || ! _nd_p_num "$s_rec" || [ $((now - s_rec)) -ge "$retry" ]; then
          action=restart-component target=stack reason="containers stay missing after $rtmax repairs; restarting the stack: $rt_reason"
          s_rtrep=$((s_rtrep + 1)) s_rec="$now"
        else
          action=escalate reason="containers stay missing after $rtmax repairs and a stack restart; next stack restart $retry s after the last ($((now - s_rec)) s so far): $rt_reason"
        fi
      else
        action=repair-runtime target="$rt_fault" reason="runtime fault: $rt_reason"
        [ "$rt_fault" != containers-missing ] || s_rtrep=$((s_rtrep + 1))
      fi
    elif [ "$pz" = escalate ]; then
      action=escalate reason="${notes}paused: $pz_names; this platform has no unpause"
      notes=""
    elif [ "$pz" = repair ]; then
      action=repair-runtime target=containers-paused reason="containers-paused: $pz_names (paused $pzpasses passes or more)"
      s_pzrep=$((s_pzrep + 1))
    elif [ "$ub_due" = 1 ]; then
      action=restart-component target=unbound reason="Unbound failed $s_ubfail checks in a row: $ub_reason"
      s_ubfail=0 s_ubrest=$((s_ubrest + 1)) s_rec="$now"
    elif [ "$ph_due" = 1 ]; then
      action=restart-component target=pi-hole reason="Pi-hole failed $s_phfail checks in a row: $ph_reason"
      s_phfail=0 s_phrest=$((s_phrest + 1)) s_rec="$now"
    elif [ "$healthy_now" = 1 ]; then
      # Current route: an identity route whose fail streak is under demote.
      local cur=-1 best=-1 cand=-1
      i=0
      while [ "$i" -lt "$n" ]; do
        [ "${rid[i]}" = "$s_route" ] && [ "${rfail[i]}" -lt "$demote" ] && [ "${runk[i]}" -lt "$stale" ] && cur="$i"
        if [ "$best" -lt 0 ] && [ "${robs[i]}" = healthy ] && [ "${rok[i]}" -ge "$promote" ]; then best="$i"; fi
        i=$((i + 1))
      done
      if [ "$cur" -ge 0 ]; then
        if [ "$best" -ge 0 ] && [ "$best" -lt "$cur" ]; then
          action=switch-route target="${rid[best]}" reason="promote ${rid[best]} after ${rok[best]} healthy observations"
        else
          reason="route ${rid[cur]} stays selected"
        fi
      else
        if [ "$best" -ge 0 ]; then cand="$best"
        else
          for j in 0 1; do
            i=0
            while [ "$i" -lt "$n" ] && [ "$cand" -lt 0 ]; do
              case "${rid[i]}" in *-onion) v=1 ;; *) v=0 ;; esac
              [ "$v" = "$j" ] && [ "${robs[i]}" = healthy ] && cand="$i"
              i=$((i + 1))
            done
          done
        fi
        if [ "$s_route" = - ]; then v="no route selected"; else v="route $s_route is not usable"; fi
        action=switch-route target="${rid[cand]}" reason="$v; select ${rid[cand]}"
      fi
    elif [ "$compat_ok" = 1 ]; then
      reason="only the compat route answers: Tor works; the compat route is never selected (DEC-005)"
    elif [ "$s_out" = - ]; then
      reason="no identity route observed healthy or unhealthy"
    elif [ "$unhealthy_now" != 1 ]; then
      # A held outage clock is not current evidence: act only on a pass that
      # itself observed the outage.
      reason="outage since $s_out held; no route observed this pass, so nothing acts"
    else
      local from="$s_out"
      [ "$from" -lt $((s_started + startup)) ] && from=$((s_started + startup))
      if [ "$in_startup" = 1 ]; then reason="full outage inside the startup allowance"
      elif [ $((now - from)) -lt "$grace" ]; then reason="full outage for $((now - s_out)) s; grace $grace s"
      elif [ "$in_cool" = 1 ]; then reason="full outage; inside the recovery cooldown"
      elif [ "$held" != " " ] && { [ "$s_rest" -ge "$maxr" ] || [ "${held#* tor }" != "$held" ]; }; then
        reason="full outage; a container is restarting on its own (crash-loop hold:$held)"
      elif [ "$s_rest" -ge "$maxr" ]; then
        # Past the cap the ladder is spent, but stopping here left hosts without
        # DNS until a reboot (mint, 2026-10-30): the stack restarts every $retry s
        # and the passes between journal the escalation.
        if ! _nd_p_num "$s_rec" || [ $((now - s_rec)) -ge "$retry" ]; then
          action=restart-component target=stack reason="full outage since $s_out persists after $s_rest restarts; restarting the stack"
          s_rest=$((s_rest + 1)) s_rec="$now"
        else
          action=escalate reason="full outage persists after $s_rest restarts (tor, then proxy); next stack restart $retry s after the last ($((now - s_rec)) s so far)"
        fi
      elif [ "$s_rest" -ge 1 ] && _nd_p_num "$s_rec" && [ $((now - s_rec)) -lt "$ladder" ]; then
        reason="full outage; waiting out the last restart's readiness window ($((now - s_rec)) of $ladder s)"
      elif [ "$s_rest" -ge 1 ]; then
        # The outage outlasted an in-image restart: the fault is not Tor's
        # process, so the next step recreates the proxy (macOS: the stack).
        action=restart-component target=proxy reason="full outage since $s_out persists after a Tor restart; restarting the proxy service"
        s_rest=$((s_rest + 1)) s_rec="$now"
      else
        action=restart-component target=tor reason="full outage since $s_out; no identity route healthy"
        s_rest=$((s_rest + 1)) s_rec="$now"
      fi
    fi
    reason="$notes$reason"
    # Past the unpause cap, a pass no other rule acted on escalates.
    if [ "$pz" = held ] && [ "$action" = no-op ]; then
      action=escalate reason="paused: $pz_names stays paused after $s_pzrep unpauses; next unpause ${retry} s after the last ($((now - s_rec)) s so far); $reason"
    fi
  fi

  if [ "$action" != no-op ]; then s_la="$action" s_laat="$now"; fi
  [ "$action" = switch-route ] && s_route="$target"
  [ "$action" = repair-runtime ] && s_rec="$now"
  case "$reason" in *"$tab"*|*"$cr"*) reason="(reason withheld: control characters)" ;; esac

  printf 'schema\tnice-dns-decision/1\naction\t%s\ntarget\t%s\nreason\t%s\n' "$action" "$target" "$reason"
  printf 'schema\tnice-dns-controller-state/1\nboot_id\t%s\nupdated\t%s\nstarted\t%s\nroute\t%s\n' "$s_boot" "$s_updated" "$s_started" "$s_route"
  printf 'outage_since\t%s\noutage_restarts\t%s\nlast_action\t%s\nlast_action_at\t%s\nrecovery_at\t%s\nproxy_gen\t%s\n' "$s_out" "$s_rest" "$s_la" "$s_laat" "$s_rec" "$s_pgen"
  # Only when non-zero: a bundle from before these rows refuses them (BL-036).
  [ "$s_ubfail" = 0 ] || printf 'unbound_fail\t%s\n' "$s_ubfail"
  [ "$s_ubrest" = 0 ] || printf 'unbound_restarts\t%s\n' "$s_ubrest"
  [ "$s_rtrep" = 0 ] || printf 'runtime_repairs\t%s\n' "$s_rtrep"
  [ "$s_phfail" = 0 ] || printf 'pihole_fail\t%s\n' "$s_phfail"
  [ "$s_phrest" = 0 ] || printf 'pihole_restarts\t%s\n' "$s_phrest"
  [ "$s_pzrep" = 0 ] || printf 'paused_repairs\t%s\n' "$s_pzrep"
  i=0
  while [ "$i" -lt 4 ]; do
    [ "${cpz[i]}" = 0 ] || printf 'paused_%s\t%s\n' "${cn[i]}" "${cpz[i]}"
    [ "${cseen[i]}" = 0 ] || printf 'restart_seen_%s\t%s\n' "${cn[i]}" "${cseen[i]}"
    [ "${crise[i]}" = - ] || printf 'crash_%s\t%s\n' "${cn[i]}" "${crise[i]}"
    [ "${cesc[i]}" = - ] || printf 'crash_esc_%s\t%s\n' "${cn[i]}" "${cesc[i]}"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    printf 'streak\t%s\t%s\t%s\t%s\n' "${rid[i]}" "${rok[i]}" "${rfail[i]}" "${runk[i]}"
    i=$((i + 1))
  done
  return 0
}
