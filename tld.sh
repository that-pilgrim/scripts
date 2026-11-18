#!/usr/bin/env bash
#
# tldlookup - IANA-aware WHOIS + RDAP + DNS lookup for a domain
#
# What it does:
#   1. Validates the TLD against IANA's Root Zone Database (org, status, registry URL)
#   2. Finds the registry WHOIS server via IANA and queries it for the domain
#   3. Prints a parsed WHOIS summary (registrar, dates, status, nameservers)
#      and, optionally, the full raw WHOIS text
#   4. Falls back to RDAP (via IANA's RDAP bootstrap) if WHOIS gives nothing useful
#   5. Asks the TLD's own nameservers for the domain's delegation (this is where a
#      TLD server actually answers), then queries the domain's authoritative
#      nameservers for A/AAAA/MX/NS/TXT/CAA/SOA records
#   6. Prints a one-line verdict: registered / delegated / likely available
#
# Requirements: bash 4+, curl, dig (dnsutils/bind-tools), python3
# Optional:     whois, timeout
#
set -uo pipefail

PROG="${0##*/}"
IANA_BASE="https://www.iana.org/domains/root/db"
IANA_WHOIS="whois.iana.org"
RDAP_BOOTSTRAP="https://data.iana.org/rdap/dns.json"
TIMEOUT=5
DO_DIG=1
DO_WHOIS=1
DO_RDAP=auto     # auto | always | never
SHOW_RAW=1
QUIET=0
DOMAIN=""

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; RESET=''
fi

usage() {
    cat <<EOF
${BOLD}${PROG}${RESET} - IANA-aware WHOIS, RDAP and DNS lookup

Usage:
  ${PROG} [options] domain.tld

Examples:
  ${PROG} example.photography
  ${PROG} --no-raw example.com
  ${PROG} --rdap example.aaa
  ${PROG} --no-dig --timeout 8 example.org

Options:
  -h, --help          Show this help
  -q, --quiet         Reduce headings and explanatory messages
  --no-dig            Skip DNS checks
  --no-whois          Skip WHOIS lookups
  --no-raw            Show the parsed WHOIS summary only, not the full raw text
  --rdap              Always query RDAP (default: only when WHOIS is unusable)
  --no-rdap           Never query RDAP
  --timeout SECONDS   Per-query timeout (default: ${TIMEOUT})

Environment:
  NO_COLOR            Disable colored output
EOF
}

while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -q|--quiet) QUIET=1; shift ;;
        --no-dig) DO_DIG=0; shift ;;
        --no-whois) DO_WHOIS=0; shift ;;
        --no-raw) SHOW_RAW=0; shift ;;
        --rdap) DO_RDAP=always; shift ;;
        --no-rdap) DO_RDAP=never; shift ;;
        --timeout)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --timeout value" >&2; exit 2; }
            TIMEOUT="$2"; shift 2 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            [[ -n "$DOMAIN" ]] && { echo "Please provide one domain at a time." >&2; exit 2; }
            DOMAIN="$1"; shift ;;
    esac
