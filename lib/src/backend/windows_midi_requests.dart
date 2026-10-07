// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import '../shim/windows_midi_shim_event.dart';

// #############################################################################
/// Pairs the asynchronous requests to the shim with their completions.
///
/// Every request gets a new id; the shim hands it back in the completion
/// event, which [complete] routes to the waiting caller.
final class WindowsMidiRequests {
  /// Creates the registry.
  WindowsMidiRequests();

  // ...........................................................................
  /// Starts a request: [send] passes a new request id to the shim, and the
  /// returned future completes with the completion that carries the id.
  ///
  /// - [timeout] the time after which the future fails with the error
  ///   [onTimeout] returns.
  /// - [onLate] receives a completion that arrives after the timeout, e.g.
  ///   to close a port that opened too late.
  Future<T> run<T extends WindowsMidiShimCompletion>({
    required void Function(int request) send,
    required Duration timeout,
    required Object Function() onTimeout,
    void Function(T completion)? onLate,
  }) async {
    final request = _next++;
    final completer = Completer<WindowsMidiShimCompletion>();
    _pending[request] = completer;
    try {
      send(request);
    } catch (_) {
      _pending.remove(request);
      rethrow;
    }
    final timer = Timer(timeout, () {
      if (_pending.remove(request) == null) return;
      if (onLate != null) _late[request] = (late) => onLate(late as T);
      completer.completeError(onTimeout());
    });
    try {
      return await completer.future as T;
    } finally {
      timer.cancel();
    }
  }

  /// Hands [completion] to the request that waits for it; returns false when
  /// none waits.
  bool complete(WindowsMidiShimCompletion completion) {
    final completer = _pending.remove(completion.request);
    if (completer != null) {
      completer.complete(completion);
      return true;
    }
    _late.remove(completion.request)?.call(completion);
    return false;
  }

  /// Fails every waiting request with [error] and forgets the late ones.
  void failAll(Object error) {
    final pending = [..._pending.values];
    _pending.clear();
    _late.clear();
    for (final completer in pending) {
      completer.completeError(error);
    }
  }

  // ...........................................................................
  /// The number of requests that wait.
  int get waiting => _pending.length;

  // ...........................................................................
  int _next = 1;
  final Map<int, Completer<WindowsMidiShimCompletion>> _pending = {};
  final Map<int, void Function(WindowsMidiShimCompletion)> _late = {};
}
