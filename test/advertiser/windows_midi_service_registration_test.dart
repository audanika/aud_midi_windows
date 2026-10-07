// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsMidiServiceRegistration', () {
    group('name, unregister()', () {
      test('keep the name and call back to unregister', () async {
        var unregistered = 0;
        final registration = WindowsMidiServiceRegistration(
          name: 'Studio',
          onUnregister: () async => unregistered++,
        );
        expect(registration.name, 'Studio');
        await registration.unregister();
        expect(unregistered, 1);
      });
    });
  });
}
