// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:typed_data';

import 'aud_midi_windows_bindings.g.dart';
import 'windows_midi_byte_writer.dart';
import 'windows_midi_endpoint_record.dart';
import 'windows_midi_port_record.dart';
import 'windows_midi_shim.dart';
import 'windows_midi_shim_event.dart';
import 'windows_midi_status.dart';

// #############################################################################
/// An in-memory [WindowsMidiShim] for tests of the backend and of apps.
///
/// It keeps the ports of every watcher source, answers requests on its own
/// and hands out events and data records in the binary format of the shim,
/// so the decoders run as in production. Signals arrive like those of
/// `NativeCallable.listener`: as a later task of the event loop, at most one
/// until [rearm].
final class WindowsMidiFakeShim implements WindowsMidiShim {
  /// Creates a fake with [features] and the initial [ports].
  ///
  /// - [clockMicros] the native clock.
  WindowsMidiFakeShim({
    this.features = AMW_FEATURE_MIDI1,
    List<WindowsMidiPortRecord> ports = const [],
    this.clockMicros = 0,
  }) {
    for (final port in ports) {
      _ports[_key(port.source, port.id)] = port;
    }
  }

  // ...........................................................................
  @override
  void create({required void Function() onSignal}) {
    _call('create');
    _onSignal = onSignal;
    _lastSignal = onSignal;
    _created = true;
  }

  @override
  void destroy() {
    calls.add('destroy');
    _destroyed = true;
    _onSignal = null;
    _open.clear();
    _queues.clear();
    _watched = 0;
    _scanning = false;
  }

  // ...........................................................................
  @override
  int clockNowMicros() => clockMicros;

  @override
  void rearm() => _signalPending = false;

  @override
  Uint8List readEvents() {
    _call('readEvents', record: false);
    final bytes = _events.toBytes();
    _events = WindowsMidiByteWriter();
    return bytes;
  }

  // ...........................................................................
  @override
  void watchStart(int sources) {
    _call('watchStart($sources)');
    _watched = sources;
    for (final source in _sources) {
      if (sources & source == 0) continue;
      for (final port in _ports.values) {
        if (port.source == source) _emitPort(AMW_EVENT_PORT_ADDED, port);
      }
      if (completeEnumeration) completeEnumerationOf(source);
    }
  }

  @override
  void watchStop() {
    _call('watchStop');
    _watched = 0;
  }

  // ...........................................................................
  @override
  void openPort({required int request, required String id, required int kind}) {
    _call('openPort($id, $kind)');
    _pendingOpens[request] = (id: id, kind: kind);
    if (autoComplete) completeOpen(request);
  }

  @override
  void closePort(int handle) {
    _call('closePort($handle)');
    if (_open.remove(handle) == null) {
      throw WindowsMidiStatus.exception(
        api: 'amw_port_close',
        status: AMW_E_UNKNOWN_HANDLE,
      );
    }
    _queues.remove(handle);
  }

  @override
  ({Uint8List records, int dropped}) readPort(int handle) {
    _call('readPort($handle)', record: false);
    final queue = _queues[handle];
    if (queue == null) {
      throw WindowsMidiStatus.exception(
        api: 'amw_port_read',
        status: AMW_E_UNKNOWN_HANDLE,
      );
    }
    final result = (records: queue.records.toBytes(), dropped: queue.dropped);
    _queues[handle] = (records: WindowsMidiByteWriter(), dropped: 0);
    return result;
  }

  @override
  void send({
    required int handle,
    required Uint8List data,
    required int dueMicros,
  }) {
    _call('send($handle)');
    if (!_open.containsKey(handle)) {
      throw WindowsMidiStatus.exception(
        api: 'amw_port_send',
        status: AMW_E_UNKNOWN_HANDLE,
      );
    }
    sent.add((
      handle: handle,
      data: Uint8List.fromList(data),
      dueMicros: dueMicros,
    ));
  }

  // ...........................................................................
  @override
  void bleScanStart() {
    _call('bleScanStart');
    _scanning = true;
  }

  @override
  void bleScanStop() {
    _call('bleScanStop');
    _scanning = false;
  }

  @override
  void blePair({required int request, required int address}) {
    _call('blePair($address)');
    _pendingPairs[request] = (address: address, pair: true);
    if (autoComplete) completePairing(request);
  }

  @override
  void bleUnpair({required int request, required int address}) {
    _call('bleUnpair($address)');
    _pendingPairs[request] = (address: address, pair: false);
    if (autoComplete) completePairing(request);
  }

  // ...........................................................................
  @override
  void virtualCreate({required int request, required Uint8List spec}) {
    _call('virtualCreate');
    virtualSpecs.add(Uint8List.fromList(spec));
    _pendingVirtual.add(request);
    if (autoComplete) completeVirtual(request);
  }

