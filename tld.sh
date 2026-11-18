#!/usr/bin/env bash
#
# tldlookup - IANA-aware WHOIS + authoritative DNS lookup
#
# Requirements: bash, curl, dig (dnsutils/bind-tools), whois, python3
# Optional: timeout
#
# Usage:
#   tldlookup example.aaa
#   tldlookup --no-dig example.aaa
#   tldlookup --no-whois example.aaa
#
set -uo pipefail

PROG="${0##*/}"
IANA_BASE="https://www.iana.org/domains/root/db"
IANA_WHOIS="whois.iana.org"
TIMEOUT=5
DO_DIG=1
DO_WHOIS=1

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; RESET=''
fi

usage() {
    cat <<EOF
${BOLD}${PROG}${RESET} - IANA-aware domain and TLD lookup

Usage:
  ${PROG} [options] domain.tld

Examples:
  ${PROG} example.aaa
  ${PROG} example.photography
  ${PROG} --no-dig example.aaa
  ${PROG} --timeout 8 example.aaa

Options:
  -h, --help          Show this help
  -q, --quiet         Reduce headings and explanatory messages
  --no-dig            Skip authoritative DNS checks
  --no-whois          Skip WHOIS lookups
  --timeout SECONDS   DNS/WHOIS connection timeout (default: ${TIMEOUT})

The TLD is checked against IANA's Root Zone Database. Registry WHOIS and
registration website details are taken from IANA when published. DNS checks
are sent to the TLD's delegated authoritative nameservers, not its WHOIS host.
EOF
}

QUIET=0
DOMAIN=""
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -q|--quiet) QUIET=1; shift ;;
        --no-dig) DO_DIG=0; shift ;;
        --no-whois) DO_WHOIS=0; shift ;;
        --timeout)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --timeout value" >&2; exit 2; }
            TIMEOUT="$2"; shift 2 ;;
        --) shift; break ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2 ;;
        *)
            if [[ -n "$DOMAIN" ]]; then
                echo "Please provide one domain at a time." >&2
                exit 2
            fi
            DOMAIN="$1"; shift ;;
    esac
