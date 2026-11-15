#!/usr/bin/env bash
# Renders Scripts/Info.plist.template for package_and_run.sh and create_dmg.sh.
# Usage: render_info_plist.sh <app-name> <bundle-id> <output-plist> [app-version]
set -euo pipefail

APP_NAME="$1"
BUNDLE_ID="$2"
OUTPUT="$3"
RAW_VERSION="${4:-${BITZ_VERSION:-1.0.0}}"
APP_VERSION="${RAW_VERSION#[vV]}"
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Info.plist.template"

# All values land in sed and in the plist, so allow only bundle-ID / semver characters
for value in "$APP_NAME" "$BUNDLE_ID" "$APP_VERSION"; do
    if [[ ! "$value" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo "render_info_plist.sh: invalid value '$value' (allowed: letters, digits, '.', '-')" >&2
        exit 1
    fi
done

sed -e "s/__APP_NAME__/${APP_NAME}/g" \
    -e "s/__BUNDLE_ID__/${BUNDLE_ID}/g" \
    -e "s/__APP_VERSION__/${APP_VERSION}/g" \
    "$TEMPLATE" > "$OUTPUT"