done
if [[ -z "$DOMAIN" && $# -gt 0 ]]; then DOMAIN="$1"; shift; fi
[[ -z "$DOMAIN" ]] && { usage >&2; exit 2; }
[[ $# -gt 0 ]] && { echo "Unexpected extra argument: $1" >&2; exit 2; }

DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN%.}"
# ASCII hostnames and punycode only; rejects URLs, ports, wildcards, bad labels.
if ((${#DOMAIN} > 253)) || [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "That doesn't look like a valid domain name: $DOMAIN" >&2
    echo "Tip: enter a hostname such as example.tld, not a URL." >&2
    exit 2
fi
TLD="${DOMAIN##*.}"

for cmd in curl dig python3; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done
if (( DO_WHOIS )) && ! command -v whois >/dev/null 2>&1; then
    echo "Note: 'whois' is not installed; WHOIS queries will be skipped (RDAP will be used instead)." >&2
    DO_WHOIS=0
    [[ "$DO_RDAP" == never ]] || DO_RDAP=always
fi

# --- helpers ---------------------------------------------------------------
heading() { (( QUIET )) || printf '\n%b── %s ──%b\n' "$BLUE$BOLD" "$1" "$RESET"; }
info()    { printf '%b%-22s%b %s\n' "$BOLD" "$1" "$RESET" "$2"; }
warn()    { printf '%b!%b %s\n' "$YELLOW" "$RESET" "$*"; }
good()    { printf '%b✓%b %s\n' "$GREEN" "$RESET" "$*"; }

# Run a command with a hard time limit when `timeout` exists.
run_to() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

# Print the first value of a "key: value" field (case-insensitive key) from text on stdin.
field_first() {
    awk -F: -v k="$1" 'tolower($1) ~ "^[[:space:]]*" tolower(k) "[[:space:]]*$" {
        sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); if ($0 != "") { print; exit } }'
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. IANA root zone record ---------------------------------------------
heading "Input"
info "Domain:" "$DOMAIN"
info "TLD:" ".$TLD"

IANA_URL="${IANA_BASE}/${TLD}.html"
HTTP_CODE="$(curl -L -sS --max-time "$((TIMEOUT * 3))" -o "$TMP/iana.html" -w '%{http_code}' "$IANA_URL" 2>/dev/null || true)"
IANA_OK=0
if [[ "$HTTP_CODE" == "200" ]] && grep -qi 'Root Zone Database' "$TMP/iana.html"; then
    IANA_OK=1
    good "IANA TLD record found"
else
    warn "Could not confirm .$TLD in IANA's Root Zone Database (HTTP ${HTTP_CODE:-unknown})."
    warn "Continuing with best-effort lookups; results may be incomplete."
fi

REG_URL=""
IANA_PAGE_WHOIS=""
if (( IANA_OK )); then
    readarray -t IANA_FIELDS < <(python3 - "$TMP/iana.html" <<'PY'
import re, sys
from html import unescape
from html.parser import HTMLParser

class Text(HTMLParser):
    def __init__(self):
        super().__init__(); self.parts = []
    def handle_data(self, d):
        d = d.strip()
        if d: self.parts.append(d)

p = Text()
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    p.feed(f.read())
text = re.sub(r"\s+", " ", unescape(" ".join(p.parts)))

def first(*labels):
    # Value is the single token after the label (URLs and hostnames have no spaces).
    for label in labels:
        m = re.search(re.escape(label) + r"\s*(\S+)", text, re.I)
        if m: return m.group(1)
    return ""

print(first("URL for registration services:", "Registration URL:"))
print(first("WHOIS Server:"))
PY
)
    REG_URL="${IANA_FIELDS[0]:-}"
    IANA_PAGE_WHOIS="${IANA_FIELDS[1]:-}"
    [[ "$REG_URL" == "-" ]] && REG_URL=""
    [[ "$IANA_PAGE_WHOIS" == "-" ]] && IANA_PAGE_WHOIS=""
fi

# --- 2. IANA WHOIS: query the TLD itself to find the registry server -------
IANA_TLD_TEXT=""
REGISTRY_WHOIS="$IANA_PAGE_WHOIS"
if (( DO_WHOIS )); then
    IANA_TLD_TEXT="$(run_to "$((TIMEOUT * 3))" whois -h "$IANA_WHOIS" "$TLD" 2>/dev/null || true)"
    ref="$(printf '%s\n' "$IANA_TLD_TEXT" | field_first whois)"
    [[ -z "$ref" ]] && ref="$(printf '%s\n' "$IANA_TLD_TEXT" | field_first refer)"
    [[ -n "$ref" ]] && REGISTRY_WHOIS="$ref"
fi

heading "TLD / registry information"
if [[ -n "$IANA_TLD_TEXT" ]]; then
    org="$(printf '%s\n' "$IANA_TLD_TEXT" | field_first organisation)"
    created="$(printf '%s\n' "$IANA_TLD_TEXT" | field_first created)"
    [[ -n "$org" ]] && info "Sponsoring org:" "$org"
    [[ -n "$created" ]] && info "TLD created:" "$created"
fi
if [[ -n "$REG_URL" ]]; then info "Registration site:" "$REG_URL"
else warn "IANA does not publish a registration URL for this TLD (or it could not be parsed)."; fi
if [[ -n "$REGISTRY_WHOIS" ]]; then info "Registry WHOIS:" "$REGISTRY_WHOIS"
else warn "No registry WHOIS host found in IANA's published data."; fi
info "IANA TLD record:" "$([[ $IANA_OK == 1 ]] && echo "$IANA_URL" || echo "not confirmed")"

# --- 3. Registry WHOIS for the domain --------------------------------------
WHOIS_TEXT=""
WHOIS_STATE="unknown"   # registered | available | unknown
if (( DO_WHOIS )); then
    heading "WHOIS"
    if [[ -n "$REGISTRY_WHOIS" ]]; then
        WHOIS_TEXT="$(run_to "$((TIMEOUT * 3))" whois -h "$REGISTRY_WHOIS" "$DOMAIN" 2>&1 || true)"
    else
        # Let the whois client work out the server itself as a last resort.
        warn "Falling back to the whois client's own server selection."
        WHOIS_TEXT="$(run_to "$((TIMEOUT * 3))" whois "$DOMAIN" 2>&1 || true)"
    fi

    if [[ -z "${WHOIS_TEXT//[[:space:]]/}" ]]; then
        warn "WHOIS returned nothing (the server may be down, rate-limiting, or WHOIS may be retired for this TLD)."
    else
        if grep -qiE '^(no match|not found|no data found|no entries found|domain not found|status:[[:space:]]*(available|free))|is (free|available)|no object found|does not exist' <<<"$WHOIS_TEXT"; then
            WHOIS_STATE="available"
        elif grep -qiE 'domain name:|^domain:|registry domain id|registrar:' <<<"$WHOIS_TEXT"; then
            WHOIS_STATE="registered"
        fi

        # Parsed summary (works for most gTLD/ccTLD formats; absent fields are skipped).
        w_registrar="$(field_first 'registrar' <<<"$WHOIS_TEXT")"
        w_created="$(awk -F: 'tolower($1) ~ /(creation date|created|registered on|registration date)/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$WHOIS_TEXT")"
        w_updated="$(awk -F: 'tolower($1) ~ /(updated date|last updated|last modified|changed)/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$WHOIS_TEXT")"
        w_expires="$(awk -F: 'tolower($1) ~ /(expir)/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$WHOIS_TEXT")"
        w_dnssec="$(field_first 'dnssec' <<<"$WHOIS_TEXT")"
        w_status="$(awk -F: 'tolower($1) ~ /^[[:space:]]*(domain )?status[[:space:]]*$/ {sub(/^[^:]*:[[:space:]]*/, ""); sub(/ https?:.*/, ""); print}' <<<"$WHOIS_TEXT" | sort -u | paste -sd, - | sed 's/,/, /g')"
        w_ns="$(awk -F: 'tolower($1) ~ /^[[:space:]]*(name server|nserver|nameserver)[[:space:]]*$/ {sub(/^[^:]*:[[:space:]]*/, ""); print tolower($1)}' <<<"$WHOIS_TEXT" | awk '{print $1}' | sort -u | paste -sd' ' -)"

        if [[ "$WHOIS_STATE" == "available" ]]; then
            warn "WHOIS indicates $DOMAIN is not registered."
        else
            [[ -n "$w_registrar" ]] && info "Registrar:" "$w_registrar"
            [[ -n "$w_created"   ]] && info "Created:" "$w_created"
            [[ -n "$w_updated"   ]] && info "Updated:" "$w_updated"
            [[ -n "$w_expires"   ]] && info "Expires:" "$w_expires"
            [[ -n "$w_status"    ]] && info "Status:" "$w_status"
            [[ -n "$w_dnssec"    ]] && info "DNSSEC:" "$w_dnssec"
            [[ -n "$w_ns"        ]] && info "Nameservers:" "$w_ns"
        fi

        if (( SHOW_RAW )); then
            printf '\n%bRaw registry WHOIS%b\n' "$BOLD" "$RESET"
            printf '%s\n' "$WHOIS_TEXT"
        fi
    fi
fi

# --- 4. RDAP (fallback or on request) --------------------------------------
want_rdap=0
case "$DO_RDAP" in
    always) want_rdap=1 ;;
    auto)   [[ "$WHOIS_STATE" == "unknown" ]] && want_rdap=1 ;;
