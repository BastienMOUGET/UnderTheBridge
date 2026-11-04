#!/usr/bin/env bash
# Compile puis joue le test bout en bout (mode --selftest, sans réseau).
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
python3 tests/selftest_e2e.py build/bridge
