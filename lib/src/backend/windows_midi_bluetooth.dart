// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../shim/aud_midi_windows_bindings.g.dart';
import '../shim/windows_midi_shim.dart';
import '../shim/windows_midi_shim_event.dart';
import '../shim/windows_midi_status.dart';
import 'windows_midi_requests.dart';

// #############################################################################
/// Finds and connects BLE-MIDI peripherals through the Windows pairing API.
///
/// A scan watches the advertisements of the BLE-MIDI service. Connecting
/// pairs the peripheral with the confirm-only ceremony; Windows then
/// exposes it as a WinRT MIDI 1.0 input and output port, which [connect]
/// waits for. Disconnecting unpairs it, and its ports disappear.
final class WindowsMidiBluetooth implements MidiBluetoothBackend {
  /// Creates the Bluetooth support on [shim].
  ///
  /// - [requests] pairs the pairing requests with their completions.
  /// - [ports] returns the current ports of the backend.
  /// - [portsChanged] fires after every change of [ports].
  /// - [settle] the time [connect] waits for the second port after the
  ///   first one appeared.
  /// - [unpairTimeout] the time [disconnect] waits for Windows.
  WindowsMidiBluetooth({
    required this._shim,
    required this._requests,
    required this._ports,
    required this._portsChanged,
    this.settle = const Duration(milliseconds: 500),
    this.unpairTimeout = const Duration(seconds: 10),
  });

  // ...........................................................................
  @override
  Stream<MidiBlePeripheralInfo> scan({Duration? timeout}) {
    close();
    _shim.bleScanStart();
    late final StreamController<MidiBlePeripheralInfo> controller;
    controller = StreamController<MidiBlePeripheralInfo>(
      // A scan that a newer one replaced must not stop the newer one.
      onCancel: () => identical(_scan, controller) ? stopScan() : null,
    );
    _scan = controller;
    if (timeout != null) _timer = Timer(timeout, () => unawaited(stopScan()));
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    if (_scan == null) return;
    close();
    try {
      _shim.bleScanStop();
    } on MidiException {
      // The scan ends either way.
    }
  }

  // ...........................................................................
  @override
  Future<List<MidiPortInfo>> connect(
    String peripheralId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final address = parseAddress(peripheralId);
    final stopwatch = Stopwatch()..start();
    final completion = await _requests.run<WindowsMidiShimBlePairCompleted>(
      send: (request) => _shim.blePair(request: request, address: address),
      timeout: timeout,
      onTimeout: () => const MidiNativeError(
        api: 'DeviceInformationCustomPairing.PairAsync',
        code: WindowsMidiStatus.timeout,
      ),
    );
    _check(
      api: 'DeviceInformationCustomPairing.PairAsync',
      status: completion.status,
      success: completion.isPaired,
      result: completion.result,
      accessDenied: WindowsMidiShimBlePairCompleted.accessDenied,
    );
    final remaining = timeout - stopwatch.elapsed;
    return _waitForPorts(
      address,
      remaining.isNegative ? Duration.zero : remaining,
    );
  }

  @override
  Future<void> disconnect(String peripheralId) async {
    final address = parseAddress(peripheralId);
    final completion = await _requests.run<WindowsMidiShimBleUnpairCompleted>(
      send: (request) => _shim.bleUnpair(request: request, address: address),
      timeout: unpairTimeout,
      onTimeout: () => const MidiNativeError(
        api: 'DeviceInformationPairing.UnpairAsync',
        code: WindowsMidiStatus.timeout,
      ),
    );
    _check(
      api: 'DeviceInformationPairing.UnpairAsync',
      status: completion.status,
      success: completion.isUnpaired,
      result: completion.result,
      accessDenied: WindowsMidiShimBleUnpairCompleted.accessDenied,
    );
  }

  // ...........................................................................
  /// Reports the peripheral of [event] to the running scan.
  void onAdvertisement(WindowsMidiShimBleAdvertisement event) {
    _scan?.add(
      MidiBlePeripheralInfo(
        id: addressText(event.address),
        name: event.name,
        rssi: event.rssi,
        isConnectable: event.flags & AMW_BLE_CONNECTABLE != 0,
      ),
    );
  }

