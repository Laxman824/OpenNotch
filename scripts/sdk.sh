#!/bin/bash
# Sourced by build.sh and Checks/run.sh. The Command Line Tools ship the macOS 27 SDK without SwiftUI's
# macro plugin (needs Xcode), so `@State` fails to compile there. Without Xcode, fall back to the newest
# macOS 26.x SDK. macOS 27-only APIs are behind `#if canImport(FoundationModels, _version: 2.0)`.
# Set SDKROOT yourself to override.
if [ -z "${SDKROOT:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  CLT=/Library/Developer/CommandLineTools
  if ! ls "$CLT"/usr/lib/swift/host/plugins/libSwiftUIMacros* >/dev/null 2>&1 \
     && [[ "$(xcrun --show-sdk-version 2>/dev/null)" == 27* ]]; then
    SDK26=$(ls -d "$CLT"/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
    [ -z "$SDK26" ] && [ -d "$CLT/SDKs/MacOSX26.sdk" ] && SDK26="$CLT/SDKs/MacOSX26.sdk"
    if [ -n "$SDK26" ]; then
      export SDKROOT="$SDK26"
      echo "note: Command Line Tools without SwiftUI macros — building against $(basename "$SDK26")" >&2
    fi
  fi
fi
