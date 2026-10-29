#!/usr/bin/env bash
#
# Asserts that a Release build of Ledger carries production config (BACKLOG IOS-21r).
# Checks shape only and never prints a value: messages name the key and the rule.
#
#   release-config-check.sh settings
#       From an Xcode "Run Script" phase: reads the LEDGER_* build settings from
#       the environment. A Release build with a missing or local value fails here,
#       before anything compiles (project.yml, preBuildScripts).
#   release-config-check.sh archive PATH
#       PATH is a .xcarchive, an .ipa or a .app. Reads the built Info.plist of the
#       app AND every embedded .appex with plutil (scripts/testflight.sh after
#       archiving, scripts/publish-build.sh on the IPA it stages).
#
# The rules, for each bundle:
#   LedgerSupabaseURL             https://, and the host is not local or private
#   LedgerSupabasePublishableKey  non-empty, sb_publishable_… (never sb_secret_…)
#   LedgerSentryDSN               non-empty, https://
#   LedgerEnvironment             exactly `production`
# and no value is an unresolved $(…) or an example placeholder (<…>).
#
# And the identity, which lives only in the gitignored Config/Identity.xcconfig
# (Base.xcconfig carries neutral defaults: the repository is public):
#   bundle id (LEDGER_BUNDLE_PREFIX / CFBundleIdentifier)  not com.example.…
#   team (DEVELOPMENT_TEAM / LedgerKeychainGroup's prefix)  ten characters A-Z 0-9
#   passkey host (LEDGER_PASSKEY_DOMAIN / LedgerPasskeyDomain, the app only)
#                                                           not example.com
set -euo pipefail

ERRORS=0
fail() { echo "error: $1" >&2; ERRORS=$((ERRORS + 1)); }

# Prints nothing; returns 0 when the URL's host is loopback, private or a local name.
is_local_host() {
  local host="$1"
  host="${host#[}"; host="${host%]}"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$host" in
    ''|localhost|*.localhost|*.local|*.test|*.internal|0.0.0.0|::1|::) return 0 ;;
    127.*|10.*|192.168.*|169.254.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
  esac
  return 1
}

