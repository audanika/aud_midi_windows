// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../shim/aud_midi_windows_bindings.g.dart';

// #############################################################################
/// The kinds of ports of the Windows backend, each with the prefix of its
/// native id: a port id is `winrt:<prefix>:<Windows id>`.
enum WindowsMidiPortKind {
  /// A WinRT MIDI 1.0 input port.
  midi1Input('in', AMW_KIND_MIDI1_IN, MidiDirection.input),

  /// A WinRT MIDI 1.0 output port.
  midi1Output('out', AMW_KIND_MIDI1_OUT, MidiDirection.output),

  /// The input of a UMP endpoint of Windows MIDI Services.
  umpInput('umpin', AMW_KIND_MIDI2_IN, MidiDirection.input),

  /// The output of a UMP endpoint of Windows MIDI Services.
  umpOutput('umpout', AMW_KIND_MIDI2_OUT, MidiDirection.output),

  /// An own virtual device that other apps send to.
  virtualInput('vin', AMW_KIND_VIRTUAL, MidiDirection.input),

  /// An own virtual device that sends to other apps.
  virtualOutput('vout', AMW_KIND_VIRTUAL, MidiDirection.output);

  /// Creates a kind with its id [prefix], its `AMW_KIND_*` [shimKind] and
  /// its [direction] seen from the app.
  const WindowsMidiPortKind(this.prefix, this.shimKind, this.direction);

  // ...........................................................................
  /// Returns the native id of the port [windowsId] of this kind.
  String nativeId(String windowsId) => '$prefix:$windowsId';

  /// Returns the port id of the port [windowsId] of this kind.
  MidiPortId portId(String windowsId) =>
      MidiPortId.of(backend: backend, nativeId: nativeId(windowsId));

  // ...........................................................................
  /// The prefix of the native id.
  final String prefix;

  /// The `AMW_KIND_*` value of the shim.
  final int shimKind;

  /// The direction, seen from the app.
  final MidiDirection direction;

  /// Whether ports of this kind exchange UMP words.
  bool get isUmp => this != midi1Input && this != midi1Output;

  /// Whether ports of this kind are own virtual devices.
  bool get isVirtual => shimKind == AMW_KIND_VIRTUAL;

  // ...........................................................................
  /// The name of the backend, the prefix of every port id.
  static const String backend = 'winrt';

  /// Returns the kind and the Windows id of [port], or null when [port] is
  /// no port of the Windows backend.
  static ({WindowsMidiPortKind kind, String windowsId})? parse(
    MidiPortId port,
  ) {
    if (port.backend != backend) return null;
    final nativeId = port.nativeId;
    final colon = nativeId.indexOf(':');
    if (colon < 0) return null;
    final prefix = nativeId.substring(0, colon);
    for (final kind in values) {
      if (kind.prefix == prefix) {
        return (kind: kind, windowsId: nativeId.substring(colon + 1));
      }
    }
    return null;
  }
}
