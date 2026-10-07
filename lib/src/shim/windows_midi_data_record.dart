// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'aud_midi_windows_bindings.g.dart';
import 'windows_midi_list_equality.dart';

// #############################################################################
/// One received message as an input port of the shim stores it
/// (`src/aud_midi_windows.h`): the bytes of a MIDI 1.0 message or the words
/// of one UMP, with its receive time.
final class WindowsMidiDataRecord {
  /// Creates a record from a copy of [data].
  ///
  /// - [timeMicros] the receive time on the native clock
  ///   (`amw_clock_now_us`).
  /// - [flags] the `AMW_RECORD_*` bits.
  WindowsMidiDataRecord({
    required this.timeMicros,
    this.flags = 0,
    required List<int> data,
  }) : data = Uint8List.fromList(data).asUnmodifiableView();

  // ...........................................................................
  /// The receive time on the native clock in microseconds.
  final int timeMicros;

  /// The `AMW_RECORD_*` bits.
  final int flags;

  /// The payload; cannot be modified.
  final Uint8List data;

  /// Whether the payload holds UMP words instead of MIDI 1.0 bytes.
  bool get isUmp => flags & AMW_RECORD_UMP != 0;

  /// The payload as little-endian 32-bit words; a partial last word is
  /// dropped.
  List<int> get words {
    final view = ByteData.sublistView(data);
    return [
      for (var i = 0; i + 4 <= data.length; i += 4)
        view.getUint32(i, Endian.little),
    ];
  }

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowsMidiDataRecord &&
          other.timeMicros == timeMicros &&
          other.flags == flags &&
          other.data.equals(data);

  @override
  int get hashCode => Object.hash(timeMicros, flags, Object.hashAll(data));

  @override
  String toString() =>
      'WindowsMidiDataRecord(timeMicros: $timeMicros, flags: $flags, '
      'data: $data)';
}