done
if [[ -z "$DOMAIN" && $# -gt 0 ]]; then DOMAIN="$1"; shift; fi
if [[ -z "$DOMAIN" ]]; then usage >&2; exit 2; fi
if [[ $# -gt 0 ]]; then echo "Unexpected extra argument: $1" >&2; exit 2; fi

DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN%.}"
# Accept ordinary ASCII hostnames and punycode IDNs. Deliberately reject URLs,
# ports, wildcards, and malformed labels.
if ((${#DOMAIN} > 253)) || [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "That doesn't look like a valid domain name: $DOMAIN" >&2
    echo "Tip: enter a hostname such as example.tld, not a URL." >&2
    exit 2
fi

TLD="${DOMAIN##*.}"
for cmd in curl dig python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd" >&2
        echo "Install it and try again." >&2
        exit 1
    fi
done
if (( DO_WHOIS )) && ! command -v whois >/dev/null 2>&1; then
    echo "Note: 'whois' is not installed; WHOIS queries will be skipped." >&2
    DO_WHOIS=0
fi

heading() {
    (( QUIET )) || printf '\n%b── %s ──%b\n' "$BLUE$BOLD" "$1" "$RESET"
}
info() { printf '%b%-22s%b %s\n' "$BOLD" "$1" "$RESET" "$2"; }
warn() { printf '%b!%b %s\n' "$YELLOW" "$RESET" "$*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

heading "Input"
info "Domain:" "$DOMAIN"
info "TLD:" ".$TLD"
info "IANA source:" "$IANA_BASE"

# Fetch the official per-TLD IANA record. A successful page response is the
# validation check; we don't infer registry details from the TLD's spelling.
IANA_URL="${IANA_BASE}/${TLD}.html"
HTTP_CODE="$(curl -L -sS --max-time "$((TIMEOUT * 3))" -o "$TMP/iana.html" -w '%{http_code}' "$IANA_URL" 2>/dev/null || true)"
IANA_OK=0
if [[ "$HTTP_CODE" == "200" ]] && grep -qi 'Root Zone Database' "$TMP/iana.html"; then
    IANA_OK=1
    printf '%bIANA TLD record found%b\n' "$GREEN" "$RESET"
else
    warn "Could not confirm .$TLD in IANA's Root Zone Database (HTTP ${HTTP_CODE:-unknown})."
    warn "Continuing with best-effort lookups; results may be incomplete."
fi

# Extract fields from IANA's HTML without requiring BeautifulSoup.
# IANA pages render these as table label/value pairs.
REG_URL=""
IANA_WHOIS_HOST=""
if (( IANA_OK )); then
    readarray -t IANA_FIELDS < <(python3 - "$TMP/iana.html" <<'PY'
import sys, re
from html.parser import HTMLParser
from html import unescape

class Text(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts=[]
    def handle_data(self, data):
        s=data.strip()
        if s: self.parts.append(s)

p=Text()
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    p.feed(f.read())
text=" ".join(p.parts)
text=re.sub(r"\s+", " ", unescape(text))
def field(label):
    m=re.search(re.escape(label)+r"\s*(.*?)\s*(?:Modify|$)", text, re.I)
    return m.group(1).strip() if m else ""
print(field("Registration URL:"))
print(field("WHOIS Server:"))
PY
)
    REG_URL="${IANA_FIELDS[0]:-}"
    IANA_WHOIS_HOST="${IANA_FIELDS[1]:-}"
    [[ "$REG_URL" == "-" ]] && REG_URL=""
    [[ "$IANA_WHOIS_HOST" == "-" ]] && IANA_WHOIS_HOST=""
fi

# Query IANA WHOIS for the referral. This is useful when the page's WHOIS
# field is absent or the IANA page layout changes.
IANA_WHOIS_TEXT=""
REFERRAL=""
if (( DO_WHOIS )); then
    heading "IANA WHOIS referral"
    if IANA_WHOIS_TEXT="$(whois -h "$IANA_WHOIS" "$DOMAIN" 2>/dev/null || true)"; then
        REFERRAL="$(printf '%s\n' "$IANA_WHOIS_TEXT" | awk -F: 'tolower($1) ~ /^[[:space:]]*refer[[:space:]]*$/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
        # Some IANA responses identify the registry with a "whois:" field.
        if [[ -z "$REFERRAL" ]]; then
            REFERRAL="$(printf '%s\n' "$IANA_WHOIS_TEXT" | awk -F: 'tolower($1) ~ /^[[:space:]]*whois[[:space:]]*$/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
        fi
        [[ -n "$REFERRAL" ]] && printf 'IANA referral: %s\n' "$REFERRAL" || printf 'No registry referral supplied by IANA WHOIS.\n'
    fi
fi

WHOIS_HOST="$IANA_WHOIS_HOST"
if [[ -n "$REFERRAL" ]]; then WHOIS_HOST="$REFERRAL"; fi

heading "Registry / website information"
if [[ -n "$REG_URL" ]]; then
    info "Registration site:" "$REG_URL"
else
    warn "IANA does not publish a registration URL for this TLD, or it could not be parsed."
fi
if [[ -n "$WHOIS_HOST" ]]; then
    info "Registry WHOIS:" "$WHOIS_HOST"
else
    warn "No registry WHOIS hostname was found in IANA's published data."
fi
info "IANA TLD record:" "$([[ $IANA_OK == 1 ]] && echo "$IANA_URL" || echo "not confirmed")"

if (( DO_WHOIS )); then
    heading "WHOIS results"
    if [[ -n "$WHOIS_HOST" ]]; then
        printf '%bQuerying registry WHOIS: %s%b\n' "$DIM" "$WHOIS_HOST" "$RESET"
        if ! whois -h "$WHOIS_HOST" "$DOMAIN" 2>&1; then
            warn "Registry WHOIS query failed; showing the IANA response instead."
        fi
    else
        warn "No registry WHOIS host identified; IANA's response follows."
    fi
    if [[ -n "$IANA_WHOIS_TEXT" ]]; then
        printf '\n%bIANA WHOIS response%b\n' "$BOLD" "$RESET"
        printf '%s\n' "$IANA_WHOIS_TEXT"
    fi
fi

if (( DO_DIG )); then
    heading "Authoritative DNS"
    # The NS records for the TLD are the delegated nameservers published in
    # the DNS hierarchy. A WHOIS server is not assumed to be a DNS server.
    mapfile -t NS_LIST < <(dig +time="$TIMEOUT" +tries=1 +short NS "$TLD" 2>/dev/null | sed 's/\.$//' | sort -u)
    if ((${#NS_LIST[@]} == 0)); then
        warn "No delegated nameservers could be discovered for .$TLD."
        warn "Skipping authoritative DNS queries."
    else
        printf 'TLD nameservers discovered for .%s:\n' "$TLD"
        printf '  %s\n' "${NS_LIST[@]}"
        for ns in "${NS_LIST[@]}"; do
            printf '\n%b%s%b\n' "$BOLD" "$ns" "$RESET"
            for rr in A AAAA MX NS TXT CAA SOA; do
                RESULT="$(dig @"$ns" "$DOMAIN" "$rr" +time="$TIMEOUT" +tries=1 +noall +answer 2>/dev/null || true)"
                if [[ -n "$RESULT" ]]; then
                    printf '%b[%s]%b\n%s\n' "$GREEN" "$rr" "$RESET" "$RESULT"
                fi
            done
        done
        printf '\n%bOnly returned answer records are shown; empty record types are omitted.%b\n' "$DIM" "$RESET"
    fi
fi

heading "Finished"
printf 'Lookup complete for %s\n' "$DOMAIN"