esac
RDAP_STATE="unknown"
if (( want_rdap )); then
    heading "RDAP"
    if curl -sS -L --max-time "$((TIMEOUT * 3))" -o "$TMP/bootstrap.json" "$RDAP_BOOTSTRAP" 2>/dev/null; then
        RDAP_BASE="$(python3 - "$TMP/bootstrap.json" "$TLD" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    for tlds, urls in data.get("services", []):
        if sys.argv[2] in tlds and urls:
            print(sorted(urls, key=lambda u: not u.startswith("https"))[0]); break
except Exception:
    pass
PY
)"
        if [[ -n "$RDAP_BASE" ]]; then
            RDAP_BASE="${RDAP_BASE%/}"
            info "RDAP server:" "$RDAP_BASE"
            code="$(curl -sS -L -H 'Accept: application/rdap+json' --max-time "$((TIMEOUT * 3))" \
                -o "$TMP/rdap.json" -w '%{http_code}' "$RDAP_BASE/domain/$DOMAIN" 2>/dev/null || true)"
            if [[ "$code" == "200" ]]; then
                RDAP_STATE="registered"
                python3 - "$TMP/rdap.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def row(k, v):
    if v: print(f"\033[1m{k:<22}\033[0m {v}" if sys.stdout.isatty() else f"{k:<22} {v}")
