// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_windows/src/shim/windows_midi_byte_writer.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsMidiByteWriter', () {
    group('u8(value), u16(value), u32(value), u64(value)', () {
      test('write the low bits little-endian', () {
        final writer = WindowsMidiByteWriter()
          ..u8(0x112)
          ..u16(0x3456)
          ..u32(-2)
          ..u64(0x0102030405060708);
        expect(
          writer.toBytes(),
          equals([
            0x12, //
            0x56, 0x34,
            0xFE, 0xFF, 0xFF, 0xFF,
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
          ]),
        );
      });
    });

    group('string(value)', () {
      test('writes the UTF-8 length and bytes', () {
        final writer = WindowsMidiByteWriter()..string('Gä');
        expect(writer.toBytes(), equals([3, 0, 0, 0, 0x47, 0xC3, 0xA4]));
      });
    });

    group('bytes(values)', () {
      test('writes the low bits of every value', () {
        final writer = WindowsMidiByteWriter()..bytes([1, 0x1FF]);
        expect(writer.toBytes(), equals([1, 0xFF]));
      });
    });

    group('toBytes()', () {
      test('returns a copy', () {
        final writer = WindowsMidiByteWriter()..u8(1);
        final first = writer.toBytes();
        writer.u8(2);
        expect(
          [first, writer.toBytes()],
          equals([
            [1],
            [1, 2],
          ]),
        );
      });
    });
  });
}
