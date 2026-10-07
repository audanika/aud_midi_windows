// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsMidiApi', () {
    test('offers automatic selection and both APIs', () {
      expect(
        WindowsMidiApi.values.map((api) => api.name),
        equals(['auto', 'midi1', 'midi2']),
      );
    });
  });
}
