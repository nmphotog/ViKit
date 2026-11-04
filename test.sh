#!/bin/bash
# Runs the headless ViEngine test-suite on macOS.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -swift-version 5 -O Sources/ViEngine.swift Tests/main.swift -o build/engine-tests
./build/engine-tests
