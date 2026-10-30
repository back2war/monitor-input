#!/bin/sh
# Requires Xcode Command Line Tools:  xcode-select --install
set -e
cd "$(dirname "$0")"
swiftc -O main.swift -o monitor-input -framework IOKit -framework AppKit -framework Carbon
echo "Built ./monitor-input"
