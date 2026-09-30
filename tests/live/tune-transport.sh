# shellcheck shell=bash
# Group live/tune-transport (Sub-plan 5, Task 1.4; ARCH-04, ARCH-07; DEC-012,
# DEC-014). Run with `tests/run.sh live tune-transport --live --targets FILE
# --platforms all --proxies all --comparison baseline`.
#
# The interleaved comparison of live/tune-resolver (same cell, arms, blocks,
# classes and comparator: cold, warm, restart), with the transport changes of
# this task in the candidate arm:
#
#   fix A  nice-dns: a fresh proxy starts Unbound on the exit route
#          (lib/recovery.sh start_route, run before every Unbound start)
#   fix B  the proxy image built on the target from the sibling checkout's
#          commit (target.sh build-proxy): readiness is a working stream, and
#          Tor's log is kept
#
# --proxies all: one representative cell per platform covers both proxies
# (linux/haproxy/standard, macos/socat/standard; DEC-012).
#
# The controller's schedules are quiesced during the blocks, so nothing
# promotes the onion and fix A would never act. Before each swap to the
# candidate arm the harness therefore leaves a persisted onion include
# (target.sh route-onion: what the controller leaves once the onion is
# sustained); the swap restarts the stack, and the candidate's restart sample
# is the first answer after a start that found a persisted onion. Each
# candidate block then asserts that Unbound runs the exit route (fix A acted)
# and records the proxy's readiness line (fix B). The baseline arm (b85bc9b)
# always starts on its exit backup, so the restart class shows "no worse
# than the baseline", not an improvement over it.
#
# The target ends on this checkout's deployment with the released, pinned
# proxy (the final reinstall pulls it again).
#
# Evidence: $ARTIFACT_DIR/tune-transport/<alias>/ (private).

TR_GROUP=tune-transport
# shellcheck source=tests/live/tune-resolver.sh
. "$NICE_DNS_ROOT/tests/live/tune-resolver.sh"

# tt_proxy_sha <proxy>: the sibling checkout's commit, which must be what its
# tracked files hold (build-proxy sends `git archive` of that commit).
tt_proxy_sha() {
  local r="$NICE_DNS_ROOT/../tor-$1"
  assert_eq "" "$(GIT_OPTIONAL_LOCKS=0 git -C "$r" status --porcelain --untracked-files=no)" "tor-$1 is committed (the archive is of its HEAD)"
  git -C "$r" rev-parse HEAD
}

tr_candidate_images() {
  local d
  d="$(il_dir "$1")"
  printf 'generation-of-%s+proxy-%s\n' "$(il_sha)" "$(awk -F '\t' '$1 == "proxy_sha" { print substr($2, 1, 12) }' "$d/cell.tsv")"
}

tr_hook_after_install() {
  local plat="$1" a="$2" proxy="$3" d sha
  d="$(il_dir "$a")"
  sha="$(tt_proxy_sha "$proxy")"
  printf 'proxy_sha\t%s\n' "$sha" >>"$d/cell.tsv"
  il_t "$a" build-proxy --component "tor-$proxy" --source-sha "$sha" >"$d/build-proxy.tsv" 2>>"$d/ops.log" \
    || fail "$a: build-proxy: $(tail -n 10 "$d/ops.log")"
  il_t "$a" recreate-proxy --component "tor-$proxy" >"$d/recreate-proxy.tsv" 2>>"$d/ops.log" \
    || fail "$a: recreate-proxy: $(tail -n 10 "$d/ops.log")"
  tr_dns_settled "$a" || fail "$a: the host resolver did not settle on the candidate proxy"
}

tr_hook_before_candidate() {
  local a="$1" k="$2" d
  d="$(il_dir "$a")"
  il_t "$a" route-onion >"$d/blocks/onion-$k.tsv" 2>>"$d/ops.log" || fail "$a: route-onion (block $k): $(tail -n 5 "$d/ops.log")"
  assert_eq "applied	cloudflare-onion" "$(awk -F '\t' '$1 == "result" || $1 == "route" { printf "%s%s", s, $2; s = "\t" }' "$d/blocks/onion-$k.tsv")" "$a: block $k: a persisted onion include before the swap"
}

tr_hook_after_candidate() {
  local a="$1" k="$2" d og ready
  d="$(il_dir "$a")"
  og="$(awk -F '\t' '$1 == "generation" { print $2 }' "$d/blocks/onion-$k.tsv")"
  # Fix A: the start found the onion persisted at generation og and a fresh
  # proxy, and Unbound runs the exit at the next generation.
  assert_eq "cloudflare-exit $((og + 1))" "$(awk -F '\t' '$1 == "readback" { split($2, f, " "); print f[1] " " f[2] }' "$d/blocks/route-$k.tsv")" \
    "$a: block $k: the start demoted the persisted onion (generation $og) to the exit"
  # Fix B: the candidate proxy reported readiness on a working stream.
  ready="$(awk -F '\t' '$1 == "proxy_ready" { print $2 }' "$d/blocks/set-candidate-$k.tsv")"
  printf 'block\t%s\t%s\n' "$k" "$ready" >>"$d/candidate-ready.tsv"
  assert_match 'bootstrapped after [0-9]+ s, a stream works after [0-9]+ s \((exit|onion)\)' "$ready" "$a: block $k: the candidate proxy logged its time to the first stream"
}

t_0_options() {
  assert_eq all "${NICE_DNS_OPT_PROXIES:-}" "--proxies all (one representative cell per platform covers both proxies)"
}
