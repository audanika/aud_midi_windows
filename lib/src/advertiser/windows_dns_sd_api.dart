// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// The DNS-SD registrar of Windows (`DnsServiceRegister` and
/// `DnsServiceDeRegister` in dnsapi.dll, Windows 10 1903+), as the
/// `WindowsMidiServiceAdvertiser` uses it.
///
/// Both calls are asynchronous: they return [requestPending] and report the
/// result through the callback given to [listen].
abstract interface class WindowsDnsSdApi {
  // ...........................................................................
  /// Sets [onCompleted], which receives the id, the Win32 status and the
  /// registered instance name (null when unknown) of every completed
  /// registration and deregistration.
  void listen(
    void Function(int id, int status, String? instanceName) onCompleted,
  );

  /// Stops reporting completions; call it only when none is pending.
  void close();

  // ...........................................................................
  /// Starts the registration [id] of the service instance [instanceName],
  /// e.g. `Studio._apple-midi._udp.local`, of the host [hostName], e.g.
  /// `pc.local`, on [port] with the TXT entries [txt]; returns the status of
  /// the call.
  int register({
    required int id,
    required String instanceName,
    required String hostName,
    required int port,
    required Map<String, String> txt,
  });

  /// Starts to withdraw the registration [id]; returns the status of the
  /// call.
  int deregister(int id);

  /// Frees the native memory of the registration [id].
  void release(int id);

  // ...........................................................................
  /// The status of a call whose result follows (DNS_REQUEST_PENDING).
  static const int requestPending = 9506;
}
