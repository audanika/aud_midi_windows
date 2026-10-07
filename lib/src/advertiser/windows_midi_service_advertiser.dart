// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';

import 'package:aud_midi_core/aud_midi_core.dart';

import '../shim/windows_midi_status.dart';
import 'windows_dns_sd_api.dart';
import 'windows_dns_sd_ffi_api.dart';
import 'windows_midi_service_registration.dart';

// #############################################################################
/// Advertises network MIDI sessions through the DNS-SD registrar of Windows
/// (`DnsServiceRegister`), e.g. the `_apple-midi._udp` sessions of
/// `aud_midi_network`.
///
/// The registrar answers mDNS queries for the registered services until
/// they are unregistered or the process ends.
final class WindowsMidiServiceAdvertiser implements MidiServiceAdvertiser {
  /// Creates an advertiser.
  ///
  /// - [api] the registrar; the dnsapi.dll binding by default.
  /// - [hostName] the name of this computer; `Platform.localHostname` by
  ///   default. The services point to `<hostName>.local`.
  /// - [timeout] the time to wait for the registrar.
  WindowsMidiServiceAdvertiser({
    WindowsDnsSdApi? api,
    String? hostName,
    this.timeout = const Duration(seconds: 10),
  }) : _api = api ?? WindowsDnsSdFfiApi(),
       _hostName = (hostName ?? Platform.localHostname).split('.').first {
    _api.listen(_completed);
  }

  // ...........................................................................
  @override
  Future<MidiServiceRegistration> register({
    required String name,
    required String type,
    required int port,
    Map<String, String> txt = const {},
  }) async {
    if (_closed) throw StateError('The advertiser is closed');
    if (name.isEmpty) throw ArgumentError.value(name, 'name', 'Is empty');
    if (!_type.hasMatch(type)) {
      throw ArgumentError.value(type, 'type', 'Is no type like _x._udp');
    }
    if (port < 1 || port > 0xFFFF) {
      throw ArgumentError.value(port, 'port', 'Is no port');
    }
    final id = _nextId++;
    final result = await _run(
      id,
      api: 'DnsServiceRegister',
      registering: true,
      call: () => _api.register(
        id: id,
        instanceName: '$name.$type.local',
        hostName: '$_hostName.local',
        port: port,
        txt: txt,
      ),
    );
    if (result.status != 0) {
      _api.release(id);
      throw MidiNativeError(api: 'DnsServiceRegister', code: result.status);
    }
    final registration = WindowsMidiServiceRegistration(
      name: shortName(result.instanceName, type: type) ?? name,
      onUnregister: () => _unregister(id),
    );
    _registrations[id] = registration;
    return registration;
  }

  /// Withdraws every registration, then stops listening to the registrar.
  ///
  /// A registrar that did not answer in time keeps its callback open, so
  /// that a late answer finds it.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final registration in [..._registrations.values]) {
      try {
        await registration.unregister();
      } on MidiException {
        // The registration ends with the process anyway.
      }
    }
    if (_pending.isEmpty && _abandoned.isEmpty) _api.close();
  }

  // ...........................................................................
  /// The time to wait for the registrar.
  final Duration timeout;

  // ...........................................................................
  /// Returns the service name of the registered [instanceName], e.g.
  /// `Studio (2)` for `Studio (2)._apple-midi._udp.local`, or null when
  /// [instanceName] is unknown.
  static String? shortName(String? instanceName, {required String type}) {
    if (instanceName == null || instanceName.isEmpty) return null;
    final name = instanceName.endsWith('.')
        ? instanceName.substring(0, instanceName.length - 1)
        : instanceName;
    final suffix = '.$type.local';
    return name.endsWith(suffix)
        ? name.substring(0, name.length - suffix.length)
        : name;
  }

  // ...........................................................................
  static final RegExp _type = RegExp(r'^_[A-Za-z0-9-]+\._(udp|tcp)$');

  Future<({int status, String? instanceName})> _run(
    int id, {
    required String api,
    required bool registering,
    required int Function() call,
  }) async {
    final completer = Completer<({int status, String? instanceName})>();
    _pending[id] = completer;
    final status = call();
    if (status != WindowsDnsSdApi.requestPending) {
      _pending.remove(id);
      _api.release(id);
      throw MidiNativeError(api: api, code: status);
    }
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      _abandoned[id] = registering;
      throw MidiNativeError(api: api, code: WindowsMidiStatus.timeout);
    }
  }

  Future<void> _unregister(int id) async {
    if (_registrations.remove(id) == null) return;
    final result = await _run(
      id,
      api: 'DnsServiceDeRegister',
      registering: false,
      call: () => _api.deregister(id),
    );
    _api.release(id);
    if (result.status != 0) {
      throw MidiNativeError(api: 'DnsServiceDeRegister', code: result.status);
    }
  }

  void _completed(int id, int status, String? instanceName) {
    final completer = _pending.remove(id);
    if (completer != null) {
      completer.complete((status: status, instanceName: instanceName));
      return;
    }
    // A late answer to a request that timed out: withdraw a registration
    // nobody holds, then free the memory.
    final registering = _abandoned.remove(id);
    if (registering == null) return;
    if (registering &&
        status == 0 &&
        _api.deregister(id) == WindowsDnsSdApi.requestPending) {
      _abandoned[id] = false;
      return;
    }
    _api.release(id);
  }

  final WindowsDnsSdApi _api;
  final String _hostName;
  final Map<int, Completer<({int status, String? instanceName})>> _pending = {};
  final Map<int, bool> _abandoned = {};
  final Map<int, WindowsMidiServiceRegistration> _registrations = {};
  int _nextId = 1;
  bool _closed = false;
}