  /// Ends the running scan, which Windows stopped.
  void onScanStopped() => close();

  /// Ends the running scan without stopping it natively, e.g. when the
  /// backend stops.
  void close() {
    _timer?.cancel();
    _timer = null;
    final controller = _scan;
    _scan = null;
    unawaited(controller?.close());
  }

  // ...........................................................................
  /// The time [connect] waits for the second port of a peripheral.
  final Duration settle;

  /// The time [disconnect] waits for Windows.
  final Duration unpairTimeout;

  /// Whether a scan runs.
  bool get isScanning => _scan != null;

  // ...........................................................................
  /// Returns the peripheral id of the Bluetooth [address]: six lower-case
  /// hex pairs separated by colons, e.g. `c0:a1:b2:c3:d4:e5`.
  static String addressText(int address) {
    final hex = address.toRadixString(16).padLeft(12, '0');
    return [
      for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2),
    ].join(':');
  }

  /// Parses a peripheral id of [addressText], with or without separators.
  ///
  /// Throws an [ArgumentError] when [peripheralId] is no Bluetooth address.
  static int parseAddress(String peripheralId) {
    final hex = peripheralId.replaceAll(RegExp('[:-]'), '');
    final value = hex.length == 12 ? int.tryParse(hex, radix: 16) : null;
    if (value == null) {
      throw ArgumentError.value(
        peripheralId,
        'peripheralId',
        'Not a Bluetooth address',
      );
    }
    return value;
  }

  /// Whether [port] belongs to the peripheral at [address]: Windows puts
  /// the address into the ids of BLE-MIDI ports.
  static bool isPortOf(MidiPortInfo port, int address) {
    if (port.transport != MidiTransport.bluetoothLe) return false;
    final hex = address.toRadixString(16).padLeft(12, '0');
    final ids =
        '${port.native['windowsId'] ?? ''}|'
                '${port.native['deviceInstanceId'] ?? ''}'
            .toLowerCase();
    return ids.contains(hex);
  }

  // ...........................................................................
  void _check({
    required String api,
    required int status,
    required bool success,
    required int result,
    required int accessDenied,
  }) {
    WindowsMidiStatus.check(
      api: api,
      status: status,
      permission: MidiPermission.bluetooth,
      feature: 'Bluetooth LE MIDI',
    );
    if (success) return;
    if (result == accessDenied) {
      throw WindowsMidiStatus.exception(
        api: api,
        status: AMW_E_ACCESS_DENIED,
        permission: MidiPermission.bluetooth,
      );
    }
    throw MidiNativeError(api: api, code: result);
  }

  Future<List<MidiPortInfo>> _waitForPorts(int address, Duration timeout) {
    final completer = Completer<List<MidiPortInfo>>();
    List<MidiPortInfo> matching() => [
      for (final port in _ports())
        if (isPortOf(port, address)) port,
    ];
    void finish() {
      if (!completer.isCompleted) completer.complete(matching());
    }

    Timer? settleTimer;
    void check() {
      final found = matching();
      if (found.isEmpty) return;
      if (found.any((port) => port.isInput) &&
          found.any((port) => port.isOutput)) {
        finish();
      } else {
        settleTimer ??= Timer(settle, finish);
      }
    }

    final subscription = _portsChanged.listen((_) => check());
    final timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      completer.completeError(
        const MidiNativeError(
          api: 'BLE-MIDI port',
          code: WindowsMidiStatus.timeout,
        ),
      );
    });
    check();
    return completer.future.whenComplete(() {
      timer.cancel();
      settleTimer?.cancel();
      return subscription.cancel();
    });
  }

  final WindowsMidiShim _shim;
  final WindowsMidiRequests _requests;
  final List<MidiPortInfo> Function() _ports;
  final Stream<void> _portsChanged;
  StreamController<MidiBlePeripheralInfo>? _scan;
  Timer? _timer;
}
