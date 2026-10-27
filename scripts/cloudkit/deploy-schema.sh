#!/bin/bash
# Imports the OpenArc CloudKit schema into the Development environment (plan D4).
#
# Usage:
#   scripts/cloudkit/deploy-schema.sh [--token-file FILE] [--validate-only] [--backup-dir DIR]
#
#   --token-file     file whose first line is a CloudKit *management* token (CloudKit Console →
#                    Settings → Tokens). Without it, cktool uses the token saved earlier with
#                    `xcrun cktool save-token --type management` (keychain), or the
#                    CLOUDKIT_MANAGEMENT_TOKEN environment variable if already set.
#   --validate-only  run validate-schema only; change nothing.
#   --backup-dir     where to write the current Development schema before importing
#                    (default: build/cloudkit). Needs the same token.
#
# Steps: export the current Development schema as a backup, `cktool validate-schema`, then
# `cktool import-schema` of scripts/cloudkit/schema.ckdb into Development of container
# iCloud.org.openarc.browser (team 7G42499LWB). Importing the same file again is a no-op, so the
# script is safe to rerun. CloudKit refuses imports that would lose data (removed types/fields).
# The token is handed to cktool through the environment, never on the command line, and never
# printed. Needs network. Production is changed only by hand afterwards (see the last message).
set -euo pipefail

TEAM_ID="7G42499LWB"
CONTAINER_ID="iCloud.org.openarc.browser"
ENVIRONMENT="development"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
schema="$here/schema.ckdb"
token_file=""
validate_only=0
backup_dir="$repo/build/cloudkit"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token-file) token_file="${2:?--token-file needs a path}"; shift 2 ;;
        --validate-only) validate_only=1; shift ;;
        --backup-dir) backup_dir="${2:?--backup-dir needs a path}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -f "$schema" ]] || { echo "error: schema not found: $schema" >&2; exit 1; }
xcrun -f cktool >/dev/null 2>&1 || { echo "error: xcrun cktool not found (needs Xcode 13+)" >&2; exit 1; }

if [[ -n "$token_file" ]]; then
    [[ -r "$token_file" ]] || { echo "error: cannot read token file: $token_file" >&2; exit 1; }
    token="$(head -n 1 "$token_file" | tr -d '[:space:]')"
    [[ -n "$token" ]] || { echo "error: token file is empty: $token_file" >&2; exit 1; }
    # cktool reads this variable; exporting keeps the token out of argv (`ps`) and the output.
    export CLOUDKIT_MANAGEMENT_TOKEN="$token"
    unset token
fi

common=(--team-id "$TEAM_ID" --container-id "$CONTAINER_ID" --environment "$ENVIRONMENT")

echo "==> Container $CONTAINER_ID ($ENVIRONMENT), team $TEAM_ID"

if [[ $validate_only -eq 0 ]]; then
    mkdir -p "$backup_dir"
    backup="$backup_dir/schema-$ENVIRONMENT-$(date +%Y%m%d-%H%M%S).ckdb"
    echo "==> Backing up the current $ENVIRONMENT schema to $backup"
    xcrun cktool export-schema "${common[@]}" --output-file "$backup"
fi

echo "==> Validating $schema"
xcrun cktool validate-schema "${common[@]}" --file "$schema"

if [[ $validate_only -eq 1 ]]; then
    echo "==> Valid. Nothing imported (--validate-only)."
    exit 0
fi

echo "==> Importing into $ENVIRONMENT"
xcrun cktool import-schema "${common[@]}" --validate --file "$schema"

cat <<MSG
==> Done: the schema is in the $ENVIRONMENT environment.

Next (manual, cannot be scripted): deploy it to Production.
  1. Open https://icloud.developer.apple.com → CloudKit Database → $CONTAINER_ID.
  2. Check the Development record types (Profile, Theme, Space, Folder, Tab, ArchiveItem,
     SplitLayout, Easel, EaselElement).
  3. Click "Deploy Schema Changes…", review the diff, and deploy to Production.
  4. Retry the Developer ID round trip of plan D4.
MSG
