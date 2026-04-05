#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT_NAME="Xmux"
PROJECT_FILE="${PROJECT_NAME}.xcodeproj"
PROJECT_SPEC="project.yml"
SCHEME="${PROJECT_NAME}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$SCRIPT_DIR/build/DerivedData}"
GHOSTTY_FRAMEWORK="$SCRIPT_DIR/Frameworks/GhosttyKit.xcframework"

if [[ $# -gt 0 && "${1:-}" != -* ]]; then
  CONFIGURATION="$1"
  shift
fi

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: required command not found: $command_name" >&2
    exit 1
  fi
}

require_command xcodegen
require_command xcodebuild

if [[ ! -f "$PROJECT_SPEC" ]]; then
  echo "error: missing project spec: $PROJECT_SPEC" >&2
  exit 1
fi

if [[ ! -d "$GHOSTTY_FRAMEWORK" ]]; then
  cat >&2 <<EOF
error: missing GhosttyKit xcframework at:
  $GHOSTTY_FRAMEWORK

Download and unpack it first, for example:
  gh release download xcframework-9fa3ab01bb67d5cec4daa358e25509a271af8171 \\
    --repo manaflow-ai/ghostty \\
    --pattern "*.tar.gz" \\
    --dir Frameworks
  cd Frameworks && tar xzf GhosttyKit.xcframework.tar.gz && rm *.tar.gz
EOF
  exit 1
fi

echo "Generating $PROJECT_FILE from $PROJECT_SPEC..."
xcodegen generate --spec "$PROJECT_SPEC"

echo "Building $SCHEME ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build \
  "$@"

APP_PATH="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$PROJECT_NAME.app"

if [[ -d "$APP_PATH" ]]; then
  echo
  echo "Built app:"
  echo "  $APP_PATH"
else
  echo
  echo "Build completed, but app bundle was not found at the expected path:" >&2
  echo "  $APP_PATH" >&2
  exit 1
fi
