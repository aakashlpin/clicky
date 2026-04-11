#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"

SCHEME="leanring-buddy"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${PROJECT_DIR}/build/local-release"
ARCHIVE_PATH="${BUILD_ROOT}/launcher.xcarchive"
STAGED_APP_DIR="${BUILD_ROOT}/launcher"
SHOULD_INSTALL=0

usage() {
    cat <<EOF
Usage: ./scripts/build-launcher.sh [--install]

Builds a Release archive of the leanring-buddy scheme and stages a
standalone launcher app under build/local-release/launcher/. The exact
.app bundle name is determined by Xcode's PRODUCT_NAME build setting
and is auto-detected from the archive.

Options:
  --install    Replace the installed launcher in /Applications
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

echo "📦 Archiving in Release mode..."
xcodebuild archive \
    -project "${PROJECT_DIR}/leanring-buddy.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${ARCHIVE_PATH}"

# Auto-detect the produced .app bundle name. Xcode's PRODUCT_NAME build
# setting determines this — hardcoding the name here silently breaks the
# script whenever the product is renamed (it already happened once when
# Clicky was renamed to Flowee and this verification kept failing on
# Clicky.app long after the archive started producing Flowee.app).
ARCHIVED_APPLICATIONS_DIR="${ARCHIVE_PATH}/Products/Applications"
ARCHIVED_APP_PATH="$(find "${ARCHIVED_APPLICATIONS_DIR}" -maxdepth 1 -name '*.app' -type d -print -quit 2>/dev/null || true)"

if [ -z "${ARCHIVED_APP_PATH}" ] || [ ! -d "${ARCHIVED_APP_PATH}" ]; then
    echo "❌ No .app bundle found in ${ARCHIVED_APPLICATIONS_DIR}" >&2
    exit 1
fi

ARCHIVED_APP_BUNDLE_NAME="$(basename "${ARCHIVED_APP_PATH}")"
ARCHIVED_APP_BUNDLE_NAME_WITHOUT_EXTENSION="${ARCHIVED_APP_BUNDLE_NAME%.app}"

STAGED_APP_PATH="${STAGED_APP_DIR}/${ARCHIVED_APP_BUNDLE_NAME}"
ZIP_PATH="${BUILD_ROOT}/${ARCHIVED_APP_BUNDLE_NAME_WITHOUT_EXTENSION}.zip"
INSTALL_DESTINATION="/Applications/${ARCHIVED_APP_BUNDLE_NAME}"

echo "📁 Staging ${ARCHIVED_APP_BUNDLE_NAME}..."
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
    echo "   Move ${ARCHIVED_APP_BUNDLE_NAME} into /Applications before launching it."
    echo "   That is the installed launcher you can run without keeping Xcode open."
fi
echo "═══════════════════════════════════════════════════════════════"
