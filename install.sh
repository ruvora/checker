#!/bin/bash
# Checker agent installer. macOS system tools only; no sudo or developer tools.
set -eEuo pipefail
umask 077

if [ "$(/usr/bin/uname -s)" != Darwin ]; then
    printf '%s\n' '{"status":"unsupported","message":"Checker requires macOS 13 or later on Apple Silicon."}'
    exit 1
fi

checker_tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/checker-install.XXXXXX")
checker_mount=""
checker_mounted=no
checker_stage_app=""
checker_backup=""
checker_app=""
checker_version=""
checker_stage=arguments
checker_home="${HOME}"
checker_profile=auto
checker_language=auto
checker_yes=no
checker_plan=no
checker_local_dmg=""
checker_sha=""
checker_requested_version=""
checker_status_id=""
checker_timeout=20

cleanup() {
    if [ "$checker_mounted" = yes ]; then /usr/bin/hdiutil detach "$checker_mount" >/dev/null 2>&1 || true; fi
    if [ -n "$checker_stage_app" ] && [ -d "$checker_stage_app" ]; then /bin/rm -rf "$checker_stage_app"; fi
    if [ -n "$checker_backup" ] && [ -d "$checker_backup" ] && [ ! -e "$checker_app" ]; then /bin/mv "$checker_backup" "$checker_app"; fi
    /bin/rm -rf "$checker_tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

report() {
    local state="$1" message="$2"
    local file="$checker_tmp/report.json"
    /bin/rm -f "$file"
    /usr/bin/plutil -create xml1 "$file"
    /usr/bin/plutil -insert status -string "$state" "$file"
    /usr/bin/plutil -insert stage -string "$checker_stage" "$file"
    /usr/bin/plutil -insert message -string "$message" "$file"
    /usr/bin/plutil -insert version -string "$checker_version" "$file"
    /usr/bin/plutil -insert appPath -string "$checker_app" "$file"
    if [ -n "${checker_id:-}" ]; then /usr/bin/plutil -insert requestID -string "$checker_id" "$file"; fi
    if [ -n "$checker_backup" ]; then /usr/bin/plutil -insert previousAppBackup -string "$checker_backup" "$file"; fi
    /usr/bin/plutil -convert json -o - "$file"
    printf '\n'
}
fail() { report error "$1"; exit 1; }
unexpected() { trap - ERR; report error "Installation stopped during $checker_stage. Your checklist data was not removed."; exit 1; }
trap unexpected ERR
get_json() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
valid_version() { printf '%s' "$1" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }
valid_uuid() { printf '%s' "$1" | /usr/bin/grep -Eiq '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'; }
download() { /usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 "$1" -o "$2"; }
usage() {
    cat <<'HELP'
Checker installer
  /bin/bash install.sh --yes [--language en|ko|auto] [--connections auto|all|none|codex,chrome,claude]
  /bin/bash install.sh --plan
  /bin/bash install.sh --status REQUEST_ID

Options:
  --version X.Y.Z             Pin an official release (default: published install.json).
  --install-home PATH         Install into PATH/Applications and use its isolated app data.
  --local-dmg PATH --sha256 H  Verify and install an already downloaded DMG.
  --timeout SECONDS           Wait up to 1–60 seconds for the app's setup receipt (default 20).

The installer preserves your checklist and existing unrelated connections. It never
disables Gatekeeper, removes quarantine, modifies Chrome profiles/policies, or installs
Codex/Claude/Chrome themselves. macOS approval and Chrome extension loading stay with you.
HELP
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes) checker_yes=yes; shift ;;
        --plan) checker_plan=yes; shift ;;
        --language|--connections|--install-home|--local-dmg|--sha256|--version|--status|--timeout)
            [ "$#" -ge 2 ] || fail "Missing value for $1."
            case "$1" in
                --language) checker_language="$2" ;;
                --connections) checker_profile="$2" ;;
                --install-home) checker_home="$2" ;;
                --local-dmg) checker_local_dmg="$2" ;;
                --sha256) checker_sha="$2" ;;
                --version) checker_requested_version="$2" ;;
                --status) checker_status_id="$2" ;;
                --timeout) checker_timeout="$2" ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[ "$(/usr/bin/id -u)" != 0 ] || fail "Run as your normal macOS user. Do not use sudo."
