// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'windows_midi_list_equality.dart';
import 'windows_midi_port_record.dart';

// #############################################################################
/// An event of the shim, as `amw_read_events` hands it out
/// (`src/aud_midi_windows.h`).
sealed class WindowsMidiShimEvent {
  /// Creates an event.
  const WindowsMidiShimEvent();
}

// #############################################################################
/// A watcher found a port (`AMW_EVENT_PORT_ADDED`).
final class WindowsMidiShimPortAdded extends WindowsMidiShimEvent {
  /// Creates the event for [port].
  const WindowsMidiShimPortAdded(this.port);

  // ...........................................................................
  /// The port that appeared.
  final WindowsMidiPortRecord port;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimPortAdded && other.port == port;

  @override
  int get hashCode => Object.hash(WindowsMidiShimPortAdded, port);

  @override
  String toString() => 'WindowsMidiShimPortAdded($port)';
}

// #############################################################################
/// The information of a port changed (`AMW_EVENT_PORT_UPDATED`).
final class WindowsMidiShimPortUpdated extends WindowsMidiShimEvent {
  /// Creates the event for [port].
  const WindowsMidiShimPortUpdated(this.port);

  // ...........................................................................
  /// The port with its new information.
  final WindowsMidiPortRecord port;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimPortUpdated && other.port == port;

  @override
  int get hashCode => Object.hash(WindowsMidiShimPortUpdated, port);

  @override
  String toString() => 'WindowsMidiShimPortUpdated($port)';
}

// #############################################################################
/// A port disappeared (`AMW_EVENT_PORT_REMOVED`).
final class WindowsMidiShimPortRemoved extends WindowsMidiShimEvent {
  /// Creates the event for the port [id] of the watcher [source].
  const WindowsMidiShimPortRemoved({required this.source, required this.id});

  // ...........................................................................
  /// The watcher that reported the port.
  final int source;

  /// The Windows device id of the port.
  final String id;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimPortRemoved &&
      other.source == source &&
      other.id == id;

  @override
  int get hashCode => Object.hash(WindowsMidiShimPortRemoved, source, id);

  @override
  String toString() => "WindowsMidiShimPortRemoved(source: $source, id: '$id')";
}

// #############################################################################
/// A watcher reported every port that existed when it started
/// (`AMW_EVENT_ENUMERATION_COMPLETED`).
final class WindowsMidiShimEnumerationCompleted extends WindowsMidiShimEvent {
  /// Creates the event for the watcher [source].
  const WindowsMidiShimEnumerationCompleted(this.source);

  // ...........................................................................
  /// The watcher.
  final int source;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimEnumerationCompleted && other.source == source;

  @override
  int get hashCode => Object.hash(WindowsMidiShimEnumerationCompleted, source);

  @override
  String toString() => 'WindowsMidiShimEnumerationCompleted($source)';
}

// #############################################################################
/// A watcher stopped on its own (`AMW_EVENT_WATCHER_STOPPED`).
final class WindowsMidiShimWatcherStopped extends WindowsMidiShimEvent {
  /// Creates the event for the watcher [source] with its DeviceWatcherStatus
  /// [status].
  const WindowsMidiShimWatcherStopped({
    required this.source,
    required this.status,
  });

  // ...........................................................................
  /// The watcher.
  final int source;

  /// The DeviceWatcherStatus of the watcher, [statusAborted] after a
  /// failure.
  final int status;

  /// Whether the watcher stopped because it failed.
  bool get isAborted => status == statusAborted;

  // ...........................................................................
  /// The DeviceWatcherStatus of a failed watcher.
  static const int statusAborted = 5;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimWatcherStopped &&
      other.source == source &&
      other.status == status;

  @override
  int get hashCode =>
      Object.hash(WindowsMidiShimWatcherStopped, source, status);

  @override
  String toString() =>
      'WindowsMidiShimWatcherStopped(source: $source, status: $status)';
}

// #############################################################################
/// The result of an asynchronous request of the shim, carrying the request
/// id the caller passed.
sealed class WindowsMidiShimCompletion extends WindowsMidiShimEvent {
  /// Creates the completion of [request].
  const WindowsMidiShimCompletion({
    required this.request,
    required this.status,
    this.message = '',
  });

  // ...........................................................................
  /// The request id the caller passed.
  final int request;

  /// The status: 0 or more on success, an HRESULT on failure.
  final int status;

  /// The message of a failure, empty on success.
  final String message;

  /// Whether the request succeeded.
  bool get isSuccess => status >= 0;
}

// #############################################################################
/// A port opened, or failed to (`AMW_EVENT_OPEN_COMPLETED`).
final class WindowsMidiShimOpenCompleted extends WindowsMidiShimCompletion {
  /// Creates the completion of [request] with the [handle] of the port.
  const WindowsMidiShimOpenCompleted({
    required super.request,
    required super.status,
    this.handle = 0,
    super.message,
  });

