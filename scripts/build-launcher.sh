#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"

SCHEME="leanring-buddy"
APP_NAME="Clicky"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${PROJECT_DIR}/build/local-release"
ARCHIVE_PATH="${BUILD_ROOT}/${APP_NAME}.xcarchive"
STAGED_APP_DIR="${BUILD_ROOT}/launcher"
STAGED_APP_PATH="${STAGED_APP_DIR}/${APP_NAME}.app"
ZIP_PATH="${BUILD_ROOT}/${APP_NAME}.zip"
INSTALL_DESTINATION="/Applications/${APP_NAME}.app"
SHOULD_INSTALL=0

usage() {
    cat <<EOF
Usage: ./scripts/build-launcher.sh [--install]

Builds a Release archive of Clicky and stages a standalone launcher app at:
  build/local-release/launcher/Clicky.app

Options:
  --install    Replace /Applications/Clicky.app with the staged launcher
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --install)
            SHOULD_INSTALL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

echo "🧹 Cleaning previous local release artifacts..."
rm -rf "${BUILD_ROOT}"
mkdir -p "${STAGED_APP_DIR}"

echo "📦 Archiving ${APP_NAME} in Release mode..."
xcodebuild archive \
    -project "${PROJECT_DIR}/leanring-buddy.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${ARCHIVE_PATH}"

ARCHIVED_APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"

if [ ! -d "${ARCHIVED_APP_PATH}" ]; then
    echo "❌ Expected archived app at ${ARCHIVED_APP_PATH}, but it was not found." >&2
    exit 1
fi

echo "📁 Staging launcher app..."
ditto "${ARCHIVED_APP_PATH}" "${STAGED_APP_PATH}"

echo "🗜️ Creating zip artifact..."
ditto -c -k --keepParent "${STAGED_APP_PATH}" "${ZIP_PATH}"

echo "🔎 Verifying staged app signature..."
codesign --verify --deep --strict "${STAGED_APP_PATH}"

if [ "${SHOULD_INSTALL}" -eq 1 ]; then
    echo "🚚 Installing launcher to /Applications..."
    rm -rf "${INSTALL_DESTINATION}"
    ditto "${STAGED_APP_PATH}" "${INSTALL_DESTINATION}"
    xattr -dr com.apple.quarantine "${INSTALL_DESTINATION}" 2>/dev/null || true
    echo "✅ Installed: ${INSTALL_DESTINATION}"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Local release build complete"
echo ""
echo "   Launcher app: ${STAGED_APP_PATH}"
echo "   Zip artifact:  ${ZIP_PATH}"
if [ "${SHOULD_INSTALL}" -eq 0 ]; then
    echo ""
    echo "   Next step:"
    echo "   Move ${APP_NAME}.app into /Applications before launching it."
    echo "   That is the installed launcher you can run without keeping Xcode open."
fi
echo "═══════════════════════════════════════════════════════════════"
