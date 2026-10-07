// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';

// #############################################################################
/// A service the `WindowsMidiServiceAdvertiser` registered with Windows.
final class WindowsMidiServiceRegistration implements MidiServiceRegistration {
  /// Creates the registration of the service [name]; [onUnregister]
  /// withdraws it.
  WindowsMidiServiceRegistration({
    required this.name,
    required this._onUnregister,
  });

  // ...........................................................................
  @override
  Future<void> unregister() => _onUnregister();

  // ...........................................................................
  @override
  final String name;

  // ...........................................................................
  final Future<void> Function() _onUnregister;
}