  // ...........................................................................
  /// The handle of the open port, 0 on failure.
  final int handle;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimOpenCompleted &&
      other.request == request &&
      other.status == status &&
      other.handle == handle &&
      other.message == message;

  @override
  int get hashCode => Object.hash(
    WindowsMidiShimOpenCompleted,
    request,
    status,
    handle,
    message,
  );

  @override
  String toString() =>
      'WindowsMidiShimOpenCompleted(request: $request, status: $status, '
      "handle: $handle, message: '$message')";
}

// #############################################################################
/// The endpoint of an open UMP port disconnected
/// (`AMW_EVENT_PORT_DISCONNECTED`).
final class WindowsMidiShimPortDisconnected extends WindowsMidiShimEvent {
  /// Creates the event for the port [handle].
  const WindowsMidiShimPortDisconnected(this.handle);

  // ...........................................................................
  /// The handle of the port.
  final int handle;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimPortDisconnected && other.handle == handle;

  @override
  int get hashCode => Object.hash(WindowsMidiShimPortDisconnected, handle);

  @override
  String toString() => 'WindowsMidiShimPortDisconnected($handle)';
}

// #############################################################################
/// A scan found a BLE-MIDI peripheral or saw it again
/// (`AMW_EVENT_BLE_ADVERTISEMENT`).
final class WindowsMidiShimBleAdvertisement extends WindowsMidiShimEvent {
  /// Creates the event for the peripheral at the Bluetooth [address].
  ///
  /// - [rssi] the signal strength in dBm.
  /// - [flags] the `AMW_BLE_*` bits.
  const WindowsMidiShimBleAdvertisement({
    required this.address,
    required this.rssi,
    this.flags = 0,
    this.name = '',
  });

  // ...........................................................................
  /// The 48-bit Bluetooth address.
  final int address;

  /// The signal strength in dBm.
  final int rssi;

  /// The `AMW_BLE_*` bits.
  final int flags;

  /// The local name, empty when unknown.
  final String name;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimBleAdvertisement &&
      other.address == address &&
      other.rssi == rssi &&
      other.flags == flags &&
      other.name == name;

  @override
  int get hashCode =>
      Object.hash(WindowsMidiShimBleAdvertisement, address, rssi, flags, name);

  @override
  String toString() =>
      'WindowsMidiShimBleAdvertisement(address: $address, rssi: $rssi, '
      "flags: $flags, name: '$name')";
}

// #############################################################################
/// The Bluetooth LE scan stopped on its own (`AMW_EVENT_BLE_SCAN_STOPPED`).
final class WindowsMidiShimBleScanStopped extends WindowsMidiShimEvent {
  /// Creates the event with the BluetoothError value [error].
  const WindowsMidiShimBleScanStopped(this.error);

  // ...........................................................................
  /// The BluetoothError value, e.g. 1 when the radio is off.
  final int error;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimBleScanStopped && other.error == error;

  @override
  int get hashCode => Object.hash(WindowsMidiShimBleScanStopped, error);

  @override
  String toString() => 'WindowsMidiShimBleScanStopped($error)';
}

// #############################################################################
/// A Bluetooth LE device paired, or failed to
/// (`AMW_EVENT_BLE_PAIR_COMPLETED`).
final class WindowsMidiShimBlePairCompleted extends WindowsMidiShimCompletion {
  /// Creates the completion of [request] with the
  /// DevicePairingResultStatus [result].
  const WindowsMidiShimBlePairCompleted({
    required super.request,
    required super.status,
    required this.result,
    super.message,
  });

  // ...........................................................................
  /// The DevicePairingResultStatus value, e.g. [paired].
  final int result;

  /// Whether the device is paired now.
  bool get isPaired => result == paired || result == alreadyPaired;

  // ...........................................................................
  /// The device paired.
  static const int paired = 0;

  /// The device was paired before.
  static const int alreadyPaired = 3;

  /// The application lacks the permission to pair.
  static const int accessDenied = 12;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimBlePairCompleted &&
      other.request == request &&
      other.status == status &&
      other.result == result &&
      other.message == message;

  @override
  int get hashCode => Object.hash(
    WindowsMidiShimBlePairCompleted,
    request,
    status,
    result,
    message,
  );

  @override
  String toString() =>
      'WindowsMidiShimBlePairCompleted(request: $request, status: $status, '
      "result: $result, message: '$message')";
}

