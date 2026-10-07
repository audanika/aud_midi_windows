#!/usr/bin/env bash
# @license
# Copyright (c) Audanika
#
# Use of this source code is governed by terms that can be
# found in the LICENSE file in the root of this package.

# Builds and runs the portable core test of the shim twice, with the address
# and undefined behaviour sanitizers and with the thread sanitizer, then
# compiles the WinRT implementation against the stand-in headers of
# test/native/winrt_mock, with and without AUD_MIDI_WITH_MIDI2. Runs on
# macOS and Linux with clang++. The stand-ins only catch errors inside the
# shim; the real check against the Windows SDK is the hook build on Windows.
#
# Usage: tool/test_native_core.sh [--update]
#   --update rewrites the golden files in test/goldens.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

compiler="${CXX:-clang++}"
flags=(-std=c++20 -O1 -g -Wall -Wextra -Wpedantic -Wconversion -Wshadow
  -Werror -I"$root/src")
source_file="$root/test/native/aud_midi_windows_core_test.cpp"

"$compiler" "${flags[@]}" -fsanitize=address,undefined \
  -fno-sanitize-recover=all "$source_file" -o "$out/core_test_asan"
"$compiler" "${flags[@]}" -fsanitize=thread "$source_file" \
  -o "$out/core_test_tsan"

"$out/core_test_asan" "$root/test/goldens" "${1:-}"
"$out/core_test_tsan" "$root/test/goldens"

for midi2 in 0 1; do
  "$compiler" -std=c++20 -fsyntax-only -Wall -Wextra -Wpedantic -Wshadow \
    -Wconversion -Werror -DAMW_COMPILE_CHECK -DAUD_MIDI_WITH_MIDI2="$midi2" \
    -I"$root/test/native/winrt_mock" -I"$root/src" \
    "$root/src/aud_midi_windows.cpp"
done
echo "WinRT shim compile check passed"
