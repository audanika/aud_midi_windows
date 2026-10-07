// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../shim/aud_midi_windows_bindings.g.dart';
import '../shim/windows_midi_data_record.dart';
import '../shim/windows_midi_ffi_shim.dart';
import '../shim/windows_midi_shim.dart';
import '../shim/windows_midi_shim_decoder.dart';
import '../shim/windows_midi_shim_event.dart';
import '../shim/windows_midi_status.dart';
import 'windows_midi_api.dart';
import 'windows_midi_bluetooth.dart';
import 'windows_midi_port_kind.dart';
import 'windows_midi_port_table.dart';
import 'windows_midi_requests.dart';
import 'windows_midi_virtual_ports.dart';

// #############################################################################
/// The Windows backend: WinRT MIDI 1.0 (`Windows.Devices.Midi`) and, when
/// present, Windows MIDI Services (`Windows.Devices.Midi2`), through the
/// C++/WinRT shim that `hook/build.dart` builds.
///
/// WinRT MIDI 1.0 ports are byte ports with receive timestamps; they send at
/// once, so the engine schedules them in software. UMP endpoints of Windows
/// MIDI Services exchange UMP words and schedule in the service. Paired
/// BLE-MIDI peripherals are WinRT MIDI 1.0 ports, [bluetooth] pairs them.
/// [virtualPorts] needs Windows MIDI Services with virtual devices.
final class WindowsMidiBackend implements MidiBackend {
  /// Creates the backend.
  ///
  /// - [shim] the shim to use; the FFI shim by default, a
  ///   `WindowsMidiFakeShim` in tests.
  /// - [api] which Windows MIDI API to use.
  /// - [includeDiagnosticLoopback] whether the diagnostic loopback
  ///   endpoints of Windows MIDI Services appear as ports, e.g. for tests.
  /// - [enumerationTimeout] the time [start] waits for the first port list.
  /// - [requestTimeout] the time to wait for Windows to open a port, pair a
  ///   peripheral or create a virtual device.
  /// - [resyncInterval] how often the native clock is mapped anew.
  WindowsMidiBackend({
    WindowsMidiShim? shim,
    this.api = WindowsMidiApi.auto,
    this.includeDiagnosticLoopback = false,
    this.enumerationTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 10),
    this.resyncInterval = const Duration(seconds: 10),
  }) : _shim = shim ?? WindowsMidiFfiShim();

  // ...........................................................................
  @override
  Future<void> start(MidiBackendHost host) async {
    if (_host != null) throw StateError('The backend was started before');
    _host = host;
    try {
      _shim.create(onSignal: _drain);
      _configure(_shim.features);
      _clock = MidiClockMapper(
        clock: host.clock,
        nativeNow: _shim.clockNowMicros,
      );
      await _enumerate();
    } catch (_) {
      _shim.destroy();
      _host = null;
      _bluetooth = null;
      _virtualPorts = null;
      _pendingSources.clear();
      rethrow;
    }
    if (_stopped) return;
    _published = _table.ports;
    _running = true;
    _resync = Timer.periodic(resyncInterval, (_) => _clock.resync());
  }

  @override
  Future<void> stop() async {
    if (_host == null || _stopped) return;
    _stopped = true;
    _running = false;
    _resync?.cancel();
    _bluetooth?.close();
    final enumerated = _enumerated;
    if (enumerated != null && !enumerated.isCompleted) enumerated.complete();
    // First the native sources stop, then destroy waits until no native
    // callback runs before it closes the callback and frees the buffers.
    _quietly(_shim.watchStop);
    for (final handle in _handles.keys) {
      _quietly(() => _shim.closePort(handle));
    }
    _shim.destroy();
    _requests.failAll(StateError('The backend stopped'));
    _handles.clear();
    _open.clear();
    _own.clear();
    _inputs.clear();
    await _portsChanged.close();
  }

  // ...........................................................................
  @override
  Future<void> openPort(MidiPortId port) {
    _checkRunning();
    if (_open.containsKey(port) || _own.containsKey(port)) {
      return Future.value();
    }
    return _opening[port] ??= _openNative(port).whenComplete(() {
      _opening.remove(port);
    });
  }

  @override
  Future<void> closePort(MidiPortId port) async {
    _checkRunning();
    final handle = _open[port];
    if (handle == null) return;
    _forget(port);
    try {
      _shim.closePort(handle);
    } on MidiNativeError catch (error) {
      if (error.code != AMW_E_UNKNOWN_HANDLE) rethrow;
    }
  }

  // ...........................................................................
  @override
  Future<void> send(MidiPortId port, MidiPacket packet) async {
    _checkRunning();
    final info = _output(port);
    final handle = _open[port] ?? _own[port];
    if (handle == null) throw StateError('The port $port is not open');
    final ump = info.capabilities.ump;
    final data = switch (packet) {
      MidiBytesPacket(:final bytes) when !ump => bytes.bytes,
      MidiUmpPacket(:final words) when ump => _wordBytes(words),
      _ => throw MidiUnsupported(
        ump ? 'MIDI 1.0 bytes on UMP ports' : 'UMP words on byte ports',
      ),
    };
    if (data.isEmpty) return;
    final due =
        info.capabilities.scheduledSend &&
            packet.time.isAfter(_host!.clock.now())
        ? max(_clock.toNative(packet.time), 1)
        : 0;
    try {
      _shim.send(handle: handle, data: data, dueMicros: due);
    } on MidiNativeError catch (error) {
      if (error.code == AMW_E_CLOSED || error.code == AMW_E_UNKNOWN_HANDLE) {
        throw MidiPortGone(port);
      }
      rethrow;
    }
  }

  @override
  Future<void> cancelPending(MidiPortId port) async {
    _checkRunning();
    final info = _output(port);
    // Ports without a native queue have nothing pending; Windows MIDI
    // Services schedules but cannot cancel.
    if (info.capabilities.scheduledSend) {
      throw const MidiUnsupported('cancelPending');
    }
  }

  // ...........................................................................
  /// Which Windows MIDI API the backend uses.
  final WindowsMidiApi api;

  /// Whether the diagnostic loopback endpoints appear as ports.
  final bool includeDiagnosticLoopback;

  /// The time [start] waits for the first port list.
  final Duration enumerationTimeout;

  /// The time to wait for Windows to complete a request.
  final Duration requestTimeout;

  /// How often the native clock is mapped anew.
  final Duration resyncInterval;

  @override
  String get name => WindowsMidiPortKind.backend;

  @override
  MidiCapabilities get capabilities => _running
      ? MidiCapabilities(
          virtualPorts: _virtualPorts == null
              ? MidiVirtualPortSupport.none
              : MidiVirtualPortSupport.dynamicPorts,
          bleScan: _bluetooth != null,
          ump: _midi2,
          scheduling: _midi2
              ? MidiSchedulingSupport.hardware
              : MidiSchedulingSupport.software,
        )
      : const MidiCapabilities.none();

  @override
  List<MidiPortInfo> get ports => _running ? _published : const [];

  @override
  MidiVirtualPortsBackend? get virtualPorts => _running ? _virtualPorts : null;

  @override
  MidiBluetoothBackend? get bluetooth => _running ? _bluetooth : null;

  @override
  MidiNetworkBackend? get network => null;

  // ...........................................................................
  void _configure(int features) {
    final midi2Available = features & AMW_FEATURE_MIDI2 != 0;
    if (api == WindowsMidiApi.midi2 && !midi2Available) {
      throw const MidiUnsupported('Windows MIDI Services');
    }
    _midi2 = api != WindowsMidiApi.midi1 && midi2Available;
    _midi1 = !_midi2 || features & AMW_FEATURE_MIDI2_HYBRID != 0;
    if (_midi1 && features & AMW_FEATURE_MIDI1 == 0) {
      throw const MidiUnsupported('Windows.Devices.Midi');
    }
    if (_midi1 && features & AMW_FEATURE_BLUETOOTH != 0) {
      _bluetooth = WindowsMidiBluetooth(
        shim: _shim,
        requests: _requests,
        ports: () => ports,
        portsChanged: _portsChanged.stream,
      );
    }
    if (_midi2 && features & AMW_FEATURE_VIRTUAL_DEVICES != 0) {
      _virtualPorts = WindowsMidiVirtualPorts(
        shim: _shim,
        requests: _requests,
        onCreated: _addOwn,
        handleOf: (port) => _own[port],
        onRemoved: _removeOwn,
        timeout: requestTimeout,
      );
    }
  }

  Future<void> _enumerate() async {
    var sources = 0;
    if (_midi1) sources |= AMW_SOURCE_MIDI1_IN | AMW_SOURCE_MIDI1_OUT;
    if (_midi2) {
      sources |= AMW_SOURCE_MIDI2;
      if (includeDiagnosticLoopback) sources |= AMW_SOURCE_MIDI2_LOOPBACK;
    }
    _pendingSources.addAll([
      for (final source in const [
        AMW_SOURCE_MIDI1_IN,
        AMW_SOURCE_MIDI1_OUT,
        AMW_SOURCE_MIDI2,
      ])
        if (sources & source != 0) source,
    ]);
    final enumerated = _enumerated = Completer<void>();
    _shim.watchStart(sources);
    await enumerated.future.timeout(
      enumerationTimeout,
      onTimeout: () => _report(
        MidiDiagnosticKind.nativeError,
        cause: 'The port enumeration did not complete in $enumerationTimeout',
      ),
    );
  }

  void _sourceDone(int source) {
    _pendingSources.remove(source);
    final enumerated = _enumerated;
    if (_pendingSources.isEmpty &&
        enumerated != null &&
        !enumerated.isCompleted) {
      enumerated.complete();
    }
  }

  // ...........................................................................
  void _drain() {
    if (_host == null || _stopped) return;
    _shim.rearm();
    try {
      for (
        var bytes = _shim.readEvents();
        bytes.isNotEmpty;
        bytes = _shim.readEvents()
      ) {
        _decoder.decodeEvents(bytes).forEach(_handle);
      }
    } on MidiException catch (error) {
      _report(
        MidiDiagnosticKind.nativeError,
        cause: 'Reading the events failed: $error',
      );
    } on FormatException catch (error) {
      _report(
        MidiDiagnosticKind.invalidData,
        cause: 'Malformed events: ${error.message}',
      );
    }
    _publish();
    for (final entry in [..._inputs.entries]) {
      _drainPort(entry.key, entry.value);
    }
  }

  void _handle(WindowsMidiShimEvent event) {
    switch (event) {
      case WindowsMidiShimPortAdded(:final port) ||
          WindowsMidiShimPortUpdated(:final port):
        _table.put(port);
      case WindowsMidiShimPortRemoved(:final source, :final id):
        _table.remove(source: source, id: id);
      case WindowsMidiShimEnumerationCompleted(:final source):
        _sourceDone(source);
      case WindowsMidiShimWatcherStopped(:final source, :final status):
        if (event.isAborted) {
          _report(
            MidiDiagnosticKind.nativeError,
            cause: 'The watcher of source $source failed (status $status)',
          );
        }
      case WindowsMidiShimCompletion():
        _requests.complete(event);
      case WindowsMidiShimPortDisconnected(:final handle):
        _disconnected(handle);
      case WindowsMidiShimBleAdvertisement():
        _bluetooth?.onAdvertisement(event);
      case WindowsMidiShimBleScanStopped(:final error):
        _bluetooth?.onScanStopped();
        if (error != 0) {
          _report(
            MidiDiagnosticKind.nativeError,
            cause: 'The Bluetooth LE scan stopped with BluetoothError $error',
          );
        }
      case WindowsMidiShimError(:final api, :final message, :final source):
        _report(
          MidiDiagnosticKind.nativeError,
          cause:
              '$api failed with ${WindowsMidiStatus.hex(event.status)}: '
              '$message',
        );
        if (source != 0) _sourceDone(source);
      case WindowsMidiShimEventsDropped(:final count):
        _report(
          MidiDiagnosticKind.queueOverflow,
          count: count,
          cause: 'The event queue of the shim was full',
        );
      case WindowsMidiShimUnknownEvent():
        // An event of a newer shim; nothing to do.
        break;
    }
  }

  void _drainPort(int handle, MidiPortId port) {
    try {
      for (;;) {
        final read = _shim.readPort(handle);
        if (read.dropped > 0) {
          _report(
            MidiDiagnosticKind.queueOverflow,
            port: port,
            count: read.dropped,
            cause: 'The receive buffer of the shim was full',
          );
        }
        if (read.records.isEmpty) return;
        for (final record in _decoder.decodeRecords(read.records)) {
          _host!.received(port, _packet(record));
        }
      }
    } on MidiException catch (error) {
      _report(
        MidiDiagnosticKind.nativeError,
        port: port,
        cause: 'Reading the port failed: $error',
      );
      _inputs.remove(handle);
      _forget(port);
    } on FormatException catch (error) {
      _report(
        MidiDiagnosticKind.invalidData,
        port: port,
        cause: 'Malformed records: ${error.message}',
      );
    }
  }

  MidiPacket _packet(WindowsMidiDataRecord record) {
    final time = _clock.toPackage(record.timeMicros);
    return record.isUmp
        ? MidiUmpPacket(words: record.words, time: time)
        : MidiBytesPacket(bytes: MidiBytes(record.data), time: time);
  }

  void _publish() {
    if (!_running) return;
    final current = _table.ports;
    final events = WindowsMidiPortTable.diff(_published, current);
    _published = current;
    if (events.isEmpty) return;
    _clock.resync();
    for (final event in events) {
      if (event is MidiPortRemoved) _close(event.port.id);
    }
    _host!.portsChanged(events);
    _portsChanged.add(null);
  }

  // ...........................................................................
  Future<void> _openNative(MidiPortId port) async {
    final parsed = WindowsMidiPortKind.parse(port);
    if (_table.find(port) == null || parsed == null) throw MidiPortGone(port);
    final completion = await _requests.run<WindowsMidiShimOpenCompleted>(
      send: (request) => _shim.openPort(
        request: request,
        id: parsed.windowsId,
        kind: parsed.kind.shimKind,
      ),
      timeout: requestTimeout,
      onTimeout: () => const MidiNativeError(
        api: 'amw_port_open',
        code: WindowsMidiStatus.timeout,
      ),
      onLate: (late) {
        if (late.isSuccess) _quietly(() => _shim.closePort(late.handle));
      },
    );
    WindowsMidiStatus.check(
      api: 'amw_port_open',
      status: completion.status,
      port: port,
    );
    if (_stopped || _table.find(port) == null) {
      _quietly(() => _shim.closePort(completion.handle));
      throw MidiPortGone(port);
    }
    _open[port] = completion.handle;
    _handles[completion.handle] = port;
    if (parsed.kind.direction == MidiDirection.input) {
      _inputs[completion.handle] = port;
      // Data that arrived with the completion signalled before the handle
      // was known.
      _drainPort(completion.handle, port);
    }
  }

  void _addOwn(MidiPortInfo port, int handle, String productInstanceId) {
    _own[port.id] = handle;
    _handles[handle] = port.id;
    _table.putOwn(port, productInstanceId: productInstanceId);
    _publish();
    if (port.isInput) {
      _inputs[handle] = port.id;
      _drainPort(handle, port.id);
    }
  }

  void _removeOwn(MidiPortId port) {
    final handle = _own.remove(port);
    _handles.remove(handle);
    _inputs.remove(handle);
    _table.removeOwn(port);
    _publish();
  }

  void _disconnected(int handle) {
    final port = _handles[handle];
    if (port == null || _own.containsKey(port)) return;
    _close(port);
    _table.markDisconnected(port);
  }

  /// Forgets the open [port] without closing it natively.
  void _forget(MidiPortId port) {
    final handle = _open.remove(port);
    _handles.remove(handle);
    _inputs.remove(handle);
  }

  /// Forgets the open [port] and closes it natively.
  void _close(MidiPortId port) {
    final handle = _open[port];
    if (handle == null) return;
    _forget(port);
    _quietly(() => _shim.closePort(handle));
  }

  void _quietly(void Function() call) {
    try {
      call();
    } on MidiException catch (error) {
      _report(MidiDiagnosticKind.nativeError, cause: '$error');
    }
  }

  void _report(
    MidiDiagnosticKind kind, {
    required String cause,
    MidiPortId? port,
    int count = 1,
  }) {
    final host = _host!;
    host.diagnostic(
      MidiDiagnostic(
        kind: kind,
        port: port,
        count: count,
        cause: cause,
        time: host.clock.now(),
      ),
    );
  }

  void _checkRunning() {
    if (!_running) throw StateError('The backend is not running');
  }

  /// Returns the output [port]; throws for unknown ports and inputs.
  MidiPortInfo _output(MidiPortId port) {
    final info = _table.find(port);
    if (info == null) throw MidiPortGone(port);
    if (!info.isOutput) {
      throw ArgumentError.value(port, 'port', 'The port is no output');
    }
    return info;
  }

  static Uint8List _wordBytes(List<int> words) {
    final data = ByteData(words.length * 4);
    for (var i = 0; i < words.length; i++) {
      data.setUint32(i * 4, words[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  final WindowsMidiShim _shim;
  final WindowsMidiShimDecoder _decoder = const WindowsMidiShimDecoder();
  final WindowsMidiPortTable _table = WindowsMidiPortTable();
  final WindowsMidiRequests _requests = WindowsMidiRequests();
  final StreamController<void> _portsChanged = StreamController.broadcast(
    sync: true,
  );
  final Set<int> _pendingSources = {};
  final Map<MidiPortId, int> _open = {};
  final Map<MidiPortId, int> _own = {};
  final Map<int, MidiPortId> _handles = {};
  final Map<int, MidiPortId> _inputs = {};
  final Map<MidiPortId, Future<void>> _opening = {};
  MidiBackendHost? _host;
  late MidiClockMapper _clock;
  Completer<void>? _enumerated;
  Timer? _resync;
  WindowsMidiBluetooth? _bluetooth;
  WindowsMidiVirtualPorts? _virtualPorts;
  List<MidiPortInfo> _published = const [];
  bool _midi1 = false;
  bool _midi2 = false;
  bool _running = false;
  bool _stopped = false;
}
