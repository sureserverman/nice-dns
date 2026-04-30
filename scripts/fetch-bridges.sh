#!/usr/bin/env bash
#
# Fetch 3 distinct obfs4 bridges from the Tor Project's Moat API and write
# them as BRIDGE1..BRIDGE3 to ~/.config/nice-dns/bridges.env. The tor-haproxy
# and tor-socat containers consume that file via EnvironmentFile= (Linux
# quadlets) or `sed -n 's/^KEY=//p'` (install-mac.sh — bash `source` is unsafe
# on values with spaces and no quotes).
#
# Why exactly 3:
#   - ≥3 distinct primary guards are required for Tor 0.4.8+ to form Conflux
#     paths on onion-service traffic, which roughly halves cold-query latency
#     to the Cloudflare DoT .onion (measured ~700 ms vs ~1 s with 2 bridges).
#   - More than 3 (we tried all ~7 Moat returns) made cold-query latency
#     WORSE, not better: with NumPrimaryGuards 3 and a larger pool, Tor's
#     primary-guard rotation widens first-query variance enough to produce
#     multi-second timeouts in the first ~10 minutes. The theoretical
#     failover-via-reserves benefit is real but doesn't pay back the cost in
#     normal operation. start.sh accepts BRIDGE4+ for operators who want to
#     experiment, but we don't auto-fetch them.
#
# Idempotent: if the file already exists and contains ≥3 valid BRIDGE_i
# lines, the script exits 0 without touching anything. Re-fetch by
# `rm`-ing the file.
#
# The Moat "circumvention/builtin" endpoint returns the same default bridges
# Tor Browser ships with — public, rotated by the Tor Project, no CAPTCHA, no
# enumeration concern (they were already public the moment Tor Browser
# shipped them).

set -euo pipefail

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
BRIDGES_DIR="$CONFIG_HOME/nice-dns"
BRIDGES_FILE="$BRIDGES_DIR/bridges.env"
MOAT_URL="https://bridges.torproject.org/moat/circumvention/builtin"
BRIDGE_RE='^obfs4 [^[:space:]]+ [0-9A-Fa-f]{40} cert=[^[:space:]]+ iat-mode=[012]$'
# Cap how many BRIDGE_i lines we'll write. start.sh iterates BRIDGE1..BRIDGE16,
# but empirically 3 outperforms 7: with NumPrimaryGuards 3 and a larger pool,
# Tor's primary-guard rotation widens first-query latency variance enough to
# make multi-second timeouts common in the first ~10 minutes. The theoretical
# failover-via-reserves benefit is real but doesn't pay back the cost.
# Operators who want reserves can hand-edit bridges.env to add BRIDGE4+ —
# start.sh handles them — but we don't auto-fetch them.
MAX_BRIDGES=3
# Minimum needed to engage Conflux mode in tor-haproxy/start.sh.
MIN_BRIDGES=3

# Skip work if the file is already populated with ≥ MIN_BRIDGES unquoted,
# container-valid obfs4 lines. Older nice-dns versions wrote shell-quoted
# values or only two bridges; both shapes need a refetch — podman --env-file
# passes quotes through literally (rejected by tor-haproxy's regex), and a
# 2-bridge file makes Tor fall back to single circuits (Conflux disabled).
existing_count=0
if [[ -f "$BRIDGES_FILE" ]]; then
    for ((j=1; j<=MAX_BRIDGES; j++)); do
        v="$(sed -n "s/^BRIDGE${j}=//p" "$BRIDGES_FILE" | head -n 1)"
        [[ -z "$v" ]] && break
        if [[ ! "$v" =~ $BRIDGE_RE ]]; then
            existing_count=-1
            break
        fi
        existing_count=$((existing_count + 1))
    done
fi

if (( existing_count >= MIN_BRIDGES )); then
    echo "▸ Bridges already configured at $BRIDGES_FILE ($existing_count entries)"
    exit 0
