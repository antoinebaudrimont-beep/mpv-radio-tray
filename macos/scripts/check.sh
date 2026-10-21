#!/bin/sh
set -eu
case "${1:-}" in
    "") [ "$#" -eq 0 ] ;;
    --popover) [ "$#" -eq 1 ] ;;
    --outputs) [ "$#" -eq 1 ] ;;
    --stream) [ "$#" -eq 2 ] ;;
    *) printf 'Usage: %s [--outputs | --popover | --stream URL]\n' "$0" >&2; exit 2 ;;
esac
MACOS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RADIO_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/radio-native-check.XXXXXX")
trap 'rm -rf "$RADIO_CHECK_DIR"' EXIT
trap 'exit 130' HUP INT TERM
export CLANG_MODULE_CACHE_PATH="$RADIO_CHECK_DIR/clang-cache"
radio_compile() {
    swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macosx13.0" \
        -module-cache-path "$RADIO_CHECK_DIR/module-cache" "$@"
}
radio_compile -parse-as-library -emit-library -static -emit-module -module-name RadioCore \
    -emit-module-path "$RADIO_CHECK_DIR/RadioCore.swiftmodule" \
    "$MACOS_DIR"/Sources/RadioCore/*.swift -o "$RADIO_CHECK_DIR/libRadioCore.a"
radio_compile -parse-as-library -I "$RADIO_CHECK_DIR" -L "$RADIO_CHECK_DIR" -lRadioCore \
    "$MACOS_DIR"/Tests/RadioCoreTests/*.swift -o "$RADIO_CHECK_DIR/CoreChecks"
"$RADIO_CHECK_DIR/CoreChecks"
if [ "$#" -gt 0 ]; then
    radio_compile -parse-as-library -I "$RADIO_CHECK_DIR" -L "$RADIO_CHECK_DIR" -lRadioCore \
        "$MACOS_DIR/Sources/RadioMenuBar/PlayerController.swift" \
        "$MACOS_DIR/Sources/RadioMenuBar/NowPlayingController.swift" \
        "$MACOS_DIR/Sources/RadioMenuBar/AirPlayController.swift" \
        "$MACOS_DIR/Sources/RadioMenuBar/CoreAudioOutputs.swift" \
        "$MACOS_DIR/Sources/RadioMenuBar/OutputController.swift" \
        "$MACOS_DIR/Sources/RadioMenuBar/RadioLogger.swift" \
        "$MACOS_DIR/Tests/NativeChecks/NativeChecks.swift" -o "$RADIO_CHECK_DIR/NativeChecks"
    if [ "$1" = "--stream" ]; then
        "$RADIO_CHECK_DIR/NativeChecks" --stream "$2"
    else
        "$RADIO_CHECK_DIR/NativeChecks" "${1:-}"
    fi
fi
