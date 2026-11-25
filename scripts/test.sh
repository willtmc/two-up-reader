#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "==> Checking shell scripts"
bash -n build.sh scripts/test.sh
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error build.sh scripts/test.sh
fi

echo "==> Validating Info.plist"
plutil -lint Info.plist

echo "==> Typechecking Swift sources (strict concurrency)"
swiftc -typecheck -swift-version 5 -warn-concurrency -warnings-as-errors Core.swift main.swift
swiftc -typecheck -swift-version 5 -warn-concurrency -warnings-as-errors make_icon.swift

echo "==> Running Swift CoreTests"
TMP_BIN="$(mktemp "${TMPDIR:-/tmp}/twoup-core-tests.XXXXXX")"
trap 'rm -f "$TMP_BIN"' EXIT
swiftc -swift-version 5 -warn-concurrency -warnings-as-errors Core.swift tests/CoreTests.swift -o "$TMP_BIN"
"$TMP_BIN"

echo "==> Running Node reader tests"
node --test tests/reader.test.mjs