elif (( existing_count == -1 )); then
    echo "▸ Existing bridges at $BRIDGES_FILE are not valid for podman --env-file; refreshing..."
elif [[ -f "$BRIDGES_FILE" ]]; then
    echo "▸ Existing $BRIDGES_FILE has only $existing_count bridge(s); refreshing for Conflux + failover support..."
fi

mkdir -p "$BRIDGES_DIR"
chmod 700 "$BRIDGES_DIR"

echo "▸ Fetching default obfs4 bridges from Tor Moat..."

# Fetch the JSON payload. -fsS = fail on HTTP error, silent except on error.
moat_payload="$(curl -fsS --max-time 30 \
    -X POST "$MOAT_URL" \
    -H 'Content-Type: application/vnd.api+json' \
    --data '{"data":[{"version":"0.1.0","type":"moat-circumvention"}]}' \
    || true)"

if [[ -z "$moat_payload" ]]; then
    echo "ERROR: Could not reach $MOAT_URL." >&2
    echo "       Check internet access, or pre-populate $BRIDGES_FILE manually" >&2
    echo "       with two BRIDGE1=/BRIDGE2= obfs4 lines and re-run install." >&2
    exit 1
fi

# Extract obfs4 lines from the JSON. The payload shape is
#   {"obfs4":["obfs4 IP:PORT FPR cert=... iat-mode=N", ...], "snowflake":[...]}
# We use grep -oE with a regex anchored on the literal "obfs4 " prefix so
# we don't depend on jq being installed.
# `while read` instead of `mapfile -t` because macOS ships Bash 3.2 as
# /bin/bash (GPLv3-avoidance) and the install-mac.sh shebang `#!/usr/bin/env
# bash` resolves to it; mapfile is a Bash 4+ builtin and would crash the
# install with "mapfile: command not found" before tor-haproxy starts.
obfs4_lines=()
while IFS= read -r _line; do
    obfs4_lines+=("$_line")
done < <(printf '%s' "$moat_payload" \
    | grep -oE '"obfs4 [^"]+"' \
    | sed 's/^"//; s/"$//')

