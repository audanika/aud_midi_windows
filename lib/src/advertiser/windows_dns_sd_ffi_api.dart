// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// coverage:ignore-file
// Reason: calls dnsapi.dll, which exists on Windows only; covered by the
// @TestOn('windows') tests in test/windows.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'windows_dns_sd_api.dart';

// #############################################################################
/// The [WindowsDnsSdApi] of dnsapi.dll, bound through `package:win32`.
///
/// Every registration owns its native request, instance and strings until
/// [release]. The completion callback is a `NativeCallable.listener`, so it
/// runs later in this isolate; the instance Windows hands to it stays valid
/// until `DnsServiceFreeInstance`.
final class WindowsDnsSdFfiApi implements WindowsDnsSdApi {
  /// Creates the binding; nothing native happens before [listen].
  WindowsDnsSdFfiApi();

  // ...........................................................................
  @override
  void listen(
    void Function(int id, int status, String? instanceName) onCompleted,
  ) {
    _onCompleted = onCompleted;
    _callable ??= NativeCallable<PDNS_SERVICE_REGISTER_COMPLETE>.listener(
      _complete,
    );
  }

  @override
  void close() {
    _callable?.close();
    _callable = null;
    _onCompleted = null;
  }

  // ...........................................................................
  @override
  int register({
    required int id,
    required String instanceName,
    required String hostName,
    required int port,
    required Map<String, String> txt,
  }) {
    // An empty TXT record needs one empty entry: Windows then sends one
    // empty string, as RFC 6763 6.1 demands.
    final count = txt.isEmpty ? 1 : txt.length;
    final keys = calloc<Pointer<Utf16>>(count);
    final values = calloc<Pointer<Utf16>>(count);
    var index = 0;
    for (final MapEntry(:key, :value) in txt.entries) {
      keys[index] = key.toNativeUtf16();
      values[index] = value.toNativeUtf16();
      index++;
    }
    final instance = calloc<DNS_SERVICE_INSTANCE>();
    instance.ref
      ..pszInstanceName = PWSTR(instanceName.toNativeUtf16())
      ..pszHostName = PWSTR(hostName.toNativeUtf16())
      ..wPort = port
      ..dwPropertyCount = count
      ..keys = keys
      ..values = values;
    final memory = _Memory(instance: instance, count: count)
      ..register = _request(id, instance);
    _memory[id] = memory;
    return DnsServiceRegister(memory.register, null).value;
  }

  @override
  int deregister(int id) {
    final memory = _memory[id]!;
    memory.deregistering = true;
    final instance = memory.registered == nullptr
        ? memory.instance
        : memory.registered;
    memory.deregister = _request(id, instance);
    return DnsServiceDeRegister(memory.deregister, null).value;
  }

  @override
  void release(int id) {
    final memory = _memory.remove(id);
    if (memory == null) return;
    final instance = memory.instance.ref;
    for (var i = 0; i < memory.count; i++) {
      if (instance.keys[i] != nullptr) calloc.free(instance.keys[i]);
      if (instance.values[i] != nullptr) calloc.free(instance.values[i]);
    }
    calloc
      ..free(instance.keys)
      ..free(instance.values)
      ..free(instance.pszInstanceName)
      ..free(instance.pszHostName)
      ..free(memory.instance);
    if (memory.registered != nullptr) _freeInstance(memory.registered);
    if (memory.register != nullptr) calloc.free(memory.register);
    if (memory.deregister != nullptr) calloc.free(memory.deregister);
  }

  // ...........................................................................
  // DNS_QUERY_REQUEST_VERSION1 of windns.h.
  static const int _requestVersion1 = 1;

  static final void Function(Pointer<DNS_SERVICE_INSTANCE>) _freeInstance =
      DynamicLibrary.open('dnsapi.dll').lookupFunction<
        Void Function(Pointer<DNS_SERVICE_INSTANCE>),
        void Function(Pointer<DNS_SERVICE_INSTANCE>)
      >('DnsServiceFreeInstance');

  Pointer<DNS_SERVICE_REGISTER_REQUEST> _request(
    int id,
    Pointer<DNS_SERVICE_INSTANCE> instance,
  ) {
    final request = calloc<DNS_SERVICE_REGISTER_REQUEST>();
    request.ref
      ..Version = _requestVersion1
      ..InterfaceIndex = 0
      ..pServiceInstance = instance
      ..pRegisterCompletionCallback = _callable!.nativeFunction
      ..pQueryContext = Pointer.fromAddress(id)
      ..unicastEnabled = false;
    return request;
  }

  void _complete(
    int status,
    Pointer<NativeType> context,
    Pointer<DNS_SERVICE_INSTANCE> instance,
  ) {
    final id = context.address;
    final name = instance == nullptr
        ? null
        : instance.ref.pszInstanceName.toDartString();
    final memory = _memory[id];
    if (memory == null || memory.deregistering) {
      if (instance != nullptr &&
          (memory == null || instance != memory.registered)) {
        _freeInstance(instance);
      }
    } else {
      if (memory.registered != nullptr) _freeInstance(memory.registered);
      memory.registered = instance;
    }
    _onCompleted?.call(id, status, name);
  }

  NativeCallable<PDNS_SERVICE_REGISTER_COMPLETE>? _callable;
  void Function(int id, int status, String? instanceName)? _onCompleted;
  final Map<int, _Memory> _memory = {};
}

// #############################################################################
/// The native memory of one registration.
final class _Memory {
  _Memory({required this.instance, required this.count});

  final Pointer<DNS_SERVICE_INSTANCE> instance;
  final int count;
  Pointer<DNS_SERVICE_REGISTER_REQUEST> register = nullptr;
  Pointer<DNS_SERVICE_REGISTER_REQUEST> deregister = nullptr;
  Pointer<DNS_SERVICE_INSTANCE> registered = nullptr;
  bool deregistering = false;
}
