#!/bin/sh
# Builds and runs the simulation tests on the Mac.
set -e
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
swiftc -O -o "$out/simulation" \
    Shared/PilotLink.swift Watch/PointerMath.swift Watch/GestureDetector.swift Mac/PointerFilter.swift \
    Tests/main.swift
"$out/simulation"
