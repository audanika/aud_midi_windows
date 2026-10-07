// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:typed_data';

// #############################################################################
/// Reads the little-endian values and length-prefixed UTF-8 strings of the
/// buffers the shim hands out (`src/aud_midi_windows.h`).
///
/// Every read throws a [FormatException] once the data runs out.
final class WindowsMidiByteReader {
  /// Creates a reader that starts at the first byte of [bytes].
  WindowsMidiByteReader(Uint8List bytes)
    : _bytes = bytes,
      _data = ByteData.sublistView(bytes);

  // ...........................................................................
  /// Reads an unsigned 8-bit value.
  int u8() => _data.getUint8(_take(1));

  /// Reads an unsigned 16-bit value.
  int u16() => _data.getUint16(_take(2), Endian.little);

  /// Reads an unsigned 32-bit value.
  int u32() => _data.getUint32(_take(4), Endian.little);

  /// Reads a signed 32-bit value.
  int i32() => _data.getInt32(_take(4), Endian.little);

  /// Reads an unsigned 64-bit value; values above 2^63 - 1 wrap around.
  int u64() => _data.getUint64(_take(8), Endian.little);

  /// Reads a signed 64-bit value.
  int i64() => _data.getInt64(_take(8), Endian.little);

  /// Reads a copy of the next [length] bytes.
  Uint8List bytes(int length) {
    final start = _take(length);
    return Uint8List.fromList(
      Uint8List.sublistView(_bytes, start, start + length),
    );
  }

  /// Reads a uint32 byte length and that many UTF-8 bytes; malformed bytes
  /// become U+FFFD.
  String string() {
    final length = u32();
    final start = _take(length);
    return utf8.decode(
      Uint8List.sublistView(_bytes, start, start + length),
      allowMalformed: true,
    );
  }

  // ...........................................................................
  /// The number of bytes not read yet.
  int get remaining => _bytes.length - _offset;

  /// Whether every byte was read.
  bool get isAtEnd => remaining == 0;

  // ...........................................................................
  int _take(int count) {
    if (count < 0 || count > remaining) {
      throw FormatException('Unexpected end of data', _bytes, _offset);
    }
    final start = _offset;
    _offset += count;
    return start;
  }

  final Uint8List _bytes;
  final ByteData _data;
  int _offset = 0;
}
