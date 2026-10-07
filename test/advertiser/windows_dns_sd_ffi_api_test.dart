// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Integration test against dnsapi.dll; it needs Windows 10 1903+.
@TestOn('windows')
library;

import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsDnsSdFfiApi', () {
    test('registers and withdraws an AppleMIDI session', () async {
      final advertiser = WindowsMidiServiceAdvertiser();
      final registration = await advertiser.register(
        name: 'aud_midi test',
        type: '_apple-midi._udp',
        port: 50040,
      );
      expect(registration.name, startsWith('aud_midi test'));
      await registration.unregister();
      await advertiser.close();
    });

    test('registers TXT entries', () async {
      final advertiser = WindowsMidiServiceAdvertiser();
      final registration = await advertiser.register(
        name: 'aud_midi test 2',
        type: '_midi2._udp',
        port: 50060,
        txt: const {'UMPEndpointName': 'aud_midi test 2'},
      );
      await registration.unregister();
      await advertiser.close();
    });
  });
}
