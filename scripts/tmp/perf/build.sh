#!/bin/bash
# Build the instrumented macOS app. Usage: build.sh [profile|debug|release]
cd /Users/jhangyu/project/Halcyon || exit 1
export PATH="/Users/jhangyu/project/flutter/bin:$PATH"
MODE="${1:-profile}"
echo "=== build start $(date) mode=$MODE ==="
flutter build macos "--$MODE" 2>&1
echo "BUILD_EXIT=$?"
echo "=== build end $(date) ==="
find build/macos/Build/Products -name App -path "*App.framework*" -newermt '-10 minutes' -exec ls -la {} \;
