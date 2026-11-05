#!/usr/bin/env bash
#
# Copyright 2026 Element Creations Ltd.
#
# SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
# Please see LICENSE files in the repository root for full details.
#
# Downloads the call screen's strings from the element-call Localazy project and regenerates L10n.
# The strings are written in Localazy's dashboard, in the project's mobile.json, which Element Call
# Android downloads too; nothing here uploads. See CONTRIBUTING.md, "Strings".

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: scripts/download-strings.sh [--all-languages]

  --all-languages   Download every language, not only English. The weekly translations workflow
                    passes it; adding a string needs only English.
USAGE
    exit 64
}

ALL_LANGUAGES="no"

while [ $# -gt 0 ]; do
    case "$1" in
        --all-languages)
            ALL_LANGUAGES="yes"
            shift
            ;;
        *)
            usage
            ;;
    esac
done

cd "$(dirname "$0")/.."

LOCALIZATIONS="Sources/ElementCallHost/Resources/Localizations"

if [ "$ALL_LANGUAGES" = "yes" ]; then
    # Cleared first, so a language Localazy no longer has leaves the package rather than lingering
    # with whatever it last had.
    rm -rf "$LOCALIZATIONS"
    localazy download all
else
    localazy download
fi

# Localazy writes keys in its own order, which is not stable between downloads; sorted, a diff shows
# only the strings that changed. The comments Localazy writes are dropped with the rest.
find "$LOCALIZATIONS" -name '*.strings' | while read -r file; do
    grep -E '^".+" = ".*";$' "$file" | LC_ALL=C sort -t '"' -k 2,2 > "$file.sorted"
    mv "$file.sorted" "$file"
done
find "$LOCALIZATIONS" -name '*.stringsdict' -exec plutil -convert xml1 {} \;

# SwiftGen refuses an output directory that does not exist yet.
mkdir -p Sources/ElementCallHost/Generated
swiftgen config run --config Tools/SwiftGen/swiftgen-config.yml
