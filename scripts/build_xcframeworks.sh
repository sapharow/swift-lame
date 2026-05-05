#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build_xcframeworks.sh [--output-dir <dir>] [--version-tag <tag>] [--zip]

Builds two dynamic XCFrameworks for all platforms declared in Package.swift:
  1. SwiftLame.xcframework (Swift wrapper)
  2. lamemp3.xcframework  (pure C, public header limited to lame.h)

Options:
  --output-dir <dir>   Output directory (default: artifacts)
  --version-tag <tag>  Version suffix for zip assets (default: current git short SHA, else "local")
  --zip                Also emit zipped assets + SHA256SUMS.txt
USAGE
}

OUTPUT_DIR="artifacts"
VERSION_TAG=""
ZIP_ASSETS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --version-tag)
      VERSION_TAG="$2"
      shift 2
      ;;
    --zip)
      ZIP_ASSETS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION_TAG" ]]; then
  if git rev-parse --short=12 HEAD >/dev/null 2>&1; then
    VERSION_TAG="$(git rev-parse --short=12 HEAD)"
  else
    VERSION_TAG="local"
  fi
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG_FILE="$ROOT_DIR/Package.swift"
BUILD_ROOT="$ROOT_DIR/.build/xcframework"
ARCHIVE_ROOT="$BUILD_ROOT/archives"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
HEADERS_ROOT="$BUILD_ROOT/headers"
LIBRARIES_ROOT="$BUILD_ROOT/libraries"
OUTPUT_ABS="$ROOT_DIR/$OUTPUT_DIR"

rm -rf "$BUILD_ROOT"
mkdir -p "$ARCHIVE_ROOT" "$DERIVED_DATA_PATH" "$HEADERS_ROOT" "$LIBRARIES_ROOT" "$OUTPUT_ABS"
cd "$ROOT_DIR"

