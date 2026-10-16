#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
swiftc -swift-version 6 -module-cache-path "$PWD/.build/module-cache" \
  Sources/InterpreterCore/AudioFrameBuffer.swift \
  Sources/InterpreterCore/TranscriptBuffer.swift \
  Sources/InterpreterCore/SessionConfiguration.swift \
  scripts/CoreSmoke.swift -o .build/core-smoke
.build/core-smoke
