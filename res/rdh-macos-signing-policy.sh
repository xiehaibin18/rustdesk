#!/bin/bash

set -euo pipefail

fail() {
    printf 'signing_policy_error=%s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  rdh-macos-signing-policy.sh --check-reports <baseline-report> <candidate-report>
  rdh-macos-signing-policy.sh --promote \
    --input-dmg <path> \
    --input-sha256 <path> \
    --input-metadata <path> \
    --baseline-app <path> \
    --identity <codesigning-sha1> \
    --output-dir </Volumes/DevData/path>

The CI DMG is build-only. --promote creates a separate Apple Development-signed
DMG and metadata after verifying Team ID, Designated Requirement, and entitlement
continuity against the baseline app. It never installs an application.
EOF
}

read_field() {
    local report="$1"
    local key="$2"
    local count
    local value

    [[ -f "$report" ]] || fail "missing report: $report"
    count="$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$report")"
    [[ "$count" == "1" ]] || fail "report must contain exactly one $key field: $report"
    value="$(awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$report")"
    [[ -n "$value" ]] || fail "empty $key field: $report"
    printf '%s' "$value"
}

require_sha256() {
    [[ "$1" =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA-256 value for $2"
}

verify_report_pair() {
    local baseline_report="$1"
    local candidate_report="$2"
    local baseline_signature
    local candidate_signature
    local baseline_team
    local candidate_team
    local baseline_bundle
    local candidate_bundle
    local baseline_requirement
    local candidate_requirement
    local baseline_entitlements
    local candidate_entitlements

    baseline_signature="$(read_field "$baseline_report" signature)"
    candidate_signature="$(read_field "$candidate_report" signature)"
    baseline_team="$(read_field "$baseline_report" team_id)"
    candidate_team="$(read_field "$candidate_report" team_id)"
    baseline_bundle="$(read_field "$baseline_report" bundle_id)"
    candidate_bundle="$(read_field "$candidate_report" bundle_id)"
    baseline_requirement="$(read_field "$baseline_report" designated_requirement_sha256)"
    candidate_requirement="$(read_field "$candidate_report" designated_requirement_sha256)"
    baseline_entitlements="$(read_field "$baseline_report" entitlements_sha256)"
    candidate_entitlements="$(read_field "$candidate_report" entitlements_sha256)"

    [[ "$baseline_signature" != "ad-hoc" && "$baseline_team" != "not set" ]] ||
        fail "baseline must be certificate-signed"
    [[ "$candidate_signature" != "ad-hoc" && "$candidate_team" != "not set" ]] ||
        fail "candidate must be certificate-signed"
    [[ "$baseline_bundle" == "com.herbin.rustdesk" ]] || fail "unexpected baseline bundle ID"
    [[ "$candidate_bundle" == "$baseline_bundle" ]] || fail "candidate bundle ID does not match baseline"
    [[ "$candidate_team" == "$baseline_team" ]] || fail "candidate Team ID does not match baseline"
    require_sha256 "$baseline_requirement" "baseline Designated Requirement"
    require_sha256 "$candidate_requirement" "candidate Designated Requirement"
    [[ "$candidate_requirement" == "$baseline_requirement" ]] ||
        fail "candidate Designated Requirement does not match baseline"
    require_sha256 "$baseline_entitlements" "baseline entitlements"
    require_sha256 "$candidate_entitlements" "candidate entitlements"
    [[ "$candidate_entitlements" == "$baseline_entitlements" ]] ||
        fail "candidate entitlements do not match baseline"

    printf 'signing_continuity=ok team_id=%s\n' "$candidate_team"
}

canonicalize_entitlements() {
    local app="$1"
    local output="$2"
    local raw

    raw="${output}.raw"
    codesign -d --entitlements :- "$app" >"$raw" 2>/dev/null
    python3 - "$raw" "$output" <<'PY'
import json
import plistlib
import sys

source, destination = sys.argv[1:]
with open(source, "rb") as handle:
    value = plistlib.load(handle)
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
}

write_app_report() {
    local app="$1"
    local report="$2"
    local details
    local signature
    local team_id
    local bundle_id
    local requirement
    local requirement_sha
    local entitlements
    local entitlements_sha

    [[ -d "$app" ]] || fail "missing app: $app"
    codesign --verify --deep --strict "$app"
    details="$(codesign -dvvv "$app" 2>&1)"
    if printf '%s\n' "$details" | grep -q '^Signature=adhoc$'; then
        signature="ad-hoc"
    elif printf '%s\n' "$details" | grep -q '^Authority=Apple Development:'; then
        signature="apple-development"
    else
        signature="certificate"
    fi
    team_id="$(printf '%s\n' "$details" | awk -F= '/^TeamIdentifier=/{ print $2; exit }')"
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
    requirement="$(codesign -dr - "$app" 2>&1 | sed -n 's/^# \{0,1\}//; /designated =>/p')"
    [[ -n "$requirement" ]] || fail "missing Designated Requirement: $app"
    requirement_sha="$(printf '%s\n' "$requirement" | shasum -a 256 | awk '{ print $1 }')"
    entitlements="${report}.entitlements.json"
    canonicalize_entitlements "$app" "$entitlements"
    entitlements_sha="$(shasum -a 256 "$entitlements" | awk '{ print $1 }')"

    {
        printf 'signature=%s\n' "$signature"
        printf 'team_id=%s\n' "${team_id:-not set}"
        printf 'bundle_id=%s\n' "$bundle_id"
        printf 'designated_requirement_sha256=%s\n' "$requirement_sha"
        printf 'entitlements_sha256=%s\n' "$entitlements_sha"
    } >"$report"
    printf '%s\n' "$requirement" >"${report}.designated-requirement.txt"
}

if [[ "${1:-}" == "--check-reports" ]]; then
    [[ "$#" == "3" ]] || fail "--check-reports requires baseline and candidate reports"
    verify_report_pair "$2" "$3"
    exit 0
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

[[ "${1:-}" == "--promote" ]] || {
    usage >&2
    exit 2
}
shift

input_dmg=""
input_sha256=""
input_metadata=""
baseline_app=""
identity=""
output_dir=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --input-dmg) input_dmg="${2:-}"; shift 2 ;;
        --input-sha256) input_sha256="${2:-}"; shift 2 ;;
        --input-metadata) input_metadata="${2:-}"; shift 2 ;;
        --baseline-app) baseline_app="${2:-}"; shift 2 ;;
        --identity) identity="${2:-}"; shift 2 ;;
        --output-dir) output_dir="${2:-}"; shift 2 ;;
        *) fail "unknown promotion argument: $1" ;;
    esac