// #############################################################################
/// A Bluetooth LE device unpaired, or failed to
/// (`AMW_EVENT_BLE_UNPAIR_COMPLETED`).
final class WindowsMidiShimBleUnpairCompleted
    extends WindowsMidiShimCompletion {
  /// Creates the completion of [request] with the
  /// DeviceUnpairingResultStatus [result].
  const WindowsMidiShimBleUnpairCompleted({
    required super.request,
    required super.status,
    required this.result,
    super.message,
  });

  // ...........................................................................
  /// The DeviceUnpairingResultStatus value, e.g. [unpaired].
  final int result;

  /// Whether the device is unpaired now.
  bool get isUnpaired => result == unpaired || result == alreadyUnpaired;

  // ...........................................................................
  /// The device unpaired.
  static const int unpaired = 0;

  /// The device was not paired.
  static const int alreadyUnpaired = 1;

  /// The application lacks the permission to unpair.
  static const int accessDenied = 3;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimBleUnpairCompleted &&
      other.request == request &&
      other.status == status &&
      other.result == result &&
      other.message == message;

  @override
  int get hashCode => Object.hash(
    WindowsMidiShimBleUnpairCompleted,
    request,
    status,
    result,
    message,
  );

  @override
  String toString() =>
      'WindowsMidiShimBleUnpairCompleted(request: $request, '
      "status: $status, result: $result, message: '$message')";
}

// #############################################################################
/// A virtual device was created, or failed to be
/// (`AMW_EVENT_VIRTUAL_CREATED`).
final class WindowsMidiShimVirtualCreated extends WindowsMidiShimCompletion {
  /// Creates the completion of [request] with the [handle] of the device
  /// side and its [endpointId].
  const WindowsMidiShimVirtualCreated({
    required super.request,
    required super.status,
    this.handle = 0,
    this.endpointId = '',
    super.message,
  });

  // ...........................................................................
  /// The handle of the device side, an open UMP port.
  final int handle;

  /// The endpoint device id of the device side.
  final String endpointId;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimVirtualCreated &&
      other.request == request &&
      other.status == status &&
      other.handle == handle &&
      other.endpointId == endpointId &&
      other.message == message;

  @override
  int get hashCode => Object.hash(
    WindowsMidiShimVirtualCreated,
    request,
    status,
    handle,
    endpointId,
    message,
  );

  @override
  String toString() =>
      'WindowsMidiShimVirtualCreated(request: $request, status: $status, '
      "handle: $handle, endpointId: '$endpointId', message: '$message')";
}

// #############################################################################
/// An asynchronous call into Windows failed (`AMW_EVENT_ERROR`).
final class WindowsMidiShimError extends WindowsMidiShimEvent {
  /// Creates the event for the failed [api] with [status].
  ///
  /// - [source] the watcher that failed to start, 0 for none.
  const WindowsMidiShimError({
    required this.status,
    this.source = 0,
    required this.api,
    this.message = '',
  });

  // ...........................................................................
  /// The HRESULT.
  final int status;

  /// The watcher that failed to start, 0 for none.
  final int source;

  /// The failed call.
  final String api;

  /// The message of Windows.
  final String message;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimError &&
      other.status == status &&
      other.source == source &&
      other.api == api &&
      other.message == message;

  @override
  int get hashCode =>
      Object.hash(WindowsMidiShimError, status, source, api, message);

  @override
  String toString() =>
      'WindowsMidiShimError(status: $status, source: $source, '
      "api: '$api', message: '$message')";
}

// #############################################################################
/// The event queue of the shim was full and dropped events
/// (`AMW_EVENT_EVENTS_DROPPED`).
final class WindowsMidiShimEventsDropped extends WindowsMidiShimEvent {
  /// Creates the event for [count] dropped events.
  const WindowsMidiShimEventsDropped(this.count);

  // ...........................................................................
  /// The number of dropped events.
  final int count;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimEventsDropped && other.count == count;

  @override
  int get hashCode => Object.hash(WindowsMidiShimEventsDropped, count);

  @override
  String toString() => 'WindowsMidiShimEventsDropped($count)';
}

// #############################################################################
/// An event of a kind this version does not know, e.g. from a newer shim.
final class WindowsMidiShimUnknownEvent extends WindowsMidiShimEvent {
  /// Creates the event of [kind] from a copy of [payload].
  WindowsMidiShimUnknownEvent({required this.kind, required List<int> payload})
    : payload = Uint8List.fromList(payload).asUnmodifiableView();

  // ...........................................................................
  /// The kind of the event.
  final int kind;

  /// The payload; cannot be modified.
  final Uint8List payload;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is WindowsMidiShimUnknownEvent &&
      other.kind == kind &&
      other.payload.equals(payload);

  @override
  int get hashCode =>
      Object.hash(WindowsMidiShimUnknownEvent, kind, Object.hashAll(payload));

  @override
  String toString() =>
      'WindowsMidiShimUnknownEvent(kind: $kind, payload: $payload)';
}
