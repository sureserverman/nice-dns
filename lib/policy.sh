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
#   target  a route id (switch-route), tor (restart-component), the runtime
#           fault (repair-runtime), or -
#   reason  one line
# followed by the proposed next state (nice-dns-controller-state/1, without a
# generation row). Exit 0; 2 on a bad argument or route table.
# refresh-bridges is part of the vocabulary; no rule selects it yet (bridge
# application is Task 2.2's).
#
# Rules, in order (tunables in seconds unless noted):
#   * Unreadable observations escalate; the state is only time-stamped.
#   * A new boot restarts the startup allowance, the outage clock, the restart
#     count, the cooldown and every streak; the last route stays selected. A
#     wall clock that moved back (now < updated) restarts the allowance and
#     the outage clock, and restarts the cooldown at now (never shortens it).
#   * Streaks: a healthy route observation adds to ok and clears fail, an
#     unhealthy one the reverse; an indeterminate or missing one changes
#     neither. unknown counts consecutive observations that were not healthy
#     (unhealthy, indeterminate or missing) and a healthy one clears it. Only
#     class "identity" routes count (DEC-005: the compat route is never
#     selected).
#   * runtime cli-missing escalates. runtime-down or containers-missing is
#     repaired (repair-runtime) after the startup allowance and outside the
#     cooldown; an indeterminate runtime is no evidence of a fault.
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
#     times per outage; then it escalates.

ND_POLICY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

_nd_p_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 15 ]; }

nd_policy_decide() {
  local obs="${1:-}" stf="${2:-}" now="${3:-}" boot="${4:-}"
  local startup="${ND_POLICY_STARTUP_S:-120}" grace="${ND_POLICY_GRACE_S:-300}" cool="${ND_POLICY_COOLDOWN_S:-300}"
  local promote="${ND_POLICY_PROMOTE:-5}" demote="${ND_POLICY_DEMOTE:-2}" maxr="${ND_POLICY_MAX_RESTARTS:-2}"
  local stale="${ND_POLICY_STALE:-5}"
  local routes="${ND_ROUTES_FILE:-$ND_POLICY_LIB_DIR/../routes/providers.tsv}"
  local tab=$'\t' cr=$'\r' a b c d e rest i j n=0 v
  local -a rid=() rok=() rfail=() runk=() robs=()
  local s_boot=- s_updated=- s_started=- s_route=- s_out=- s_rest=0 s_la=- s_laat=- s_rec=-
  local rt=- rt_reason="" compat_ok=0 valid=1 why="" notes=""
  local action=no-op target=- reason=""

  _nd_p_num "$now" || { printf 'policy: now must be an epoch, got %s\n' "$now" >&2; return 2; }
  case "$boot" in ''|*[!A-Za-z0-9._-]*) printf 'policy: bad boot id %s\n' "$boot" >&2; return 2 ;; esac
  [ -r "$obs" ] && [ -r "$stf" ] && [ -r "$routes" ] || { printf 'policy: unreadable input\n' >&2; return 2; }

  # Identity routes, in table order (preference order).
  local compat_ids=" "
  while IFS="$tab" read -r a b c d e rest || [ -n "$a" ]; do
    case "$a" in ''|'#'*|schema) continue ;; esac
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
    s_boot="$boot" s_started="$now" s_out=- s_rest=0 s_rec=- s_laat=-
    [ "$s_la" = - ] || s_la=-
    i=0; while [ "$i" -lt "$n" ]; do rok[i]=0; rfail[i]=0; runk[i]=0; i=$((i + 1)); done
  elif _nd_p_num "$s_updated" && [ "$now" -lt "$s_updated" ]; then
    notes="clock moved back; timers restart; "
    s_started="$now" s_out=-
    [ "$s_rec" = - ] || s_rec="$now"
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
    local in_startup=0 in_cool=0
    [ $((now - s_started)) -lt "$startup" ] && in_startup=1
    if _nd_p_num "$s_rec" && [ $((now - s_rec)) -lt "$cool" ]; then in_cool=1; fi

    if [ "$healthy_now" = 1 ] || [ "$compat_ok" = 1 ]; then
      s_out=- s_rest=0
    elif [ "$unhealthy_now" = 1 ] && [ "$s_out" = - ]; then
      s_out="$now"
    fi

    local rt_fault=""
    if [ "$rt" = unhealthy ]; then
      case "$rt_reason" in
        cli-missing:*) rt_fault=cli-missing ;;
        runtime-down:*) rt_fault=runtime-down ;;
        containers-missing:*) rt_fault=containers-missing ;;
      esac
    fi

    if [ "$rt_fault" = cli-missing ]; then
      action=escalate reason="runtime CLI is missing: $rt_reason"
    elif [ -n "$rt_fault" ]; then
      if [ "$in_startup" = 1 ]; then reason="runtime fault ($rt_fault) inside the startup allowance"
      elif [ "$in_cool" = 1 ]; then reason="runtime fault ($rt_fault) inside the recovery cooldown"
      else action=repair-runtime target="$rt_fault" reason="runtime fault: $rt_reason"
      fi
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
      elif [ "$s_rest" -ge "$maxr" ]; then action=escalate reason="full outage persists after $s_rest Tor restarts"
      else
        action=restart-component target=tor reason="full outage since $s_out; no identity route healthy"
        s_rest=$((s_rest + 1)) s_rec="$now"
      fi
    fi
    reason="$notes$reason"
  fi

  if [ "$action" != no-op ]; then s_la="$action" s_laat="$now"; fi
  [ "$action" = switch-route ] && s_route="$target"
  [ "$action" = repair-runtime ] && s_rec="$now"
  case "$reason" in *"$tab"*|*"$cr"*) reason="(reason withheld: control characters)" ;; esac

  printf 'schema\tnice-dns-decision/1\naction\t%s\ntarget\t%s\nreason\t%s\n' "$action" "$target" "$reason"
  printf 'schema\tnice-dns-controller-state/1\nboot_id\t%s\nupdated\t%s\nstarted\t%s\nroute\t%s\n' "$s_boot" "$s_updated" "$s_started" "$s_route"
  printf 'outage_since\t%s\noutage_restarts\t%s\nlast_action\t%s\nlast_action_at\t%s\nrecovery_at\t%s\n' "$s_out" "$s_rest" "$s_la" "$s_laat" "$s_rec"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf 'streak\t%s\t%s\t%s\t%s\n' "${rid[i]}" "${rok[i]}" "${rfail[i]}" "${runk[i]}"
    i=$((i + 1))
  done
  return 0
}