  // ...........................................................................
  /// Adds [port]; its watcher reports it when it runs.
  void addPort(WindowsMidiPortRecord port) {
    _ports[_key(port.source, port.id)] = port;
    if (_watched & port.source != 0) _emitPort(AMW_EVENT_PORT_ADDED, port);
  }

  /// Replaces the information of [port]; its watcher reports the update.
  void updatePort(WindowsMidiPortRecord port) {
    _ports[_key(port.source, port.id)] = port;
    if (_watched & port.source != 0) _emitPort(AMW_EVENT_PORT_UPDATED, port);
  }

  /// Removes the port [id] of the watcher [source].
  void removePort({required int source, required String id}) {
    _ports.remove(_key(source, id));
    if (_watched & source == 0) return;
    _emit(AMW_EVENT_PORT_REMOVED, (out) {
      out.u32(source);
      out.string(id);
    });
  }

  /// Reports the end of the enumeration of the watcher [source].
  void completeEnumerationOf(int source) =>
      _emit(AMW_EVENT_ENUMERATION_COMPLETED, (out) => out.u32(source));

  /// Reports that the watcher [source] stopped with the DeviceWatcherStatus
  /// [status].
  void stopWatcher({required int source, required int status}) =>
      _emit(AMW_EVENT_WATCHER_STOPPED, (out) {
        out.u32(source);
        out.u32(status);
      });

  /// Completes the open [request], with [status] or the status of
  /// [openStatus] for its port; a success opens a new handle.
  void completeOpen(int request, {int? status}) {
    final pending = _pendingOpens.remove(request)!;
    final result = status ?? openStatus[pending.id] ?? AMW_OK;
    final handle = result < 0 ? 0 : _register(pending.id, pending.kind);
    _emit(AMW_EVENT_OPEN_COMPLETED, (out) {
      out.u64(request);
      out.u32(result);
      out.u32(handle);
      out.string(result < 0 ? 'fake failure' : '');
    });
  }

  /// Completes the pairing or unpairing [request] with [pairStatus] and
  /// [pairResult], or [unpairStatus] and [unpairResult].
  void completePairing(int request) {
    final pending = _pendingPairs.remove(request)!;
    final status = pending.pair ? pairStatus : unpairStatus;
    _emit(
      pending.pair
          ? AMW_EVENT_BLE_PAIR_COMPLETED
          : AMW_EVENT_BLE_UNPAIR_COMPLETED,
      (out) {
        out.u64(request);
        out.u32(status);
        out.u32(pending.pair ? pairResult : unpairResult);
        out.string(status < 0 ? 'fake failure' : '');
      },
    );
  }

  /// Completes the virtual device [request] with [virtualStatus]; a success
  /// opens a new handle of kind `AMW_KIND_VIRTUAL`.
  void completeVirtual(int request) {
    _pendingVirtual.remove(request);
    final status = virtualStatus;
    final endpointId = 'fake-virtual-$request';
    final handle = status < 0 ? 0 : _register(endpointId, AMW_KIND_VIRTUAL);
    _emit(AMW_EVENT_VIRTUAL_CREATED, (out) {
      out.u64(request);
      out.u32(status);
      out.u32(handle);
      out.string(status < 0 ? '' : endpointId);
      out.string(status < 0 ? 'fake failure' : '');
    });
  }

  /// Delivers the message [data] to the input [handle], received at the
  /// native time [timeMicros]; [ump] marks UMP words.
  void receive(
    int handle,
    List<int> data, {
    required int timeMicros,
    bool ump = false,
  }) {
    final records = _queues[handle]!.records;
    records.u64(timeMicros);
    records.u32(ump ? AMW_RECORD_UMP : 0);
    records.u32(data.length);
    records.bytes(data);
    _signal();
  }

  /// Counts [count] messages the input [handle] lost.
  void overflow(int handle, int count) {
    final queue = _queues[handle]!;
    _queues[handle] = (records: queue.records, dropped: queue.dropped + count);
    _signal();
  }

  /// Reports that the endpoint of the port [handle] disconnected.
  void disconnect(int handle) =>
      _emit(AMW_EVENT_PORT_DISCONNECTED, (out) => out.u32(handle));

  /// Reports a BLE-MIDI peripheral at [address].
  void advertise({
    required int address,
    int rssi = -60,
    String name = '',
    bool connectable = true,
  }) => _emit(AMW_EVENT_BLE_ADVERTISEMENT, (out) {
    out.u64(address);
    out.u32(rssi);
    out.u32(connectable ? AMW_BLE_CONNECTABLE : 0);
    out.string(name);
  });