# check_bundle LABEL URL KEY DSN ENV
check_bundle() {
  local label="$1" url="$2" key="$3" dsn="$4" env="$5" name value rest host
  for name in LedgerSupabaseURL LedgerSupabasePublishableKey LedgerSentryDSN LedgerEnvironment; do
    case "$name" in
      LedgerSupabaseURL) value="$url" ;;
      LedgerSupabasePublishableKey) value="$key" ;;
      LedgerSentryDSN) value="$dsn" ;;
      LedgerEnvironment) value="$env" ;;
    esac
    if [[ -z "${value//[[:space:]]/}" ]]; then
      fail "$label: $name is empty (missing from Config/Secrets.Release.xcconfig?)"
    elif [[ "$value" == *"\$("* || "$value" == *'<'* || "$value" == *'>'* ]]; then
      fail "$label: $name is an unresolved setting or a placeholder"
    fi
  done

  if [[ -n "$url" ]]; then
    if [[ "$url" != https://* ]]; then
      fail "$label: LedgerSupabaseURL is not https://"
    else
      rest="${url#https://}"
      rest="${rest%%/*}"
      rest="${rest##*@}"
      if [[ "$rest" == \[* ]]; then host="${rest%%]*}]"; else host="${rest%%:*}"; fi
      if is_local_host "$host"; then
        fail "$label: LedgerSupabaseURL points at a local or private host"
      fi
    fi
  fi
  if [[ -n "$key" ]]; then
    if [[ "$key" == sb_secret_* ]]; then
      fail "$label: LedgerSupabasePublishableKey is a secret key (sb_secret_…); clients hold only the publishable key"
    elif [[ "$key" != sb_publishable_* ]]; then
      fail "$label: LedgerSupabasePublishableKey is not a publishable key (sb_publishable_…)"
    fi
  fi
  if [[ -n "$dsn" && "$dsn" != https://* ]]; then
    fail "$label: LedgerSentryDSN is not https://"
  fi
  if [[ -n "$env" && "$env" != production ]]; then
    fail "$label: LedgerEnvironment is not \`production\`"
  fi
}

# check_identity LABEL BUNDLE_ID TEAM PASSKEY_DOMAIN — an argument passed as `-`
# is not checked (an extension has no passkey domain). Values are never printed.
check_identity() {
  local label="$1" bundle="$2" team="$3" domain="$4"
  if [[ "$bundle" != - ]]; then
    if [[ -z "$bundle" || "$bundle" == *"\$("* || "$bundle" == *'<'* ]]; then
      fail "$label: bundle id is empty or unresolved (LEDGER_BUNDLE_PREFIX in Config/Identity.xcconfig)"
    elif [[ "$bundle" == com.example.* ]]; then
      fail "$label: bundle id is the neutral default com.example.…; set LEDGER_BUNDLE_PREFIX in Config/Identity.xcconfig"
    fi
  fi
  if [[ "$team" != - && ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    fail "$label: no Apple team ID (DEVELOPMENT_TEAM in Config/Identity.xcconfig)"
  fi
  if [[ "$domain" != - ]]; then
    if [[ -z "$domain" || "$domain" == *"\$("* || "$domain" == *'<'* ]]; then
      fail "$label: passkey domain is empty or unresolved (LEDGER_PASSKEY_DOMAIN in Config/Identity.xcconfig)"
    elif [[ "$domain" == example.com || "$domain" == *.example.com ]]; then
      fail "$label: passkey domain is the neutral default example.com; set LEDGER_PASSKEY_DOMAIN in Config/Identity.xcconfig"
    fi
  fi
}

# plist_value PLIST KEY → the raw string, or empty when absent. Never echoed by callers.
plist_value() {
  plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

# check_plist LABEL PLIST app|appex
check_plist() {
  local label="$1" plist="$2" kind="$3" group domain=-
  if [[ ! -f "$plist" ]]; then
    fail "$label: no Info.plist"
    return
  fi
  check_bundle "$label" \
    "$(plist_value "$plist" LedgerSupabaseURL)" \
    "$(plist_value "$plist" LedgerSupabasePublishableKey)" \
    "$(plist_value "$plist" LedgerSentryDSN)" \
    "$(plist_value "$plist" LedgerEnvironment)"
  # LedgerKeychainGroup is $(AppIdentifierPrefix)<prefix>.shared: the team ID and a dot.
  group="$(plist_value "$plist" LedgerKeychainGroup)"
  [[ "$kind" == app ]] && domain="$(plist_value "$plist" LedgerPasskeyDomain)"
  check_identity "$label" "$(plist_value "$plist" CFBundleIdentifier)" "${group%%.*}" "$domain"
}

check_app() {
  local app="$1" appex count=0
  check_plist "$(basename "$app")" "$app/Info.plist" app
  for appex in "$app"/PlugIns/*.appex; do
    [[ -d "$appex" ]] || continue
    count=$((count + 1))
    check_plist "$(basename "$app")/PlugIns/$(basename "$appex")" "$appex/Info.plist" appex
  done
  # The share extension ships in every build: a check that found no .appex
  # checked less than it claims.
  if [[ $count -eq 0 ]]; then
    fail "$(basename "$app"): no embedded .appex found under PlugIns/"
  fi
}

mode="${1:-}"
case "$mode" in
  settings)
    check_bundle "${TARGET_NAME:-build settings} (${CONFIGURATION:-?})" \
      "${LEDGER_SUPABASE_URL:-}" "${LEDGER_SUPABASE_PUBLISHABLE_KEY:-}" \
      "${LEDGER_SENTRY_DSN:-}" "${LEDGER_ENVIRONMENT:-}"
    check_identity "${TARGET_NAME:-build settings} (${CONFIGURATION:-?})" \
      "${LEDGER_BUNDLE_PREFIX:-}" "${DEVELOPMENT_TEAM:-}" "${LEDGER_PASSKEY_DOMAIN:-}"
    ;;
  archive)
    path="${2:-}"
    [[ -n "$path" && -e "$path" ]] || { echo "usage: $0 archive PATH(.xcarchive|.ipa|.app)" >&2; exit 2; }
    command -v plutil >/dev/null || { echo "error: plutil not found (macOS only)" >&2; exit 2; }
    apps=()
    case "$path" in
      *.xcarchive|*.xcarchive/)
        shopt -s nullglob; apps=("${path%/}"/Products/Applications/*.app); shopt -u nullglob ;;
      *.ipa)
        unpacked="$(mktemp -d)"
        trap 'rm -rf "$unpacked"' EXIT
        unzip -q "$path" 'Payload/*' -d "$unpacked"
        shopt -s nullglob; apps=("$unpacked"/Payload/*.app); shopt -u nullglob ;;
      *.app|*.app/)
        apps=("${path%/}") ;;
      *) echo "error: $path is not a .xcarchive, .ipa or .app" >&2; exit 2 ;;
    esac
    [[ ${#apps[@]} -gt 0 ]] || { echo "error: no .app inside $(basename "$path")" >&2; exit 1; }
    for app in "${apps[@]}"; do check_app "$app"; done
    ;;
  *)
    echo "usage: $0 settings | archive PATH" >&2
    exit 2
    ;;
esac

if [[ $ERRORS -gt 0 ]]; then
  echo "error: $ERRORS release config problem(s). A Release build reads only Config/Secrets.Release.xcconfig" >&2
  echo "       (copy Config/Secrets.example.xcconfig) and its identity from Config/Identity.xcconfig" >&2
  echo "       (copy Config/Identity.example.xcconfig); values were not printed." >&2
  exit 1
fi
echo "==> Release config OK ($mode${2:+: $(basename "$2")}): https non-local URL, production, keys and identity present"
