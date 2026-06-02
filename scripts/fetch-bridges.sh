#!/usr/bin/env bash
#
# Fetch obfs4 bridges from the Tor Project's Moat API and write the full
# candidate POOL (deduplicated, syntactically valid, up to MAX_BRIDGES) as
# BRIDGE1..BRIDGEN to ~/.config/nice-dns/bridges.env. The tor-haproxy and
# tor-socat containers consume that file via EnvironmentFile= (Linux quadlets)
# or `sed -n 's/^KEY=//p'` (install-mac.sh — bash `source` is unsafe on values
# with spaces and no quotes).
#
# This script intentionally does NOT rank or pre-select bridges. The proxy
# images ship /bin/bridge-eval, which at container start tests the pool for
# *real* obfs4 usability (completes the handshake + reaches the Cloudflare DoT
# .onion) and keeps the fastest-handshaking 3 — with Tor Conflux needing ≥3
# link-disjoint guards. A TCP-connect latency probe here cannot tell a working
# bridge from one that is TCP-open-but-PT-dead, so ranking is left to the
# in-image evaluator. Writing the whole pool (more than the 3 finally used) is
# what lets bridge-eval's auto mode engage.
#
# Idempotent: if the file already exists and contains ≥MIN_BRIDGES valid
# BRIDGE_i lines, the script exits 0 without touching anything. Re-fetch with
# --force or by `rm`-ing the file.
#
# The Moat "circumvention/builtin" endpoint returns the same default bridges
# Tor Browser ships with — public, rotated by the Tor Project, no CAPTCHA, no
# enumeration concern (they were already public the moment Tor Browser
# shipped them).

set -euo pipefail

# --force/-f bypasses the "skip if bridges.env already has ≥MIN_BRIDGES valid
# entries" check, so the boot-time refresh service can always re-fetch the
# current pool. Network-failure semantics are unchanged: if the curl fails,
# the existing bridges.env is kept untouched (we only mv the tmpfile in on
# success).
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--force]" >&2
            echo "  --force, -f   Refetch the candidate pool even if a valid bridges.env exists." >&2
            exit 0 ;;
        *)
            echo "ERROR: unknown argument: $arg" >&2
            exit 2 ;;
    esac
done

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
BRIDGES_DIR="$CONFIG_HOME/nice-dns"
BRIDGES_FILE="$BRIDGES_DIR/bridges.env"
MOAT_URL="https://bridges.torproject.org/moat/circumvention/builtin"
BRIDGE_RE='^obfs4 [^[:space:]]+ [0-9A-Fa-f]{40} cert=[^[:space:]]+ iat-mode=[012]$'
# Cap on how many candidates we write. start.sh reads BRIDGE1..BRIDGE16 as the
# pool and bridge-eval picks the best BRIDGE_COUNT (default 3) from it.
MAX_BRIDGES=16
# Below this, bridge-eval can't form a 3-guard Conflux set — emit a note.
MIN_BRIDGES=3

# Skip work if the file is already populated with ≥ MIN_BRIDGES unquoted,
# container-valid obfs4 lines. Older nice-dns versions wrote shell-quoted
# values or only two bridges; both shapes need a refetch — podman --env-file
# passes quotes through literally (rejected by the image's regex), and a
# 2-bridge file makes Tor fall back to single circuits (Conflux disabled).
if (( FORCE == 1 )); then
    echo "▸ --force given; re-fetching candidate pool regardless of existing $BRIDGES_FILE"
else
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
        echo "▸ Candidate pool already present at $BRIDGES_FILE ($existing_count entries)"
        exit 0
    elif (( existing_count == -1 )); then
        echo "▸ Existing bridges at $BRIDGES_FILE are not valid for podman --env-file; refreshing..."
    elif [[ -f "$BRIDGES_FILE" ]]; then
        echo "▸ Existing $BRIDGES_FILE has only $existing_count bridge(s); refreshing the pool..."
    fi
fi

mkdir -p "$BRIDGES_DIR"
chmod 700 "$BRIDGES_DIR"

echo "▸ Fetching default obfs4 bridges from Tor Moat..."

