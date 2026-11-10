#!/bin/bash
# Download, verify and copy Checker. Configure connections in the app.
set -euo pipefail
umask 077

fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
value() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
download() { /usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 --retry 2 "$1" -o "$2"; }
checker_home="${HOME}"
checker_version=""
checker_image=""
checker_hash=""
checker_yes=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes) checker_yes=yes; shift ;;
        --version|--install-home|--local-dmg|--sha256)
            [ "$#" -ge 2 ] || fail "Missing value for $1."
            case "$1" in
                --version) checker_version="$2" ;;
                --install-home) checker_home="$2" ;;
                --local-dmg) checker_image="$2" ;;
                --sha256) checker_hash="$2" ;;
            esac
            shift 2 ;;
        --help|-h)
            printf '%s\n' 'Usage: /bin/bash install.sh --yes [--version X.Y.Z]' \
                'Advanced: --install-home PATH, --local-dmg PATH --sha256 HASH' \
                'Installs the app only. Open Checker and use its connection settings afterward.'
            exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[ "$(/usr/bin/uname -s)" = Darwin ] || fail "Checker requires macOS."
[ "$(/usr/bin/id -u)" != 0 ] || fail "Run as your normal user, without sudo."
checker_os=$(/usr/bin/sw_vers -productVersion)
[ "${checker_os%%.*}" -ge 13 ] || fail "Checker requires macOS 13 or later."
if [ "$(/usr/bin/uname -m)" != arm64 ] && [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" != 1 ]; then fail "Checker requires Apple Silicon."; fi
case "$checker_home" in /*) ;; *) fail "Use an absolute installation home." ;; esac
case "$checker_home" in /|*$'\n'*) fail "Invalid installation home." ;; esac
[ -d "$checker_home" ] || fail "The installation home does not exist."
checker_home=$(CDPATH= cd -- "$checker_home" && pwd -P)
[ "$(/usr/bin/stat -f %u "$checker_home")" = "$(/usr/bin/id -u)" ] || fail "The installation home must belong to you."
checker_app="$checker_home/Applications/Checker.app"
if [ -n "$checker_version" ]; then printf '%s' "$checker_version" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "Invalid version."; fi
[ ! -L "$checker_app" ] || fail "An existing Checker symlink was preserved."
if [ -e "$checker_app" ]; then
    [ "$(value "$checker_app/Contents/Info.plist" CFBundleIdentifier || true)" = local.checker.prototype ] || fail "A different app named Checker was preserved."
fi

checker_tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/checker-install.XXXXXX")
checker_mounted=no
checker_stage=""
checker_backup=""
cleanup() {
    if [ "$checker_mounted" = yes ]; then /usr/bin/hdiutil detach "$checker_tmp/mounted" >/dev/null 2>&1 || true; fi
    if [ -n "$checker_backup" ] && [ -d "$checker_backup" ] && [ ! -e "$checker_app" ]; then /bin/mv "$checker_backup" "$checker_app"; fi
    if [ -n "$checker_stage" ]; then /bin/rm -rf "$checker_stage"; fi
    /bin/rm -rf "$checker_tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
already_installed() {
    [ -d "$checker_app" ] && [ "$(value "$checker_app/Contents/Info.plist" CFBundleShortVersionString || true)" = "$checker_version" ] &&
        /usr/bin/codesign --verify --deep --strict "$checker_app" >/dev/null 2>&1
}
done_existing() { printf 'Already installed: Checker %s\nApp: %s\n' "$checker_version" "$checker_app"; exit 0; }

if [ -z "$checker_image" ]; then
    checker_manifest=https://raw.githubusercontent.com/ruvora/checker/main/install.json
    if [ -n "$checker_version" ]; then checker_manifest="https://github.com/ruvora/checker/releases/download/v$checker_version/install.json"; fi
    download "$checker_manifest" "$checker_tmp/install.json"
    [ "$(value "$checker_tmp/install.json" schemaVersion)" = 1 ] || fail "Unsupported download manifest."
    checker_release=$(value "$checker_tmp/install.json" version)
    printf '%s' "$checker_release" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "Invalid release version."
    if [ -n "$checker_version" ]; then [ "$checker_version" = "$checker_release" ] || fail "The manifest belongs to another version."; fi
    checker_version="$checker_release"
    checker_url=$(value "$checker_tmp/install.json" downloadURL)
    [ "$checker_url" = "https://github.com/ruvora/checker/releases/download/v$checker_version/Checker-$checker_version-macOS-arm64.dmg" ] || fail "The download must come from ruvora/checker."
    checker_hash=$(value "$checker_tmp/install.json" sha256)
    if already_installed; then done_existing; fi
    checker_image="$checker_tmp/Checker.dmg"
    download "$checker_url" "$checker_image"
fi
printf '%s' "$checker_hash" | /usr/bin/grep -Eq '^[a-f0-9]{64}$' || fail "A valid SHA-256 checksum is required."
[ -f "$checker_image" ] || fail "Disk image not found."
[ "$(/usr/bin/shasum -a 256 "$checker_image" | /usr/bin/awk '{print $1}')" = "$checker_hash" ] || fail "Disk image checksum mismatch. Nothing was installed."
/bin/mkdir "$checker_tmp/mounted"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$checker_tmp/mounted" "$checker_image" >/dev/null
checker_mounted=yes
checker_source="$checker_tmp/mounted/Checker.app"
[ "$(value "$checker_source/Contents/Info.plist" CFBundleIdentifier)" = local.checker.prototype ] || fail "This is not Checker."
checker_release=$(value "$checker_source/Contents/Info.plist" CFBundleShortVersionString)
printf '%s' "$checker_release" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "Invalid app version."
if [ -n "$checker_version" ]; then [ "$checker_version" = "$checker_release" ] || fail "App and requested versions do not match."; fi
checker_version="$checker_release"
/usr/bin/codesign --verify --deep --strict "$checker_source" >/dev/null 2>&1
if already_installed; then done_existing; fi
if /bin/ps -axo comm= | /usr/bin/grep -Fx "$checker_app/Contents/MacOS/Checker" >/dev/null; then fail "Quit Checker before updating it."; fi
if [ "$checker_yes" != yes ]; then
    [ -t 0 ] || fail "Pass --yes after requesting installation."
    printf 'Install Checker %s into %s? [y/N] ' "$checker_version" "$checker_home/Applications" >&2
    read -r checker_answer
    case "$checker_answer" in y|Y|yes|YES) ;; *) printf 'Cancelled.\n'; exit 0 ;; esac
fi

/bin/mkdir -p "$checker_home/Applications"
checker_apps_real=$(CDPATH= cd -- "$checker_home/Applications" && pwd -P)
case "$checker_apps_real" in "$checker_home"/*) ;; *) fail "The Applications folder resolves outside your home." ;; esac
checker_stage=$(/usr/bin/mktemp -d "$checker_home/Applications/.checker-install.XXXXXX")
/usr/bin/ditto "$checker_source" "$checker_stage/Checker.app"
/usr/bin/codesign --verify --deep --strict "$checker_stage/Checker.app" >/dev/null 2>&1
if [ -d "$checker_app" ]; then
    /bin/mkdir -p "$checker_home/Library/Application Support/Checker/app-backups"
    checker_backup_dir=$(/usr/bin/mktemp -d "$checker_home/Library/Application Support/Checker/app-backups/previous.XXXXXX")
    checker_backup="$checker_backup_dir/Checker.app"
    /bin/mv "$checker_app" "$checker_backup"
fi
/bin/mv "$checker_stage/Checker.app" "$checker_app"
printf 'Installed Checker %s\nApp: %s\n' "$checker_version" "$checker_app"
if [ -n "$checker_backup" ]; then printf 'Previous app: %s\n' "$checker_backup"; fi
printf 'Open Checker and choose Settings & connections → Install selected connections.\n'
