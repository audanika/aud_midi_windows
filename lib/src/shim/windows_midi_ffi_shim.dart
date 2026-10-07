// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// coverage:ignore-file
// Reason: calls the native shim, which hook/build.dart builds on Windows
// only; covered by the @TestOn('windows') tests in test/windows.

import 'dart:convert';
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';

import 'aud_midi_windows_bindings.g.dart';
import 'windows_midi_shim.dart';
import 'windows_midi_status.dart';

// #############################################################################
/// The [WindowsMidiShim] that calls the native shim through FFI.
///
/// Every buffer the shim fills is native memory this class owns; the data is
/// copied into Dart lists before it is returned.
final class WindowsMidiFfiShim implements WindowsMidiShim {
  /// Creates the shim; nothing native happens before [create].
  WindowsMidiFfiShim();

  // ...........................................................................
  @override
  void create({required void Function() onSignal}) {
    if (_context != nullptr) throw StateError('The shim is created already');
    final callable = NativeCallable<Void Function()>.listener(onSignal);
    final out = calloc<Pointer<amw_context>>();
    try {
      final status = amw_create(callable.nativeFunction, out);
      if (status < 0) {
        callable.close();
        _fail('amw_create', status);
      }
      _context = out.value;
      _signal = callable;
      _length = calloc<Int32>();
      _dropped = calloc<Int64>();
    } finally {
      calloc.free(out);
    }
  }

  @override
  void destroy() {
    if (_context == nullptr) return;
    // Stops the sources and waits until no native callback runs; only then
    // the callback may close and the buffers may go.
    amw_destroy(_context);
    _context = nullptr;
    _signal?.close();
    _signal = null;
    for (final buffer in [_events, _data, _send, _length, _dropped]) {
      if (buffer != nullptr) calloc.free(buffer);
    }
    _events = nullptr;
    _data = nullptr;
    _send = nullptr;
    _length = nullptr;
    _dropped = nullptr;
    _eventsCapacity = 0;
    _dataCapacity = 0;
    _sendCapacity = 0;
  }

  // ...........................................................................
  @override
  int clockNowMicros() => amw_clock_now_us();

  @override
  void rearm() => amw_rearm(_context);

  @override
  Uint8List readEvents() {
    for (;;) {
      if (_eventsCapacity == 0) _growEvents(_initialCapacity);
      final status = amw_read_events(
        _context,
        _events,
        _eventsCapacity,
        _length,
      );
      if (status == AMW_E_BUFFER_TOO_SMALL) {
        _growEvents(_length.value);
        continue;
      }
      _check('amw_read_events', status);
      return Uint8List.fromList(_events.asTypedList(_length.value));
    }
  }

  // ...........................................................................
  @override
  void watchStart(int sources) =>
      _check('amw_watch_start', amw_watch_start(_context, sources));

  @override
  void watchStop() => _check('amw_watch_stop', amw_watch_stop(_context));

  // ...........................................................................
  @override
  void openPort({required int request, required String id, required int kind}) {
    final bytes = utf8.encode(id);
    final native = calloc<Uint8>(max(bytes.length, 1));
    try {
      native.asTypedList(bytes.length).setAll(0, bytes);
      _check(
        'amw_port_open',
        amw_port_open(_context, request, native, bytes.length, kind),
      );
    } finally {
      calloc.free(native);
    }
  }

  @override
  void closePort(int handle) =>
      _check('amw_port_close', amw_port_close(_context, handle));

  @override
  ({Uint8List records, int dropped}) readPort(int handle) {
    for (;;) {
      if (_dataCapacity == 0) _growData(_initialCapacity);
      final status = amw_port_read(
        _context,
        handle,
        _data,
        _dataCapacity,
        _length,
        _dropped,
      );
      if (status == AMW_E_BUFFER_TOO_SMALL) {
        _growData(_length.value);
        continue;
      }
      _check('amw_port_read', status);
      return (
        records: Uint8List.fromList(_data.asTypedList(_length.value)),
        dropped: _dropped.value,
      );
    }
  }

  @override
  void send({
    required int handle,
    required Uint8List data,
    required int dueMicros,
  }) {
    if (data.length > _sendCapacity) {
      if (_send != nullptr) calloc.free(_send);
      _sendCapacity = max(data.length, _initialCapacity);
      _send = calloc<Uint8>(_sendCapacity);
    }
    if (data.isNotEmpty) _send.asTypedList(data.length).setAll(0, data);
    _check(
      'amw_port_send',
      amw_port_send(_context, handle, _send, data.length, dueMicros),
    );
  }

  // ...........................................................................
  @override
  void bleScanStart() =>
      _check('amw_ble_scan_start', amw_ble_scan_start(_context));

  @override
  void bleScanStop() =>
      _check('amw_ble_scan_stop', amw_ble_scan_stop(_context));

  @override
  void blePair({required int request, required int address}) =>
      _check('amw_ble_pair', amw_ble_pair(_context, request, address));

  @override
  void bleUnpair({required int request, required int address}) =>
      _check('amw_ble_unpair', amw_ble_unpair(_context, request, address));

  // ...........................................................................
  @override
  void virtualCreate({required int request, required Uint8List spec}) {
    final native = calloc<Uint8>(max(spec.length, 1));
    try {
      native.asTypedList(spec.length).setAll(0, spec);
      _check(
        'amw_virtual_create',
        amw_virtual_create(_context, request, native, spec.length),
      );
    } finally {
      calloc.free(native);
    }
  }

  // ...........................................................................
  @override
  int get features => amw_features(_context);

  // ...........................................................................
  static const int _initialCapacity = 64 * 1024;

  static final Logger _log = Logger('aud_midi_windows');

  void _check(String api, int status) {
    if (status < 0) _fail(api, status);
  }

  Never _fail(String api, int status) {
    _log.warning(
      '$api failed with ${WindowsMidiStatus.hex(status)}: ${_lastError()}',
    );
    throw WindowsMidiStatus.exception(api: api, status: status);
  }

  String _lastError() {
    final length = amw_last_error(nullptr, 0);
    if (length <= 0) return '';
    final buffer = calloc<Uint8>(length);
    try {
      amw_last_error(buffer, length);
      return utf8.decode(buffer.asTypedList(length), allowMalformed: true);
    } finally {
      calloc.free(buffer);
    }
  }

  void _growEvents(int capacity) {
    if (_events != nullptr) calloc.free(_events);
    _eventsCapacity = max(capacity, _initialCapacity);
    _events = calloc<Uint8>(_eventsCapacity);
  }

  void _growData(int capacity) {
    if (_data != nullptr) calloc.free(_data);
    _dataCapacity = max(capacity, _initialCapacity);
    _data = calloc<Uint8>(_dataCapacity);
  }

  Pointer<amw_context> _context = nullptr;
  NativeCallable<Void Function()>? _signal;
  Pointer<Uint8> _events = nullptr;
  int _eventsCapacity = 0;
  Pointer<Uint8> _data = nullptr;
  int _dataCapacity = 0;
  Pointer<Uint8> _send = nullptr;
  int _sendCapacity = 0;
  Pointer<Int32> _length = nullptr;
  Pointer<Int64> _dropped = nullptr;
}
