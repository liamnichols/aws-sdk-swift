#!/usr/bin/env bash
#
# Pre-generates the code that smithy-swift's SmithyCodeGeneratorPlugin would otherwise generate at
# build time, so the package can be built by tools that don't run SwiftPM build tool plugins (such
# as Tuist's XcodeProj-based package integration).
#
# For every target with a swift-settings.json, this runs SmithyCodegenCLI with the same arguments as
# the plugin and writes the output to <target sources>/Generated/. Package.swift no longer attaches
# the plugin to those targets.
#
# SmithyCodegenCLI is built from the smithy-swift version Package.swift depends on
# (`clientRuntimeVersion`), so the output matches what the plugin would produce.
#
# Usage: scripts/pregenerate-smithy-codegen.sh [target...]
#   With no arguments, every target is generated. Otherwise only the named targets are.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.build/pregenerate-smithy-codegen"

cd "$ROOT"

smithy_version="$(sed -nE 's/^let clientRuntimeVersion: Version = "([^"]+)"/\1/p' Package.swift)"
[[ -n "$smithy_version" ]] || { echo "error: clientRuntimeVersion not found in Package.swift" >&2; exit 1; }

smithy="$WORK/smithy-swift-$smithy_version"
if [[ ! -d "$smithy" ]]; then
    echo "==> Cloning smithy-swift $smithy_version"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$smithy_version" \
        https://github.com/smithy-lang/smithy-swift "$smithy"
fi

echo "==> Building SmithyCodegenCLI"
swift build --package-path "$smithy" -c release --product SmithyCodegenCLI
cli="$(swift build --package-path "$smithy" -c release --show-bin-path)/SmithyCodegenCLI"

find Sources -name swift-settings.json -not -path '*/Tests/*' | sort | while read -r settings; do
    dir="$(dirname "$settings")"
    name="$(basename "$dir")"
    if [[ $# -gt 0 ]] && ! printf '%s\n' "$@" | grep -qx "$name"; then
        continue
    fi

    service="$(jq -r .service "$settings")"
    sdk_id="$(jq -r .sdkId "$settings")"
    internal="$(jq -r .internalClient "$settings")"
    operations="$(jq -r '(.operations // []) | join(",")' "$settings")"
    # Like the plugin: modelPath is relative to the package root, with model.json beside the
    # settings file as the fallback.
    model="$(jq -r '.modelPath // empty' "$settings")"
    [[ -n "$model" ]] || model="$dir/model.json"

    out="$dir/Generated"
    rm -rf "$out"
    mkdir -p "$out"

    args=(
        "$service" "$model"
        --internal "$internal"
        --sdk-id "$sdk_id"
        --schemas-path "$out/${name}Schemas.swift"
        --serialize-path "$out/${name}Serialize.swift"
        --deserialize-path "$out/${name}Deserialize.swift"
        --type-registry-path "$out/${name}TypeRegistry.swift"
        --operations-path "$out/${name}Operations.swift"
    )
    [[ -n "$operations" ]] && args+=(--operations "$operations")

    echo "==> Generating $name"
    "$cli" "${args[@]}"
done
