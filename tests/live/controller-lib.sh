# shellcheck shell=bash
# Shared helpers of the live controller groups (Sub-plan 3, Task 2.3):
# live/controller-shadow and live/controller-active. Sourced by the group
# file, which defines cs_dir <alias> (where that alias's evidence and
# ops.log go). Reports are tests/live/target.sh controller-report output:
# TSV sections ("section<TAB>name"), parsed here as data.

CS_TG="$NICE_DNS_ROOT/tests/live/target.sh"
# shellcheck disable=SC2034 # used by the groups that source this file
CS_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"

# cs_platforms: the selected platforms (cs_selection has validated them).
cs_platforms() {
  local p="${NICE_DNS_OPT_PLATFORMS:-all}"
  if [ "$p" = all ]; then printf 'linux macos\n'; else printf '%s\n' "$p" | tr ',' ' '; fi
}

# cs_alias <platform>: sets CS_ALIAS to the one target of that platform.
cs_alias() {
  local rows
  rows="$(bash "$CS_TG" validate --targets "$NICE_DNS_OPT_TARGETS" | awk -F '\t' -v p="$1" '$2 == p { print $1 }')"
  assert_eq 1 "$(printf '%s' "$rows" | grep -c .)" "exactly one $1 target in $NICE_DNS_OPT_TARGETS"
  # shellcheck disable=SC2034 # read by the caller
  CS_ALIAS="$rows"
}

# cs_t <alias> <op> [args]: one target operation, logged to the alias's ops.log.
cs_t() {
  local a="$1" op="$2"
  shift 2
  printf '== %s %s %s\n' "$(date -u +%H:%M:%S)" "$op" "$*" >>"$(cs_dir "$a")/ops.log"
  ARTIFACT_DIR="$ARTIFACT_DIR" RUN_ID="$RUN_ID" bash "$CS_TG" "$op" "$a" --targets "$NICE_DNS_OPT_TARGETS" "$@"
}

# cs_report <alias> <name>: controller-report into <dir>/<name>.tsv.
cs_report() {
  cs_t "$1" controller-report >"$(cs_dir "$1")/$2.tsv" 2>>"$(cs_dir "$1")/ops.log"
}

# cs_sec <file> <section>: the rows of one report section.
cs_sec() { awk -F '\t' -v s="$2" '$1 == "section" { on = ($2 == s); next } on' "$1"; }

cs_now() { awk -F '\t' '$1 == "now" { print $2; exit }' "$1"; }

cs_field() { cs_sec "$1" "$2" | awk -F '\t' -v k="$3" '$1 == k { print $2; exit }'; }

cs_proxy() { cs_sec "$1" proxy | awk -F '\t' '$1 == "proxy" { print $2; exit }'; }

cs_gen() { cs_sec "$1" proxy | awk -F '\t' '$1 == "proxy" { print $3; exit }'; }

cs_bridges() { cs_sec "$1" bridges | awk -F '\t' '$1 == "set" { print $2 "/" $3; exit }'; }

cs_obs() { cs_sec "$1" observe | awk -F '\t' -v n="$2" '$1 == "obs" && $2 == n { print $3; exit }'; }

cs_routes_healthy() { cs_sec "$1" observe | awk -F '\t' '$1 == "obs" && $2 ~ /^route:/ && $3 == "healthy"' | grep -c .; }

cs_routes_unhealthy() { cs_sec "$1" observe | awk -F '\t' '$1 == "obs" && $2 ~ /^route:/ && $3 != "healthy"' | grep -c .; }

cs_routes() { cs_sec "$1" observe | awk -F '\t' '$1 == "obs" && $2 ~ /^route:/' | grep -c .; }