  /// Reports that the scan stopped with the BluetoothError [error].
  void stopScan(int error) {
    _scanning = false;
    _emit(AMW_EVENT_BLE_SCAN_STOPPED, (out) => out.u32(error));
  }

  /// Reports that [api] failed asynchronously with [status].
  void fail({
    required int status,
    int source = 0,
    String api = 'fake',
    String message = '',
  }) => _emit(AMW_EVENT_ERROR, (out) {
    out.u32(status);
    out.u32(source);
    out.string(api);
    out.string(message);
  });

  /// Reports that [count] events were dropped.
  void dropEvents(int count) =>
      _emit(AMW_EVENT_EVENTS_DROPPED, (out) => out.u64(count));

  /// Emits a raw event of [kind] with [payload].
  void emit(int kind, List<int> payload) => _emit(kind, (out) {
    out.bytes(payload);
  });

  /// Appends raw [bytes] to the records of the input [handle], e.g. to
  /// simulate a damaged buffer.
  void corrupt(int handle, List<int> bytes) {
    _queues[handle]!.records.bytes(bytes);
    _signal();
  }

  /// Calls the signal callback of [create] at once, even after [destroy]:
  /// a signal that was on its way when the shim was destroyed.
  void signalNow() => _lastSignal?.call();

  // ...........................................................................
  /// The `AMW_FEATURE_*` bits [create] reports.
  @override
  int features;

  /// The native clock in microseconds.
  int clockMicros;

  /// Whether a watcher reports the end of its enumeration when it starts.
  bool completeEnumeration = true;

  /// Whether requests complete on their own; when false, tests complete
  /// them with [completeOpen], [completePairing] and [completeVirtual].
  bool autoComplete = true;

  /// The status the next call of a method fails with, by method name, e.g.
  /// `{'send': AMW_E_CLOSED}`; an entry is used once.
  final Map<String, int> failures = {};

  /// The status open requests complete with, by port id.
  final Map<String, int> openStatus = {};

  /// The status of pair requests.
  int pairStatus = AMW_OK;

  /// The DevicePairingResultStatus of pair requests.
  int pairResult = WindowsMidiShimBlePairCompleted.paired;

  /// The status of unpair requests.
  int unpairStatus = AMW_OK;

  /// The DeviceUnpairingResultStatus of unpair requests.
  int unpairResult = WindowsMidiShimBleUnpairCompleted.unpaired;

  /// The status of virtual device requests.
  int virtualStatus = AMW_OK;

  /// The calls so far except the polling ones, `readEvents` and
  /// `readPort`, e.g. `watchStart(3)` or `closePort(1)`.
  final List<String> calls = [];

  /// The data sent so far.
  final List<({int handle, Uint8List data, int dueMicros})> sent = [];

  /// The encoded specifications of the virtual devices requested so far.
  final List<Uint8List> virtualSpecs = [];

  /// Whether [create] was called.
  bool get isCreated => _created;

  /// Whether [destroy] was called.
  bool get isDestroyed => _destroyed;

  /// The open ports by handle.
  Map<int, ({String id, int kind})> get openPorts => Map.unmodifiable(_open);

  /// The `AMW_SOURCE_*` bits of the running watchers.
  int get watchedSources => _watched;

  /// Whether a Bluetooth LE scan runs.
  bool get isScanning => _scanning;

  /// The ids of the open requests that wait for [completeOpen].
  List<int> get pendingOpens => List.unmodifiable(_pendingOpens.keys);

  /// The ids of the pairing requests that wait for [completePairing].
  List<int> get pendingPairings => List.unmodifiable(_pendingPairs.keys);

  /// The ids of the virtual device requests that wait for
  /// [completeVirtual].
  List<int> get pendingVirtual => List.unmodifiable(_pendingVirtual);

  // ...........................................................................
  /// WinRT MIDI 1.0 is available (`AMW_FEATURE_MIDI1`).
  static const int featureMidi1 = AMW_FEATURE_MIDI1;

  /// The shim was built with Windows MIDI Services
  /// (`AMW_FEATURE_MIDI2_BUILT`).
  static const int featureMidi2Built = AMW_FEATURE_MIDI2_BUILT;

  /// Windows MIDI Services is usable (`AMW_FEATURE_MIDI2`).
  static const int featureMidi2 = AMW_FEATURE_MIDI2;

  /// Windows MIDI Services runs in hybrid legacy mode
  /// (`AMW_FEATURE_MIDI2_HYBRID`).
  static const int featureMidi2Hybrid = AMW_FEATURE_MIDI2_HYBRID;

  /// A Bluetooth LE radio is present (`AMW_FEATURE_BLUETOOTH`).
  static const int featureBluetooth = AMW_FEATURE_BLUETOOTH;

