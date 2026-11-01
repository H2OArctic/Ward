#!/bin/bash
set -euo pipefail

case "${1:-}" in
    configure)
        IDENTITY="${WARD_BUNDLE_ID:?Set WARD_BUNDLE_ID to the installed application identifier}"
        OUTPUT="${2:?Missing configuration path}"
        ;;
    generate)
        IDENTITY="$(cat "${2:?Missing configuration path}")"
        OUTPUT="${3:?Missing generated source path}"
        ;;
    *) echo "Usage: build-identity.sh configure <config> | generate <config> <source>" >&2; exit 1 ;;
esac

if [[ ! "$IDENTITY" =~ ^[a-z0-9]+(\.[a-z0-9]+)+$ ]]; then
    echo "WARD_BUNDLE_ID must use lowercase letters, digits and dots, with at least two nonempty segments" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
if [[ "$1" == configure ]]; then
    if [[ ! -f "$OUTPUT" ]] || [[ "$(cat "$OUTPUT")" != "$IDENTITY" ]]; then
        printf '%s\n' "$IDENTITY" > "$OUTPUT"
    fi
else
    printf 'enum WardBuildIdentity {\n    static let applicationID = "%s"\n}\n' "$IDENTITY" > "$OUTPUT"
fi