# cs_ticks <report> <since>: "epoch mode action target result generation" of
# the TICK lines at or after <since> (the target's own clock).
cs_ticks() {
  python3 - "$1" "$2" <<'PY'
import datetime, sys
f, since = sys.argv[1], int(sys.argv[2])
sec = None
for line in open(f, encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if line.startswith("section\t"):
        sec = line.split("\t")[1]
        continue
    if sec != "ticks":
        continue
    p = line.split(" ")
    if len(p) < 3 or p[1] != "TICK":
        continue
    t = int(datetime.datetime.strptime(p[0], "%Y-%m-%dT%H:%M:%S%z").timestamp())
    if t < since:
        continue
    kv = dict(x.split("=", 1) for x in p[3:] if "=" in x)
    print(t, p[2], kv.get("action", "-"), kv.get("target", "-"), kv.get("result", "-"), kv.get("generation", "-"))
PY
}

# cs_wait <alias> <tag> <timeout_s> <predicate fn>: a report every 60 s until
# <predicate> <report> succeeds; the last report is <tag>.tsv.
cs_wait() {
  local a="$1" tag="$2" max="$3" fn="$4" t0
  t0="$(date +%s)"
  while :; do
    cs_report "$a" "$tag" || fail "$a: controller-report failed while waiting for $tag"
    "$fn" "$(cs_dir "$a")/$tag.tsv" && return 0
    [ $(( $(date +%s) - t0 )) -lt "$max" ] || return 1
    sleep 60
  done
}

cs_selection() {
  local x
  assert_eq "" "${NICE_DNS_TARGET_ADAPTER:-}" "live runs use the real guarded adapter"
  assert_ne "" "${NICE_DNS_OPT_TARGETS:-}" "--targets FILE"
  for x in $(cs_platforms); do
    case "$x" in linux|macos) ;; *) fail "unknown --platforms value '$x' (all, linux, macos)" ;; esac
  done
}

cs_clean() {
  # cs_clean <repo dir>: no change but the proxies' untracked local binary
  # (the image compiles bridge-eval from source).
  GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain | grep -v '^?? bridge-eval/bridge-eval$'
}

cs_route_up() { [ "$(cs_routes_healthy "$1")" -ge 1 ] && [ -n "$(cs_proxy "$1")" ]; }

# cs_jrows <report> <journal-active|journal-shadow> <since>: journal rows at
# or after <since> (epoch<TAB>id<TAB>component<TAB>phase<TAB>detail).
cs_jrows() { cs_sec "$1" "$2" | awk -F '\t' -v s="$3" '$1 ~ /^[0-9]+$/ && $1 >= s'; }
cs_sleeps() { cs_field "$1" power sleeps; }

# ca_up <report>: an answering route and Pi-hole's own name (the chain works).
ca_up() { cs_route_up "$1" && [ "$(cs_obs "$1" local-service)" = healthy ]; }

# cs_reuse_cell <platform/proxy/pihole>: DEC-009 (user decision 2026-09-27).
# NICE_DNS_CELL_REUSE_RUNS names earlier run directories (absolute, space
# separated, searched in the order given). Prints the first such run's cell
# directory whose cell.tsv names this cell and whose observations.tsv holds
# all six controller scenarios as passed; prints nothing when none does.
# Exit 2 when a named run is not an absolute directory.
cs_reuse_cell() {
  local k="$1" r d n
  for r in ${NICE_DNS_CELL_REUSE_RUNS:-}; do
    case "$r" in /*) ;; *) printf 'cs_reuse_cell: %s is not an absolute run directory\n' "$r" >&2; return 2 ;; esac
    [ -d "$r" ] || { printf 'cs_reuse_cell: no run directory %s\n' "$r" >&2; return 2; }
    d="$r/controller-active/$(printf '%s' "$k" | tr / -)"
    [ -f "$d/cell.tsv" ] && [ -f "$d/observations.tsv" ] || continue
    [ "$(awk -F '\t' '$1 == "cell" { print $2; exit }' "$d/cell.tsv")" = "$k" ] || continue
    n="$(awk -F '\t' '$2 == "pass" && $1 ~ /^CT-(PROBES|PRIMARY-ONLY|RECOVERY-ACK|CACHE-VS-UPSTREAM|RUNTIME-WEDGE|BRIDGES)$/ { s[$1] = 1 } END { print length(s) }' "$d/observations.tsv")"
    [ "$n" = 6 ] || continue
    printf '%s\n' "$d"
    return 0
  done
  return 0
}