row("Domain:", d.get("ldhName"))
row("Status:", ", ".join(d.get("status", [])))
for e in d.get("events", []):
    row({"registration": "Created:", "expiration": "Expires:",
         "last changed": "Updated:"}.get(e.get("eventAction"), e.get("eventAction", "") + ":"),
        e.get("eventDate"))
for ent in d.get("entities", []):
    if "registrar" in ent.get("roles", []):
        name = ""
        for item in ent.get("vcardArray", [None, []])[1]:
            if item[0] == "fn": name = item[3]
        row("Registrar:", name or ent.get("handle"))
row("Nameservers:", " ".join(sorted(n.get("ldhName", "").lower() for n in d.get("nameservers", []))))
row("DNSSEC signed:", str(d.get("secureDNS", {}).get("delegationSigned", "")).lower() or None)
PY
            elif [[ "$code" == "404" ]]; then
                RDAP_STATE="available"
                warn "RDAP: no registration found for $DOMAIN (HTTP 404)."
            else
                warn "RDAP query failed (HTTP ${code:-none})."
            fi
        else
            warn "IANA's RDAP bootstrap lists no RDAP server for .$TLD."
        fi
    else
        warn "Could not download IANA's RDAP bootstrap file."
    fi
fi

# --- 5. DNS ----------------------------------------------------------------
DNS_STATE="skipped"     # delegated | nxdomain | unknown | skipped
if (( DO_DIG )); then
    heading "DNS"
    mapfile -t TLD_NS < <(dig +time="$TIMEOUT" +tries=1 +short NS "$TLD" 2>/dev/null | sed 's/\.$//' | sort -u)
    DNS_STATE="unknown"
    if ((${#TLD_NS[@]} == 0)); then
        warn "No delegated nameservers could be discovered for .$TLD; skipping DNS."
    else
        info "TLD nameservers:" "${#TLD_NS[@]} found (e.g. ${TLD_NS[0]})"

        # Step A: ask a TLD server (non-recursive) for the domain's delegation.
        # A TLD server only gives referrals for second-level names, so the NS
        # records come back in the AUTHORITY section, not the ANSWER section.
        DELEG=()
        for tns in "${TLD_NS[@]}"; do
            OUT="$(dig @"$tns" "$DOMAIN" NS +norecurse +time="$TIMEOUT" +tries=1 +noall +comments +answer +authority 2>/dev/null || true)"
            status="$(grep -o 'status: [A-Z]*' <<<"$OUT" | head -1 | awk '{print $2}')"
            [[ -z "$status" ]] && continue
            if [[ "$status" == "NXDOMAIN" ]]; then
                DNS_STATE="nxdomain"; info "Delegation via $tns:" "NXDOMAIN (name does not exist in .$TLD)"
            else
                mapfile -t DELEG < <(awk -v d="$DOMAIN." 'tolower($1)==d && $4=="NS" {n=tolower($5); sub(/\.$/, "", n); print n}' <<<"$OUT" | sort -u)
                if ((${#DELEG[@]})); then
                    DNS_STATE="delegated"
                    info "Delegation via $tns:" "${DELEG[*]}"
                else
                    info "Delegation via $tns:" "none ($status) - no NS records for the domain"
                    DNS_STATE="nxdomain"
                fi
            fi
            break
        done
        [[ "$DNS_STATE" == "unknown" ]] && warn "None of the TLD nameservers answered within ${TIMEOUT}s."

        # Step B: query each of the domain's own authoritative nameservers.
        if [[ "$DNS_STATE" == "delegated" ]]; then
            n=0
            for ns in "${DELEG[@]}"; do
                (( n++ >= 4 )) && { printf '%b(showing first 4 nameservers)%b\n' "$DIM" "$RESET"; break; }
                printf '\n%b%s%b\n' "$BOLD" "$ns" "$RESET"
                any=0
                for name in "$DOMAIN" "www.$DOMAIN"; do
                    for rr in A AAAA CNAME MX NS TXT CAA SOA; do
                        [[ "$name" != "$DOMAIN" && "$rr" != A && "$rr" != AAAA && "$rr" != CNAME ]] && continue
                        [[ "$name" == "$DOMAIN" && "$rr" == CNAME ]] && continue
                        RESULT="$(dig @"$ns" "$name" "$rr" +time="$TIMEOUT" +tries=1 +noall +answer 2>/dev/null || true)"
                        if [[ -n "$RESULT" ]]; then
                            any=1
                            printf '%b[%s %s]%b\n%s\n' "$GREEN" "$rr" "${name%.$DOMAIN}" "$RESET" "$RESULT"
                        fi
                    done
                done
                (( any )) || warn "No records returned (server unreachable, refused, or zone empty)."
            done
            printf '\n%bOnly returned records are shown; empty record types are omitted.%b\n' "$DIM" "$RESET"
        fi
    fi
fi

# --- 6. Verdict ------------------------------------------------------------
heading "Summary"
registered=0; available=0
[[ "$WHOIS_STATE" == registered || "$RDAP_STATE" == registered ]] && registered=1
[[ "$WHOIS_STATE" == available  || "$RDAP_STATE" == available  ]] && available=1

if (( registered && ! available )); then
    good "$DOMAIN is registered."
    [[ "$DNS_STATE" == nxdomain ]] && warn "...but it has no DNS delegation (parked, on hold, or not yet configured)."
elif (( available && ! registered )); then
    if [[ "$DNS_STATE" == delegated ]]; then
        warn "Registry data says unregistered, yet DNS delegation exists - check the raw output."
    else
        printf '%b%s appears to be available (unregistered).%b Confirm with a registrar before relying on it.\n' "$YELLOW" "$DOMAIN" "$RESET"
    fi
elif [[ "$DNS_STATE" == delegated ]]; then
    good "$DOMAIN is delegated in DNS (so it is registered); WHOIS/RDAP gave no clear answer."
elif [[ "$DNS_STATE" == nxdomain ]]; then
    warn "No DNS delegation found; registration status could not be confirmed from WHOIS/RDAP."
else
    warn "Could not determine registration status."
fi
printf '%bLookup complete for %s%b\n' "$DIM" "$DOMAIN" "$RESET"