contains_platform() {
  local needle="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -q "\\.${needle}\\(" "$PKG_FILE"
  else
    grep -q "\\.${needle}(" "$PKG_FILE"
  fi
}

# destination|archive_suffix
DESTINATIONS=()
if contains_platform "iOS"; then
  DESTINATIONS+=("generic/platform=iOS|ios")
  DESTINATIONS+=("generic/platform=iOS Simulator|ios-simulator")
fi
if contains_platform "tvOS"; then
  DESTINATIONS+=("generic/platform=tvOS|tvos")
  DESTINATIONS+=("generic/platform=tvOS Simulator|tvos-simulator")
fi
if contains_platform "macOS"; then
  DESTINATIONS+=("generic/platform=macOS|macos")
fi

if [[ ${#DESTINATIONS[@]} -eq 0 ]]; then
  echo "No supported Apple platforms found in Package.swift" >&2
  exit 1
fi

archive_scheme() {
  local scheme="$1"
  local destination="$2"
  local suffix="$3"
  local archive_path="$ARCHIVE_ROOT/${scheme}-${suffix}.xcarchive"
  local log_path="$BUILD_ROOT/${scheme}-${suffix}.log"

  if ! xcodebuild archive \
    -scheme "$scheme" \
    -configuration Release \
    -destination "$destination" \
    -archivePath "$archive_path" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    SWIFT_VERIFY_EMITTED_MODULE_INTERFACE=NO \
    CODE_SIGNING_ALLOWED=NO \
    > "$log_path" 2>&1; then
    echo "Archive failed for scheme=$scheme destination=$destination" >&2
    echo "Log: $log_path" >&2
    tail -n 120 "$log_path" >&2 || true
    exit 1
  fi
}

swift_framework_args=()
lame_library_args=()

for entry in "${DESTINATIONS[@]}"; do
  destination="${entry%%|*}"
  suffix="${entry##*|}"

  archive_scheme "SwiftLame" "$destination" "$suffix"
  archive_scheme "lamemp3" "$destination" "$suffix"
  swift_archive="$ARCHIVE_ROOT/SwiftLame-${suffix}.xcarchive"
  lame_archive="$ARCHIVE_ROOT/lamemp3-${suffix}.xcarchive"

  swift_framework="$swift_archive/Products/Library/Frameworks/SwiftLame.framework"
  if [[ ! -d "$swift_framework" ]]; then
    swift_framework="$swift_archive/Products/usr/local/lib/SwiftLame.framework"
  fi
  if [[ ! -d "$swift_framework" ]]; then
    echo "Missing SwiftLame.framework in archive: $swift_archive" >&2
    exit 1
  fi
  swift_framework_args+=( -framework "$swift_framework" )

  lame_dylib="$lame_archive/Products/usr/local/lib/liblamemp3.dylib"
  if [[ ! -f "$lame_dylib" ]]; then
    lame_framework_bin="$lame_archive/Products/Library/Frameworks/lamemp3.framework/lamemp3"
    if [[ ! -f "$lame_framework_bin" ]]; then
      lame_framework_bin="$lame_archive/Products/usr/local/lib/lamemp3.framework/lamemp3"
    fi
    if [[ -f "$lame_framework_bin" ]]; then
      # xcodebuild -create-xcframework requires a recognized library extension for -library inputs.
      # Some package archives emit lamemp3.framework/lamemp3 (no extension), so normalize to .dylib.
      normalized_dylib="$LIBRARIES_ROOT/liblamemp3-${suffix}.dylib"
      cp "$lame_framework_bin" "$normalized_dylib"
      chmod +x "$normalized_dylib"
      lame_dylib="$normalized_dylib"
    else
      echo "Missing lamemp3 dynamic library in archive: $lame_archive" >&2
      exit 1
    fi
  fi

  header_dir="$HEADERS_ROOT/$suffix"
  mkdir -p "$header_dir"
  cp "$ROOT_DIR/Sources/lame/include/lame.h" "$header_dir/lame.h"
  cat > "$header_dir/module.modulemap" <<'MAP'
module lamemp3 {
  header "lame.h"
  export *
}
MAP

  lame_library_args+=( -library "$lame_dylib" -headers "$header_dir" )
done

rm -rf "$OUTPUT_ABS/SwiftLame.xcframework" "$OUTPUT_ABS/lamemp3.xcframework"

xcodebuild -create-xcframework \
  "${swift_framework_args[@]}" \
  -output "$OUTPUT_ABS/SwiftLame.xcframework"

xcodebuild -create-xcframework \
  "${lame_library_args[@]}" \
  -output "$OUTPUT_ABS/lamemp3.xcframework"

if [[ "$ZIP_ASSETS" == true ]]; then
  rm -f \
    "$OUTPUT_ABS/SwiftLame-${VERSION_TAG}.xcframework.zip" \
    "$OUTPUT_ABS/lamemp3-${VERSION_TAG}.xcframework.zip" \
    "$OUTPUT_ABS/SwiftLame.xcframework.zip" \
    "$OUTPUT_ABS/lamemp3.xcframework.zip" \
    "$OUTPUT_ABS/SHA256SUMS.txt"

  (
    cd "$OUTPUT_ABS"
    ditto -c -k --sequesterRsrc --keepParent "SwiftLame.xcframework" "SwiftLame-${VERSION_TAG}.xcframework.zip"
    ditto -c -k --sequesterRsrc --keepParent "lamemp3.xcframework" "lamemp3-${VERSION_TAG}.xcframework.zip"
    cp "SwiftLame-${VERSION_TAG}.xcframework.zip" "SwiftLame.xcframework.zip"
    cp "lamemp3-${VERSION_TAG}.xcframework.zip" "lamemp3.xcframework.zip"

    shasum -a 256 \
      "SwiftLame-${VERSION_TAG}.xcframework.zip" \
      "lamemp3-${VERSION_TAG}.xcframework.zip" \
      "SwiftLame.xcframework.zip" \
      "lamemp3.xcframework.zip" \
      > "SHA256SUMS.txt"
  )
fi

echo "Built XCFrameworks in: $OUTPUT_ABS"
if [[ "$ZIP_ASSETS" == true ]]; then
  echo "Zipped assets and checksums are available in: $OUTPUT_ABS"
fi
