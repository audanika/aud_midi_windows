// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

// #############################################################################
/// The Dart view of the C API of the shim (`src/aud_midi_windows.h`).
///
/// The FFI implementation calls the shim the hook builds on Windows;
/// `WindowsMidiFakeShim` simulates it for tests. Every method throws a
/// `MidiException` when the shim reports a failure. Results of asynchronous
/// requests arrive as events that carry the request id.
abstract interface class WindowsMidiShim {
  // ...........................................................................
  /// Creates the native context; [onSignal] runs in this isolate whenever
  /// events or data wait.
  void create({required void Function() onSignal});

  /// Stops everything, waits until no native callback runs any more and
  /// releases the context, the signal callback and the buffers.
  void destroy();

  // ...........................................................................
  /// Returns the native monotonic clock in microseconds.
  int clockNowMicros();

  /// Allows the next signal; call it before draining.
  void rearm();

  /// Moves the waiting events out as bytes; empty when none wait.
  Uint8List readEvents();

  // ...........................................................................
  /// Starts the watchers of the `AMW_SOURCE_*` bits in [sources].
  void watchStart(int sources);

  /// Stops all watchers.
  void watchStop();

  // ...........................................................................
  /// Starts to open the port [id] as `AMW_KIND_*` [kind]; the result
  /// arrives as an open completion carrying [request].
  void openPort({required int request, required String id, required int kind});

  /// Closes the port [handle].
  void closePort(int handle);

  /// Moves the waiting data records of the input [handle] out, with the
  /// number of messages lost since the last read.
  ({Uint8List records, int dropped}) readPort(int handle);

  /// Sends [data] to the output [handle], at the native time [dueMicros]
  /// or at once for 0.
  void send({
    required int handle,
    required Uint8List data,
    required int dueMicros,
  });

  // ...........................................................................
  /// Starts to scan for BLE-MIDI peripherals.
  void bleScanStart();

  /// Stops the scan.
  void bleScanStop();

  /// Starts to pair the Bluetooth LE device [address].
  void blePair({required int request, required int address});

  /// Starts to unpair the Bluetooth LE device [address].
  void bleUnpair({required int request, required int address});

  // ...........................................................................
  /// Starts to create a virtual device from the encoded [spec].
  void virtualCreate({required int request, required Uint8List spec});

  // ...........................................................................
  /// The `AMW_FEATURE_*` bits detected by [create].
  int get features;
}