case "$checker_language" in auto|en|ko) ;; *) fail "Choose --language en, ko, or auto." ;; esac
case "$checker_home" in /*) ;; *) fail "The installation home must be an absolute path." ;; esac
case "$checker_home" in /|*$'\n'*) fail "Invalid installation home." ;; esac
[ -d "$checker_home" ] || fail "The installation home does not exist."
checker_home=$(CDPATH= cd -- "$checker_home" && pwd -P)
[ "$(/usr/bin/stat -f %u "$checker_home")" = "$(/usr/bin/id -u)" ] || fail "The installation home must belong to the current user."
checker_app="$checker_home/Applications/Checker.app"
checker_data="$checker_home/Library/Application Support/Checker"

read_receipt() {
    local receipt="$checker_data/installations/$checker_id.json"
    [ -f "$receipt" ] || return 1
    [ "$(get_json "$receipt" requestID)" = "$checker_id" ] || fail "Unexpected setup receipt."
    local receipt_app
    receipt_app=$(get_json "$receipt" appPath)
    [ "$receipt_app" -ef "$checker_app" ] || fail "The setup receipt belongs to another Checker installation."
    local state
    state=$(get_json "$receipt" status)
    if [ "$state" = configured ] || [ "$state" = error ]; then
        /bin/cp "$receipt" "$checker_tmp/result.json"
        /usr/bin/plutil -convert xml1 "$checker_tmp/result.json"
        /usr/bin/plutil -insert receiptPath -string "$receipt" "$checker_tmp/result.json"
        if [ -n "$checker_backup" ]; then /usr/bin/plutil -insert previousAppBackup -string "$checker_backup" "$checker_tmp/result.json"; fi
        /usr/bin/plutil -convert json -o - "$checker_tmp/result.json"; printf '\n'
        if [ "$state" = configured ]; then exit 0; else exit 1; fi
    fi
    return 1
}
if [ -n "$checker_status_id" ]; then
    valid_uuid "$checker_status_id" || fail "Invalid setup request ID."
    checker_id=$(printf '%s' "$checker_status_id" | /usr/bin/tr '[:upper:]' '[:lower:]')
    checker_stage=status
    read_receipt || true
    report needs_user_action "Setup is not finished. Open Checker from Applications and complete any macOS approval, then check this request again."
    exit 2
fi

checker_stage=preflight
checker_os=$(/usr/bin/sw_vers -productVersion)
[ "${checker_os%%.*}" -ge 13 ] || fail "Checker requires macOS 13 or later."
if [ "$(/usr/bin/uname -m)" != arm64 ] && [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" != 1 ]; then fail "This release requires Apple Silicon (M1 or later)."; fi
printf '%s' "$checker_timeout" | /usr/bin/grep -Eq '^[0-9]+$' || fail "Invalid timeout."
[ "$checker_timeout" -ge 1 ] && [ "$checker_timeout" -le 60 ] || fail "Timeout must be 1–60 seconds."
if [ -n "$checker_requested_version" ]; then
    valid_version "$checker_requested_version" || fail "Invalid release version."
    checker_version="$checker_requested_version"
fi
if [ -L "$checker_app" ]; then fail "An existing Checker app symlink was preserved. Review it before installing."; fi
if [ -e "$checker_app" ]; then
    [ -d "$checker_app" ] && [ "$(get_json "$checker_app/Contents/Info.plist" CFBundleIdentifier || true)" = local.checker.prototype ] || fail "A different app named Checker was preserved."
fi

checker_connections=""
add_connection() { if [ -n "$checker_connections" ]; then checker_connections="$checker_connections,$1"; else checker_connections="$1"; fi; }
if [ "$checker_profile" = auto ]; then
    for candidate in /Applications/Codex.app /Applications/ChatGPT.app "$checker_home/Applications/Codex.app" "$checker_home/Applications/ChatGPT.app"; do
        if [ -d "$candidate" ]; then add_connection codex; break; fi
    done
    if [ -d /Applications/Google\ Chrome.app ] || [ -d "$checker_home/Applications/Google Chrome.app" ]; then add_connection chrome; fi
    if [ -d /Applications/Claude.app ] || [ -d "$checker_home/Applications/Claude.app" ]; then add_connection claude; fi
elif [ "$checker_profile" = all ]; then checker_connections=codex,chrome,claude
elif [ "$checker_profile" != none ]; then
    case ",$checker_profile," in *,,*) fail "Invalid connection list." ;; esac
    checker_old_ifs=$IFS; IFS=,; read -r -a checker_parts <<< "$checker_profile"; IFS=$checker_old_ifs
    for part in "${checker_parts[@]}"; do case "$part" in codex|chrome|claude) add_connection "$part" ;; *) fail "Unknown connection: $part" ;; esac; done
fi
[ -n "$checker_connections" ] || checker_connections=none
if [ "$checker_plan" = yes ]; then
    report planned "Install the official verified Checker release into this user's Applications folder and register connections: $checker_connections. macOS and Chrome approvals remain manual."
    exit 0
fi
if [ "$checker_yes" != yes ]; then
    if [ ! -t 0 ]; then fail "Read install.sh first, then pass --yes when the user has requested installation."; fi
    printf 'Install Checker in %s and register %s? [y/N] ' "$checker_home/Applications" "$checker_connections" >&2
    read -r checker_answer
    case "$checker_answer" in y|Y|yes|YES) ;; *) report cancelled "Installation cancelled."; exit 0 ;; esac
fi

checker_stage=download
if [ -n "$checker_local_dmg" ]; then
    [ -f "$checker_local_dmg" ] || fail "The local disk image was not found."
    checker_dmg=$(CDPATH= cd -- "$(dirname -- "$checker_local_dmg")" && pwd -P)/$(basename -- "$checker_local_dmg")
else
    checker_manifest_url=https://raw.githubusercontent.com/ruvora/checker/main/install.json
    if [ -n "$checker_requested_version" ]; then checker_manifest_url="https://github.com/ruvora/checker/releases/download/v$checker_requested_version/install.json"; fi
    download "$checker_manifest_url" "$checker_tmp/install.json"
    [ "$(get_json "$checker_tmp/install.json" schemaVersion)" = 1 ] || fail "Unsupported installer manifest."
    [ "$(get_json "$checker_tmp/install.json" protocolVersion)" = 1 ] || fail "Unsupported agent installation protocol."
    checker_version=$(get_json "$checker_tmp/install.json" version)
    valid_version "$checker_version" || fail "Invalid manifest version."
    if [ -n "$checker_requested_version" ]; then [ "$checker_version" = "$checker_requested_version" ] || fail "The manifest belongs to another release."; fi
    checker_url=$(get_json "$checker_tmp/install.json" downloadURL)
    checker_expected_url="https://github.com/ruvora/checker/releases/download/v$checker_version/Checker-$checker_version-macOS-arm64.dmg"
    [ "$checker_url" = "$checker_expected_url" ] || fail "The download must come from the official ruvora/checker release."
    checker_sha=$(get_json "$checker_tmp/install.json" sha256)
    checker_dmg="$checker_tmp/Checker.dmg"
    download "$checker_url" "$checker_dmg"
fi
printf '%s' "$checker_sha" | /usr/bin/grep -Eq '^[a-f0-9]{64}$' || fail "A valid SHA-256 checksum is required."
checker_actual=$(/usr/bin/shasum -a 256 "$checker_dmg" | /usr/bin/awk '{print $1}')
[ "$checker_actual" = "$checker_sha" ] || fail "The disk image checksum does not match. Nothing was installed."

checker_stage=verify
checker_mount="$checker_tmp/mounted"
/bin/mkdir "$checker_mount"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$checker_mount" "$checker_dmg" >/dev/null
checker_mounted=yes
checker_source="$checker_mount/Checker.app"
[ "$(get_json "$checker_source/Contents/Info.plist" CFBundleIdentifier)" = local.checker.prototype ] || fail "This is not the Checker app."
[ "$(get_json "$checker_source/Contents/Info.plist" CheckerAgentInstallVersion || true)" = 1 ] || fail "This app does not support agent setup. Use Checker 0.4.0 or later."
checker_app_version=$(get_json "$checker_source/Contents/Info.plist" CFBundleShortVersionString)
valid_version "$checker_app_version" || fail "Invalid Checker version."
if [ -n "$checker_version" ]; then [ "$checker_app_version" = "$checker_version" ] || fail "App and manifest versions do not match."; fi
checker_version="$checker_app_version"
/usr/bin/codesign --verify --deep --strict "$checker_source" >/dev/null 2>&1

checker_stage=install
/bin/mkdir -p "$checker_home/Applications"
checker_apps_real=$(CDPATH= cd -- "$checker_home/Applications" && pwd -P)
case "$checker_apps_real" in "$checker_home"/*) ;; *) fail "The Applications folder resolves outside the installation home." ;; esac
checker_id=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')
checker_stage_app="$checker_home/Applications/.Checker-$checker_id.app"
/usr/bin/ditto "$checker_source" "$checker_stage_app"
/usr/bin/codesign --verify --deep --strict "$checker_stage_app" >/dev/null 2>&1
/usr/bin/hdiutil detach "$checker_mount" >/dev/null
checker_mounted=no

# Only stop this user's exact target executable. Other Checker installs, Claude,
# Chrome and Codex processes are never interrupted by this installer.
checker_pids=""
while read -r process_uid process_pid process_command; do
    if [ "$process_uid" = "$(/usr/bin/id -u)" ] && [ "$process_command" = "$checker_app/Contents/MacOS/Checker" ]; then checker_pids="$checker_pids $process_pid"; fi
done < <(/bin/ps -axo uid=,pid=,comm=)
for process_pid in $checker_pids; do /bin/kill -TERM "$process_pid"; done
for process_pid in $checker_pids; do
    for attempt in {1..30}; do if ! /bin/kill -0 "$process_pid" 2>/dev/null; then break; fi; /bin/sleep 0.1; done
    if /bin/kill -0 "$process_pid" 2>/dev/null; then fail "Checker is still exiting. Close it and retry."; fi
done
if [ -d "$checker_app" ]; then
    /bin/mkdir -p "$checker_data/app-backups"
    checker_backup="$checker_data/app-backups/Checker-before-$checker_version-$checker_id.app"
    /bin/mv "$checker_app" "$checker_backup"
fi
/bin/mv "$checker_stage_app" "$checker_app"
checker_stage_app=""

checker_stage=setup
/bin/mkdir -p "$checker_data/installations"
checker_pending="$checker_data/installations/pending.json"
checker_request="$checker_tmp/pending.json"
/usr/bin/plutil -create xml1 "$checker_request"
/usr/bin/plutil -insert schemaVersion -integer 1 "$checker_request"
/usr/bin/plutil -insert requestID -string "$checker_id" "$checker_request"
/usr/bin/plutil -insert createdAt -integer "$(/bin/date +%s)" "$checker_request"
/usr/bin/plutil -insert home -string "$checker_home" "$checker_request"
/usr/bin/plutil -insert connections -string "$checker_connections" "$checker_request"
/usr/bin/plutil -insert language -string "$checker_language" "$checker_request"
/usr/bin/plutil -convert json "$checker_request"
/bin/chmod 600 "$checker_request"
/bin/mv "$checker_request" "$checker_pending"

# Assessment happens before executing any code from the downloaded app. An
# unsigned preview stays pending until the user approves its normal macOS launch.
if ! /usr/sbin/spctl --assess --type execute "$checker_app" >/dev/null 2>&1; then
    checker_stage=macos_approval
    /usr/bin/open -R "$checker_app" >/dev/null 2>&1 || true
    report needs_user_action "Checker was verified and copied to Applications. Open it in Finder and complete macOS approval. Setup will continue inside the app. Then run install.sh --status $checker_id with the same --install-home, if used."
    exit 2
fi
checker_stage=launch
checker_open=(/usr/bin/open)
if [ "$checker_home" != "${HOME}" ]; then checker_open+=(-n); fi
checker_open+=("$checker_app" --args --data-dir "$checker_data")
if ! "${checker_open[@]}" >/dev/null 2>&1; then
    report needs_user_action "Open Checker from Applications and complete macOS approval, then check the setup request."
    exit 2
fi
for ((attempt=0; attempt<checker_timeout*5; attempt++)); do read_receipt || true; /bin/sleep 0.2; done
if [ -f "$checker_data/installations/$checker_id.json" ]; then
    report in_progress "Checker is still configuring connections. Check this request again shortly."
    exit 3
fi
report needs_user_action "Open Checker from Applications and finish any macOS approval, then check this setup request."
exit 2
