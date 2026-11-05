#!/usr/bin/env bash
# Renders Scripts/Info.plist.template for package_and_run.sh and create_dmg.sh.
# Usage: render_info_plist.sh <app-name> <bundle-id> <output-plist>
set -euo pipefail

APP_NAME="$1"
BUNDLE_ID="$2"
OUTPUT="$3"
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Info.plist.template"

# Both values land in sed and in the plist, so allow only bundle-ID characters
for value in "$APP_NAME" "$BUNDLE_ID"; do
    if [[ ! "$value" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo "render_info_plist.sh: invalid value '$value' (allowed: letters, digits, '.', '-')" >&2
        exit 1
    fi
done

sed -e "s/__APP_NAME__/${APP_NAME}/g" -e "s/__BUNDLE_ID__/${BUNDLE_ID}/g" "$TEMPLATE" > "$OUTPUT"
