// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_windows/src/shim/windows_midi_byte_reader.dart';
import 'package:test/test.dart';

void main() {
  WindowsMidiByteReader reader(List<int> bytes) =>
      WindowsMidiByteReader(Uint8List.fromList(bytes));

  group('WindowsMidiByteReader', () {
    group('u8(), u16(), u32(), i32(), u64(), i64()', () {
      test('read little-endian values', () {
        final input = reader([
          0x12, //
          0x56, 0x34,
          0xDE, 0xBC, 0x9A, 0x78,
          0xFE, 0xFF, 0xFF, 0xFF,
          0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
          0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        ]);
        expect([
          input.u8(),
          input.u16(),
          input.u32(),
          input.i32(),
          input.u64(),
          input.i64(),
        ], equals([0x12, 0x3456, 0x789ABCDE, -2, 0x0102030405060708, -3]));
        expect(input.isAtEnd, isTrue);
      });

      test('throw at the end of the data', () {
        final input = reader([1, 2, 3]);
        expect(
          input.u32,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'Unexpected end of data',
            ),
          ),
        );
        expect(input.remaining, 3);
      });
    });

    group('bytes(length)', () {
      test('reads a copy', () {
        final source = Uint8List.fromList([1, 2, 3]);
        final input = WindowsMidiByteReader(source);
        final copy = input.bytes(2);
        source[0] = 9;
        expect(copy, equals([1, 2]));
        expect(input.remaining, 1);
      });

      test('throws for a negative length', () {
        expect(() => reader([1]).bytes(-1), throwsA(isA<FormatException>()));
      });
    });

    group('string()', () {
      test('reads a length-prefixed UTF-8 string', () {
        final input = reader([5, 0, 0, 0, 0x47, 0xC3, 0xA4, 0x74, 0x65, 0]);
        expect(input.string(), 'Gäte');
        expect(input.u8(), 0);
      });

      test('replaces malformed bytes', () {
        expect(reader([1, 0, 0, 0, 0xFF]).string(), '\u{FFFD}');
      });

      test('throws when the bytes run out', () {
        expect(
          () => reader([4, 0, 0, 0, 0x41]).string(),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('remaining, isAtEnd', () {
      test('count the bytes not read yet', () {
        final input = reader([1, 2]);
        expect([input.remaining, input.isAtEnd], equals([2, false]));
        input.u16();
        expect([input.remaining, input.isAtEnd], equals([0, true]));
      });
    });
  });
}