  /// Virtual devices are available (`AMW_FEATURE_VIRTUAL_DEVICES`).
  static const int featureVirtualDevices = AMW_FEATURE_VIRTUAL_DEVICES;

  // ...........................................................................
  static const List<int> _sources = [
    AMW_SOURCE_MIDI1_IN,
    AMW_SOURCE_MIDI1_OUT,
    AMW_SOURCE_MIDI2,
  ];

  static String _key(int source, String id) => '$source|$id';

  void _call(String call, {bool record = true}) {
    if (record) calls.add(call);
    final name = call.split('(').first;
    final status = failures.remove(name);
    if (status != null) {
      throw WindowsMidiStatus.exception(api: 'fake $name', status: status);
    }
  }

  int _register(String id, int kind) {
    final handle = _nextHandle++;
    _open[handle] = (id: id, kind: kind);
    if (kind != AMW_KIND_MIDI1_OUT && kind != AMW_KIND_MIDI2_OUT) {
      _queues[handle] = (records: WindowsMidiByteWriter(), dropped: 0);
    }
    return handle;
  }

  void _emitPort(int kind, WindowsMidiPortRecord port) =>
      _emit(kind, (out) => _writePort(out, port));

  void _emit(int kind, void Function(WindowsMidiByteWriter out) write) {
    final payload = WindowsMidiByteWriter();
    write(payload);
    final bytes = payload.toBytes();
    _events.u32(kind);
    _events.u32(bytes.length);
    _events.bytes(bytes);
    _signal();
  }

  void _signal() {
    if (_signalPending) return;
    _signalPending = true;
    Timer.run(() => _onSignal?.call());
  }

  void _writePort(WindowsMidiByteWriter out, WindowsMidiPortRecord port) {
    out.u32(port.source);
    out.string(port.id);
    out.string(port.name);
    out.u32(port.flags);
    out.string(port.deviceInstanceId);
    out.string(port.containerId);
    final endpoint = port.endpoint;
    out.u8(endpoint == null ? 0 : 1);
    if (endpoint != null) _writeEndpoint(out, endpoint);
  }

  void _writeEndpoint(WindowsMidiByteWriter out, WindowsMidiEndpointRecord e) {
    out.u32(e.purpose);
    out.u32(e.nativeDataFormat);
    out.string(e.transportCode);
    out.string(e.manufacturer);
    out.string(e.serialNumber);
    out.string(e.description);
    out.u16(e.vendorId);
    out.u16(e.productId);
    final identity = e.identity;
    out.u32(
      identity == null
          ? e.flags & ~AMW_ENDPOINT_HAS_IDENTITY
          : e.flags | AMW_ENDPOINT_HAS_IDENTITY,
    );
    out.string(e.endpointName);
    out.string(e.productInstanceId);
    out.u8(e.declaredFunctionBlockCount);
    out.u8(e.umpVersionMajor);
    out.u8(e.umpVersionMinor);
    out.u8(e.protocol);
    out.bytes(
      identity == null
          ? List.filled(11, 0)
          : [
              ...identity.manufacturerId,
              identity.familyId & 0x7F,
              identity.familyId >> 7,
              identity.modelId & 0x7F,
              identity.modelId >> 7,
              ...identity.softwareRevision,
            ],
    );
    out.u32(e.functionBlocks.length);
    for (final block in e.functionBlocks) {
      out.bytes([
        block.number,
        block.isActive ? 1 : 0,
        block.direction.value,
        block.uiHint.value,
        block.midi1.value,
        block.firstGroup,
        block.groupCount,
        block.midiCiVersion,
        block.maxSysEx8Streams,
      ]);
      out.string(block.name);
    }
    out.u32(e.groupTerminalBlocks.length);
    for (final block in e.groupTerminalBlocks) {
      out.bytes([
        block.number,
        block.direction,
        block.protocol,
        block.firstGroup,
        block.groupCount,
      ]);
      out.string(block.name);
    }
  }

  final Map<String, WindowsMidiPortRecord> _ports = {};
  final Map<int, ({String id, int kind})> _open = {};
  final Map<int, ({WindowsMidiByteWriter records, int dropped})> _queues = {};
  final Map<int, ({String id, int kind})> _pendingOpens = {};
  final Map<int, ({int address, bool pair})> _pendingPairs = {};
  final List<int> _pendingVirtual = [];
  WindowsMidiByteWriter _events = WindowsMidiByteWriter();
  void Function()? _onSignal;
  void Function()? _lastSignal;
  bool _signalPending = false;
  bool _created = false;
  bool _destroyed = false;
  int _watched = 0;
  bool _scanning = false;
  int _nextHandle = 1;
}