if (( ${#obfs4_lines[@]} < MIN_BRIDGES )); then
    echo "ERROR: Moat returned fewer than $MIN_BRIDGES obfs4 bridges." >&2
    echo "       Payload: $moat_payload" >&2
    exit 1
fi

# Pick up to MAX_BRIDGES distinct, syntactically valid, network-diverse
# bridges. Moat's shuffle sometimes lands two bridges on the same /24
# (e.g. 212.83.43.74 and 212.83.43.95 are both Moat-returned built-ins).
# Tor's Conflux algorithm requires *link-disjoint* paths between the two
# parallel circuits — sharing a /24 is borderline at best, and in practice
# we measured cold-query latency rise from ~450 ms to multi-second timeouts
# when two of three primary guards were on the same /24 (see commit
# history). Filter to distinct /24s up front.
#
# Two-pass: first pass enforces /24-distinct + fingerprint-distinct; if
# Moat's response somehow doesn't have MAX_BRIDGES /24-distinct entries,
# the second pass relaxes the /24 constraint so we never end up with
# fewer than MIN_BRIDGES.
extract_slash24() {
    # 'obfs4 IP:PORT FPR cert=...' → first three octets of IP.
    awk '{split($2, a, ":"); split(a[1], o, "."); print o[1]"."o[2]"."o[3]}' <<<"$1"
}

picked=()
picked_fprs=()
picked_slash24s=()

# Bash 3.2 (which macOS ships as /bin/bash) treats "${arr[@]}" on an empty
# array as an unset reference under `set -u` and aborts. Bash 4.4+ fixed
# this. The picked_*/picked_slash24s arrays start empty, so the inner
# de-duplication loops use `${arr[@]+"${arr[@]}"}` — expands to nothing on
# the first pass, to the actual elements once any have been appended.

# Pass 1: /24-distinct.
for line in "${obfs4_lines[@]}"; do
    fpr="$(awk '{print $3}' <<<"$line")"
    [[ "$line" =~ $BRIDGE_RE ]] || continue
    # Skip if we've already picked this fingerprint OR this /24.
    skip=0
    for seen in ${picked_fprs[@]+"${picked_fprs[@]}"}; do
        [[ "$fpr" == "$seen" ]] && { skip=1; break; }
    done
    [[ $skip -eq 1 ]] && continue
    s24="$(extract_slash24 "$line")"
    for seen in ${picked_slash24s[@]+"${picked_slash24s[@]}"}; do
        [[ "$s24" == "$seen" ]] && { skip=1; break; }
    done
    [[ $skip -eq 1 ]] && continue
    picked+=("$line")
    picked_fprs+=("$fpr")
    picked_slash24s+=("$s24")
    [[ ${#picked[@]} -eq MAX_BRIDGES ]] && break
done

# Pass 2: if /24-distinct didn't yield enough, fall back to fingerprint-
# distinct only. Loud comment in the output so an operator inspecting
# bridges.env later can correlate with any latency complaints.
if (( ${#picked[@]} < MIN_BRIDGES )); then
    echo "▸ Moat did not return $MIN_BRIDGES /24-distinct obfs4 bridges (got ${#picked[@]})."
    echo "  Filling remaining slots without /24-diversity — Conflux may"
    echo "  occasionally fall back to single-circuit on ill-luck circuit selection."
    for line in "${obfs4_lines[@]}"; do
        fpr="$(awk '{print $3}' <<<"$line")"
        [[ "$line" =~ $BRIDGE_RE ]] || continue
        skip=0
        for seen in ${picked_fprs[@]+"${picked_fprs[@]}"}; do
            [[ "$fpr" == "$seen" ]] && { skip=1; break; }
        done
        [[ $skip -eq 1 ]] && continue
        picked+=("$line")
        picked_fprs+=("$fpr")
        [[ ${#picked[@]} -eq MAX_BRIDGES ]] && break
    done
fi

if (( ${#picked[@]} < MIN_BRIDGES )); then
    echo "ERROR: Moat returned fewer than $MIN_BRIDGES distinct, syntactically valid obfs4 bridges." >&2
    exit 1
fi

# Write atomically. NO surrounding quotes on values: podman --env-file and
# systemd EnvironmentFile= both treat quotes as literal characters, which
# breaks the obfs4 regex in tor-haproxy/tor-socat start.sh. Bash `source`,
# in contrast, requires quotes around space-containing values — so the Mac
# install script (install-mac.sh) reads BRIDGE1/BRIDGE2 with `sed`, not
# `source`, and this unquoted format works for all three consumers.
umask 077
tmp="$(mktemp "$BRIDGES_FILE.XXXXXX")"
{
    printf '# Auto-generated by nice-dns/scripts/fetch-bridges.sh on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Source: %s (Tor Project built-in obfs4 list)\n' "$MOAT_URL"
    printf "# Re-fetch with: rm '%s' && nice-dns-install rerun\n" "$BRIDGES_FILE"
    printf '# Format: KEY=VALUE  (NO surrounding quotes — podman --env-file does not strip them)\n'
    for ((i=0; i<${#picked[@]}; i++)); do
        printf 'BRIDGE%d=%s\n' "$((i+1))" "${picked[i]}"
    done
} > "$tmp"
mv "$tmp" "$BRIDGES_FILE"
chmod 600 "$BRIDGES_FILE"

echo "✓ Wrote $BRIDGES_FILE (mode 600) with ${#picked[@]} bridges"
for ((i=0; i<${#picked[@]}; i++)); do
    echo "  BRIDGE$((i+1)) fingerprint: ${picked_fprs[i]}"
done
