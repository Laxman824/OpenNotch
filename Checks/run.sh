#!/bin/bash
# Logic checks for pure-Swift parts of OpenNotch (no XCTest with the Command
# Line Tools, so each check compiles the real source slice + a case file).
set -euo pipefail
cd "$(dirname "$0")"
SRC=../App/Sources/OpenNotch
T=$(mktemp -d)
{ echo "import Foundation"; sed -n '/^enum QuickIntent/,/^\/\/\/ Performs a quick-capture intent/p' $SRC/QuickCapture.swift | sed '$d'; cat quickcapture_cases.swift; } > $T/qc.swift
{ echo "import Foundation"; sed -n '/^\/\/\/ Turns Markdown answers into something worth hearing./,$p' $SRC/HandsFree.swift; cat speech_cases.swift; } > $T/sp.swift
swift $T/qc.swift
swift $T/sp.swift
{ echo "import Foundation"; sed -n '/^\/\/\/ Turns Markdown answers into something worth hearing./,$p' $SRC/HandsFree.swift; cat voiceturn_cases.swift; } > $T/vt.swift
swift $T/vt.swift
{ echo "import AudioToolbox"; echo "import CoreAudio"; echo "import Foundation"; echo "import IOKit.ps"
  sed -n '/^enum HUDKind/,/^\/\/ MARK: - Views/p' $SRC/SystemHUD.swift; cat hud_cases.swift; } > $T/hud.swift
swift $T/hud.swift
{ echo "import Foundation"; sed -n '/^enum PaletteLogic/,/^\/\/ MARK: - Palette/p' $SRC/Palette.swift; cat palette_cases.swift; } > $T/pal.swift
swift $T/pal.swift
{ echo "import Foundation"; sed -n '/^enum HealthLogic/,/^\/\/ MARK: - Keep awake/p' $SRC/SmallWins.swift; cat health_cases.swift; } > $T/health.swift
swift $T/health.swift
{ echo "import AppKit"; echo "import Foundation"; sed -n '/^enum MediaIntent/,$p' $SRC/Agent/MediaControl.swift; cat media_cases.swift; } > $T/media.swift
swift $T/media.swift
rm -rf "$T"
# Agent logic (context window, tools, safety net, providers' wire format): built into the app.
( cd ../App && swift build >/dev/null && .build/debug/OpenNotch --checks )