done

for required_value in "$input_dmg" "$input_sha256" "$input_metadata" "$baseline_app" "$identity" "$output_dir"; do
    [[ -n "$required_value" ]] || fail "promotion argument is empty"
done
[[ -f "$input_dmg" ]] || fail "missing input DMG"
[[ -f "$input_sha256" ]] || fail "missing input SHA-256 file"
[[ -f "$input_metadata" ]] || fail "missing input metadata"
[[ -d "$baseline_app" ]] || fail "missing baseline app"
[[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]] || fail "identity must be a 40-character SHA-1"
[[ "$output_dir" == /Volumes/DevData/* ]] || fail "output directory must be under /Volumes/DevData"
[[ ! -e "$output_dir" ]] || fail "output directory already exists"
[[ -d "$(dirname "$output_dir")" ]] || fail "output directory parent does not exist"

metadata_signature="$(read_field "$input_metadata" signature)"
metadata_installable="$(read_field "$input_metadata" installable)"
metadata_promotion="$(read_field "$input_metadata" requires_local_signing_promotion)"
metadata_notarized="$(read_field "$input_metadata" notarized)"
source_commit="$(read_field "$input_metadata" source_commit)"
upstream_version="$(read_field "$input_metadata" upstream_version)"
rdh_revision="$(read_field "$input_metadata" rdh_revision)"
input_artifact="$(read_field "$input_metadata" artifact)"
[[ "$source_commit" =~ ^[0-9A-Fa-f]{40}$ ]] || fail "input source commit must be a 40-character SHA-1"
[[ "$rdh_revision" =~ ^[0-9]+$ ]] || fail "input RDH revision must be numeric"
[[ "$metadata_signature" == "ad-hoc" ]] || fail "input metadata signature must be ad-hoc"
[[ "$metadata_installable" == "false" ]] || fail "input metadata must be installable=false"
[[ "$metadata_promotion" == "true" ]] || fail "input metadata must require local signing promotion"
[[ "$metadata_notarized" == "false" ]] || fail "input metadata notarized field must be false"
[[ "$input_artifact" == "$(basename "$input_dmg")" ]] || fail "input artifact name does not match metadata"

expected_input_sha="$(awk 'NR == 1 { print $1 }' "$input_sha256")"
actual_input_sha="$(shasum -a 256 "$input_dmg" | awk '{ print $1 }')"
require_sha256 "$expected_input_sha" "input checksum"
[[ "$actual_input_sha" == "$expected_input_sha" ]] || fail "input DMG checksum mismatch"

for command_name in awk codesign ditto file find grep hdiutil plutil python3 security shasum; do
    command -v "$command_name" >/dev/null || fail "missing command: $command_name"
done
identity="$(printf '%s' "$identity" | tr '[:lower:]' '[:upper:]')"
security find-identity -p codesigning -v | grep -F "$identity" >/dev/null ||
    fail "requested Apple Development identity is unavailable"

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
release_entitlements="$repo_root/flutter/macos/Runner/Release.entitlements"
[[ -f "$release_entitlements" ]] || fail "missing release entitlements"

mkdir -m 700 "$output_dir"
work_dir="$output_dir/work"
package_root="$output_dir/package-root"
mkdir -m 700 "$work_dir" "$package_root"
baseline_report="$output_dir/baseline-signing-report.txt"
candidate_report="$output_dir/candidate-signing-report.txt"
promotion_entitlements="$output_dir/promotion-entitlements.plist"
cp "$release_entitlements" "$promotion_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$promotion_entitlements" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c 'Set :com.apple.security.cs.disable-library-validation true' "$promotion_entitlements"
plutil -lint "$promotion_entitlements" >/dev/null

write_app_report "$baseline_app" "$baseline_report"
[[ "$(read_field "$baseline_report" signature)" == "apple-development" ]] ||
    fail "baseline must use Apple Development signing"

attach_output="$(hdiutil attach -readonly -nobrowse "$input_dmg")"
mount_point="$(printf '%s\n' "$attach_output" | awk -F '\t' '/\/Volumes\// { print $NF; exit }')"
device="$(printf '%s\n' "$attach_output" | awk -F '\t' '/Apple_HFS|Apple_APFS/ { print $1; exit }')"
cleanup_mount() {
    if [[ -n "${device:-}" ]]; then
        hdiutil detach "$device" >/dev/null 2>&1 || true
    fi
}
trap cleanup_mount EXIT

source_app="$mount_point/RustDesk-Herbin.app"
work_app="$work_dir/RustDesk-Herbin.app"
[[ -d "$source_app" ]] || fail "input DMG does not contain RustDesk-Herbin.app"
[[ "$("$source_app/Contents/MacOS/RustDesk-Herbin" --version)" == "RustDesk-Herbin ${upstream_version}-rdh.${rdh_revision}" ]] ||
    fail "input app version does not match metadata"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" == "com.herbin.rustdesk" ]] ||
    fail "input app bundle ID mismatch"
codesign --verify --deep --strict "$source_app"
ditto "$source_app" "$work_app"

while IFS= read -r -d '' code_file; do
    if file "$code_file" | grep -q 'Mach-O'; then
        codesign --force --sign "$identity" --options runtime --timestamp=none "$code_file"
    fi
done < <(find "$work_app/Contents" -type f -print0)

while IFS= read -r -d '' framework; do
    codesign --force --sign "$identity" --options runtime --timestamp=none "$framework"
done < <(find "$work_app/Contents/Frameworks" -type d -name '*.framework' -prune -print0)

codesign \
    --force \
    --sign "$identity" \
    --options runtime \
    --timestamp=none \
    --entitlements "$promotion_entitlements" \
    "$work_app"
codesign --verify --deep --strict --verbose=4 "$work_app"

write_app_report "$work_app" "$candidate_report"
verify_report_pair "$baseline_report" "$candidate_report"

ditto "$work_app" "$package_root/RustDesk-Herbin.app"
codesign --verify --deep --strict "$package_root/RustDesk-Herbin.app"

dmg_name="rustdesk-herbin-${upstream_version}-rdh.${rdh_revision}-aarch64-apple-development.dmg"
dmg_path="$output_dir/$dmg_name"
hdiutil create \
    -volname "RustDesk-Herbin ${upstream_version}-rdh.${rdh_revision} Apple Development" \
    -srcfolder "$package_root" \
    -format UDZO \
    "$dmg_path"
(
    cd "$output_dir"
    shasum -a 256 "$dmg_name" >"$dmg_name.sha256"
)
hdiutil verify "$dmg_path"

team_id="$(read_field "$candidate_report" team_id)"
baseline_requirement_sha="$(read_field "$baseline_report" designated_requirement_sha256)"
candidate_requirement_sha="$(read_field "$candidate_report" designated_requirement_sha256)"
baseline_entitlements_sha="$(read_field "$baseline_report" entitlements_sha256)"
candidate_entitlements_sha="$(read_field "$candidate_report" entitlements_sha256)"
{
    printf 'artifact=%s\n' "$dmg_name"
    printf 'upstream_version=%s\n' "$upstream_version"
    printf 'rdh_revision=%s\n' "$rdh_revision"
    printf 'source_commit=%s\n' "$source_commit"
    printf 'input_artifact=%s\n' "$input_artifact"
    printf 'input_dmg_sha256=%s\n' "$actual_input_sha"
    printf 'signature=apple-development\n'
    printf 'signing_identity_sha1=%s\n' "$identity"
    printf 'team_id=%s\n' "$team_id"
    printf 'baseline_designated_requirement_sha256=%s\n' "$baseline_requirement_sha"
    printf 'candidate_designated_requirement_sha256=%s\n' "$candidate_requirement_sha"
    printf 'baseline_entitlements_sha256=%s\n' "$baseline_entitlements_sha"
    printf 'candidate_entitlements_sha256=%s\n' "$candidate_entitlements_sha"
    printf 'installable=true\n'
    printf 'requires_local_signing_promotion=false\n'
    printf 'notarized=false\n'
} >"$output_dir/rdh-promotion-metadata.txt"

printf 'promotion=complete app=%s dmg=%s team_id=%s source_commit=%s\n' \
    "$work_app" "$dmg_path" "$team_id" "$source_commit"