# Bootstrap-resolve the Moat host independently of the system resolver.
# At boot the host's /etc/resolv.conf points at 127.0.0.1 — i.e. the very
# nice-dns stack this script is trying to bring up — so a plain curl here
# fails with "Could not resolve host" and the refresh never runs, stranding
# Tor on whatever (possibly stale/slow) bridges.env already holds. Resolve
# the Moat host against public resolvers and pin the result with
# `curl --resolve` (SNI preserved). Degrade gracefully: if dig is missing or
# every bootstrap resolver fails, fall through to a plain curl so hosts with
# a working system resolver behave exactly as before.
moat_host="${MOAT_URL#*://}"; moat_host="${moat_host%%/*}"
resolve_opt=()
if command -v dig >/dev/null 2>&1; then
    for _r in 1.1.1.1 9.9.9.9 8.8.8.8; do
        moat_ip="$(dig +short +time=3 +tries=1 "@$_r" "$moat_host" A 2>/dev/null \
            | grep -Em1 '^[0-9]+(\.[0-9]+){3}$' || true)"
        if [[ -n "$moat_ip" ]]; then
            resolve_opt=(--resolve "$moat_host:443:$moat_ip")
            echo "  ↳ resolved $moat_host → $moat_ip via $_r (bootstrap resolver)"
            break
        fi
    done
fi

# Fetch the JSON payload. -fsS = fail on HTTP error, silent except on error.
moat_payload="$(curl -fsS --max-time 30 \
    ${resolve_opt[@]+"${resolve_opt[@]}"} \
    -X POST "$MOAT_URL" \
    -H 'Content-Type: application/vnd.api+json' \
    --data '{"data":[{"version":"0.1.0","type":"moat-circumvention"}]}' \
    || true)"

if [[ -z "$moat_payload" ]]; then
    echo "ERROR: Could not reach $MOAT_URL." >&2
    echo "       Check internet access, or pre-populate $BRIDGES_FILE manually" >&2
    echo "       with BRIDGE1=/BRIDGE2=/BRIDGE3= obfs4 lines and re-run install." >&2
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

if (( ${#obfs4_lines[@]} < 1 )); then
    echo "ERROR: Moat returned no obfs4 bridges." >&2
    echo "       Payload: $moat_payload" >&2
    exit 1
fi

# Keep every syntactically valid, fingerprint-distinct candidate (up to
# MAX_BRIDGES). No ranking — bridge-eval does that in-image.
picked=()
picked_fprs=()
for ((i=0; i<${#obfs4_lines[@]}; i++)); do
    line="${obfs4_lines[i]}"
    [[ "$line" =~ $BRIDGE_RE ]] || continue
    fpr="$(awk '{print $3}' <<<"$line")"
    dup=0
    for seen in ${picked_fprs[@]+"${picked_fprs[@]}"}; do
        [[ "$fpr" == "$seen" ]] && { dup=1; break; }
    done
    [[ $dup -eq 1 ]] && continue
    picked+=("$line")
    picked_fprs+=("$fpr")
    [[ ${#picked[@]} -ge MAX_BRIDGES ]] && break
done

if (( ${#picked[@]} < 1 )); then
    echo "ERROR: no syntactically valid obfs4 bridges in the Moat payload." >&2
    exit 1
fi
if (( ${#picked[@]} < MIN_BRIDGES )); then
    echo "▸ Note: only ${#picked[@]} valid candidate(s); bridge-eval/Conflux want ${MIN_BRIDGES}."
fi

# Write atomically. NO surrounding quotes on values: podman --env-file and
# systemd EnvironmentFile= both treat quotes as literal characters, which
# breaks the obfs4 regex in tor-haproxy/tor-socat start.sh. Bash `source`,
# in contrast, requires quotes around space-containing values — so the Mac
# install script (install-mac.sh) reads BRIDGE_i with `sed`, not `source`,
# and this unquoted format works for all three consumers.
umask 077
tmp="$(mktemp "$BRIDGES_FILE.XXXXXX")"
{
    printf '# Auto-generated by nice-dns/scripts/fetch-bridges.sh on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Candidate POOL from %s — final selection happens in-image via bridge-eval.\n' "$MOAT_URL"
    printf "# Re-fetch with: rm '%s' && nice-dns-install rerun\n" "$BRIDGES_FILE"
    printf '# Format: KEY=VALUE  (NO surrounding quotes — podman --env-file does not strip them)\n'
    for ((i=0; i<${#picked[@]}; i++)); do
        printf 'BRIDGE%d=%s\n' "$((i+1))" "${picked[i]}"
    done
} > "$tmp"
mv "$tmp" "$BRIDGES_FILE"
chmod 600 "$BRIDGES_FILE"

echo "✓ Wrote $BRIDGES_FILE (mode 600) with ${#picked[@]} candidate bridge(s) for in-image selection"
