// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:typed_data';

// #############################################################################
/// Writes the little-endian values and length-prefixed UTF-8 strings of the
/// buffers the shim exchanges (`src/aud_midi_windows.h`).
///
/// Every value keeps the low bits of its width, so a negative value becomes
/// its two's complement.
final class WindowsMidiByteWriter {
  /// Creates an empty writer.
  WindowsMidiByteWriter();

  // ...........................................................................
  /// Writes the low 8 bits of [value].
  void u8(int value) => _bytes.add(value & 0xFF);

  /// Writes the low 16 bits of [value].
  void u16(int value) => _write(value, 2);

  /// Writes the low 32 bits of [value].
  void u32(int value) => _write(value, 4);

  /// Writes all 64 bits of [value].
  void u64(int value) => _write(value, 8);

  /// Writes the UTF-8 byte length of [value] as uint32, then the bytes.
  void string(String value) {
    final encoded = utf8.encode(value);
    u32(encoded.length);
    _bytes.addAll(encoded);
  }

  /// Writes the low 8 bits of every value of [values].
  void bytes(List<int> values) {
    for (final value in values) {
      u8(value);
    }
  }

  // ...........................................................................
  /// Returns a copy of the bytes written so far.
  Uint8List toBytes() => Uint8List.fromList(_bytes);

  // ...........................................................................
  void _write(int value, int count) {
    for (var i = 0; i < count; i++) {
      _bytes.add((value >> (8 * i)) & 0xFF);
    }
  }

  final List<int> _bytes = [];
}
