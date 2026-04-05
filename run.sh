#!/bin/bash
set -e

MODE=${1:-dev}
SCHEME="Xmux"
DERIVED_DATA="build/DerivedData"
CONFIG="Debug"

build() {
  echo "Building $SCHEME ($CONFIG)..."
  xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=macOS" \
    build 2>&1 | xcpretty 2>/dev/null || cat
}

kill_app() {
  if pgrep -x "$SCHEME" &>/dev/null; then
    echo "Killing running $SCHEME..."
    pkill -x "$SCHEME"
    sleep 0.5
  fi
}

launch() {
  APP=$(find "$DERIVED_DATA/Build/Products/$CONFIG" -name "*.app" -maxdepth 1 | head -1)
  if [ -z "$APP" ]; then
    echo "Error: app not found in $DERIVED_DATA/Build/Products/$CONFIG"
    exit 1
  fi
  kill_app
  echo "Launching $APP..."
  open "$APP"
}

case "$MODE" in
  dev)
    build
    launch
    echo ""
    echo "App running. Save any Swift file to hot-reload via InjectionIII."
    ;;
  build)
    build
    ;;
  launch)
    launch
    ;;
  *)
    echo "Usage: ./run.sh [dev|build|launch]"
    exit 1
    ;;
esac
