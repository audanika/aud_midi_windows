// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_windows/src/shim/windows_midi_list_equality.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsMidiListEquality', () {
    group('equals(other)', () {
      test('is true for the same list', () {
        final list = [1, 2];
        expect(list.equals(list), isTrue);
      });

      test('is true for equal elements in the same order', () {
        expect([1, 2].equals([1, 2]), isTrue);
        expect(<int>[].equals([]), isTrue);
      });

      test('is false for other lengths, elements or orders', () {
        expect([1, 2].equals([1]), isFalse);
        expect([1, 2].equals([1, 3]), isFalse);
        expect([1, 2].equals([2, 1]), isFalse);
      });
    });
  });
}
