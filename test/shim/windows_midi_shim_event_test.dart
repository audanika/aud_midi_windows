// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:test/test.dart';

void main() {
  const port = WindowsMidiPortRecord(source: 1, id: 'a', name: 'A');
  const other = WindowsMidiPortRecord(source: 1, id: 'b', name: 'B');

  // Checks that [event] equals [same] and differs from every [variants],
  // and that it prints as [text].
  void checkEvent(
    WindowsMidiShimEvent event,
    WindowsMidiShimEvent same,
    List<WindowsMidiShimEvent> variants,
    String text,
  ) {
    expect(event, same);
    expect(event.hashCode, same.hashCode);
    for (final variant in variants) {
      expect(event == variant, isFalse, reason: '$variant');
    }
    expect(event.toString(), text);
  }

  group('WindowsMidiShimEvent', () {
    group('WindowsMidiShimPortAdded', () {
      test('compares and prints its port', () {
        checkEvent(
          const WindowsMidiShimPortAdded(port),
          const WindowsMidiShimPortAdded(port),
          const [
            WindowsMidiShimPortAdded(other),
            WindowsMidiShimPortUpdated(port),
          ],
          'WindowsMidiShimPortAdded($port)',
        );
      });
    });

    group('WindowsMidiShimPortUpdated', () {
      test('compares and prints its port', () {
        checkEvent(
          const WindowsMidiShimPortUpdated(port),
          const WindowsMidiShimPortUpdated(port),
          const [
            WindowsMidiShimPortUpdated(other),
            WindowsMidiShimPortAdded(port),
          ],
          'WindowsMidiShimPortUpdated($port)',
        );
      });
    });

    group('WindowsMidiShimPortRemoved', () {
      test('compares and prints source and id', () {
        checkEvent(
          const WindowsMidiShimPortRemoved(source: 1, id: 'a'),
          const WindowsMidiShimPortRemoved(source: 1, id: 'a'),
          const [
            WindowsMidiShimPortRemoved(source: 2, id: 'a'),
            WindowsMidiShimPortRemoved(source: 1, id: 'b'),
          ],
          "WindowsMidiShimPortRemoved(source: 1, id: 'a')",
        );
      });
    });

    group('WindowsMidiShimEnumerationCompleted', () {
      test('compares and prints its source', () {
        checkEvent(
          const WindowsMidiShimEnumerationCompleted(1),
          const WindowsMidiShimEnumerationCompleted(1),
          const [WindowsMidiShimEnumerationCompleted(2)],
          'WindowsMidiShimEnumerationCompleted(1)',
        );
      });
    });

    group('WindowsMidiShimWatcherStopped', () {
      test('compares and prints source and status', () {
        checkEvent(
          const WindowsMidiShimWatcherStopped(source: 1, status: 4),
          const WindowsMidiShimWatcherStopped(source: 1, status: 4),
          const [
            WindowsMidiShimWatcherStopped(source: 2, status: 4),
            WindowsMidiShimWatcherStopped(source: 1, status: 5),
          ],
          'WindowsMidiShimWatcherStopped(source: 1, status: 4)',
        );
      });

      test('isAborted is true for the aborted status', () {
        expect([
          for (final status in [4, WindowsMidiShimWatcherStopped.statusAborted])
            WindowsMidiShimWatcherStopped(source: 1, status: status).isAborted,
        ], equals([false, true]));
      });
    });

    group('WindowsMidiShimOpenCompleted', () {
      test('compares and prints its fields', () {
        checkEvent(
          const WindowsMidiShimOpenCompleted(
            request: 1,
            status: 0,
            handle: 2,
            message: 'm',
          ),
          const WindowsMidiShimOpenCompleted(
            request: 1,
            status: 0,
            handle: 2,
            message: 'm',
          ),
          const [
            WindowsMidiShimOpenCompleted(
              request: 9,
              status: 0,
              handle: 2,
              message: 'm',
            ),
            WindowsMidiShimOpenCompleted(
              request: 1,
              status: -1,
              handle: 2,
              message: 'm',
            ),
            WindowsMidiShimOpenCompleted(request: 1, status: 0, message: 'm'),
            WindowsMidiShimOpenCompleted(request: 1, status: 0, handle: 2),
          ],
          'WindowsMidiShimOpenCompleted(request: 1, status: 0, handle: 2, '
          "message: 'm')",
        );
      });

      test('isSuccess is true for a status of 0 or more', () {
        expect([
          for (final status in [-1, 0, 1])
            WindowsMidiShimOpenCompleted(request: 1, status: status).isSuccess,
        ], equals([false, true, true]));
      });
    });

    group('WindowsMidiShimPortDisconnected', () {
      test('compares and prints its handle', () {
        checkEvent(
          const WindowsMidiShimPortDisconnected(3),
          const WindowsMidiShimPortDisconnected(3),
          const [WindowsMidiShimPortDisconnected(4)],
          'WindowsMidiShimPortDisconnected(3)',
        );
      });
    });

    group('WindowsMidiShimBleAdvertisement', () {
      test('compares and prints its fields', () {
        checkEvent(
          const WindowsMidiShimBleAdvertisement(
            address: 1,
            rssi: -60,
            flags: 1,
            name: 'n',
          ),
          const WindowsMidiShimBleAdvertisement(
            address: 1,
            rssi: -60,
            flags: 1,
            name: 'n',
          ),
          const [
            WindowsMidiShimBleAdvertisement(
              address: 2,
              rssi: -60,
              flags: 1,
              name: 'n',
            ),
            WindowsMidiShimBleAdvertisement(
              address: 1,
              rssi: -61,
              flags: 1,
              name: 'n',
            ),
            WindowsMidiShimBleAdvertisement(address: 1, rssi: -60, name: 'n'),
            WindowsMidiShimBleAdvertisement(address: 1, rssi: -60, flags: 1),
          ],
          'WindowsMidiShimBleAdvertisement(address: 1, rssi: -60, flags: 1, '
          "name: 'n')",
        );
      });
    });

    group('WindowsMidiShimBleScanStopped', () {
      test('compares and prints its error', () {
        checkEvent(
          const WindowsMidiShimBleScanStopped(1),
          const WindowsMidiShimBleScanStopped(1),
          const [WindowsMidiShimBleScanStopped(2)],
          'WindowsMidiShimBleScanStopped(1)',
        );
      });
    });

    group('WindowsMidiShimBlePairCompleted', () {
      test('compares and prints its fields', () {
        checkEvent(
          const WindowsMidiShimBlePairCompleted(
            request: 1,
            status: 0,
            result: 3,
            message: 'm',
          ),
          const WindowsMidiShimBlePairCompleted(
            request: 1,
            status: 0,
            result: 3,
            message: 'm',
          ),
          const [
            WindowsMidiShimBlePairCompleted(
              request: 2,
              status: 0,
              result: 3,
              message: 'm',
            ),
            WindowsMidiShimBlePairCompleted(
              request: 1,
              status: -1,
              result: 3,
              message: 'm',
            ),
            WindowsMidiShimBlePairCompleted(
              request: 1,
              status: 0,
              result: 0,
              message: 'm',
            ),
            WindowsMidiShimBlePairCompleted(request: 1, status: 0, result: 3),
          ],
          'WindowsMidiShimBlePairCompleted(request: 1, status: 0, result: 3, '
          "message: 'm')",
        );
      });

      test('isPaired is true for paired and already paired', () {
        expect([
          for (final result in [
            WindowsMidiShimBlePairCompleted.paired,
            WindowsMidiShimBlePairCompleted.alreadyPaired,
            WindowsMidiShimBlePairCompleted.accessDenied,
          ])
            WindowsMidiShimBlePairCompleted(
              request: 1,
              status: 0,
              result: result,
            ).isPaired,
        ], equals([true, true, false]));
      });
    });

    group('WindowsMidiShimBleUnpairCompleted', () {
      test('compares and prints its fields', () {
        checkEvent(
          const WindowsMidiShimBleUnpairCompleted(
            request: 1,
            status: 0,
            result: 1,
            message: 'm',
          ),
          const WindowsMidiShimBleUnpairCompleted(
            request: 1,
            status: 0,
            result: 1,
            message: 'm',
          ),
          const [
            WindowsMidiShimBleUnpairCompleted(
              request: 2,
              status: 0,
              result: 1,
              message: 'm',
            ),
            WindowsMidiShimBleUnpairCompleted(
              request: 1,
              status: -1,
              result: 1,
              message: 'm',
            ),
            WindowsMidiShimBleUnpairCompleted(
              request: 1,
              status: 0,
              result: 0,
              message: 'm',
            ),
            WindowsMidiShimBleUnpairCompleted(request: 1, status: 0, result: 1),
          ],
          'WindowsMidiShimBleUnpairCompleted(request: 1, status: 0, '
          "result: 1, message: 'm')",
        );
      });

      test('isUnpaired is true for unpaired and already unpaired', () {
        expect([
          for (final result in [
            WindowsMidiShimBleUnpairCompleted.unpaired,
            WindowsMidiShimBleUnpairCompleted.alreadyUnpaired,
            WindowsMidiShimBleUnpairCompleted.accessDenied,
          ])
            WindowsMidiShimBleUnpairCompleted(
              request: 1,
              status: 0,
              result: result,
            ).isUnpaired,
        ], equals([true, true, false]));
      });
    });

    group('WindowsMidiShimVirtualCreated', () {
      test('compares and prints its fields', () {
        checkEvent(
          const WindowsMidiShimVirtualCreated(
            request: 1,
            status: 0,
            handle: 2,
            endpointId: 'e',
            message: 'm',
          ),
          const WindowsMidiShimVirtualCreated(
            request: 1,
            status: 0,
            handle: 2,
            endpointId: 'e',
            message: 'm',
          ),
          const [
            WindowsMidiShimVirtualCreated(
              request: 2,
              status: 0,
              handle: 2,
              endpointId: 'e',
              message: 'm',
            ),
            WindowsMidiShimVirtualCreated(
              request: 1,
              status: -1,
              handle: 2,
              endpointId: 'e',
              message: 'm',
            ),
            WindowsMidiShimVirtualCreated(
              request: 1,
              status: 0,
              endpointId: 'e',
              message: 'm',
            ),
            WindowsMidiShimVirtualCreated(
              request: 1,
              status: 0,
              handle: 2,
              message: 'm',
            ),
            WindowsMidiShimVirtualCreated(
              request: 1,
              status: 0,
              handle: 2,
              endpointId: 'e',
            ),
          ],
          'WindowsMidiShimVirtualCreated(request: 1, status: 0, handle: 2, '
          "endpointId: 'e', message: 'm')",
        );
      });
    });

    group('WindowsMidiShimError', () {
      test('compares and prints its fields', () {
        checkEvent(
          const WindowsMidiShimError(
            status: -1,
            source: 1,
            api: 'a',
            message: 'm',
          ),
          const WindowsMidiShimError(
            status: -1,
            source: 1,
            api: 'a',
            message: 'm',
          ),
          const [
            WindowsMidiShimError(status: -2, source: 1, api: 'a', message: 'm'),
            WindowsMidiShimError(status: -1, api: 'a', message: 'm'),
            WindowsMidiShimError(status: -1, source: 1, api: 'b', message: 'm'),
            WindowsMidiShimError(status: -1, source: 1, api: 'a'),
          ],
          "WindowsMidiShimError(status: -1, source: 1, api: 'a', message: 'm')",
        );
      });
    });

    group('WindowsMidiShimEventsDropped', () {
      test('compares and prints its count', () {
        checkEvent(
          const WindowsMidiShimEventsDropped(3),
          const WindowsMidiShimEventsDropped(3),
          const [WindowsMidiShimEventsDropped(4)],
          'WindowsMidiShimEventsDropped(3)',
        );
      });
    });

    group('WindowsMidiShimUnknownEvent', () {
      test('compares and prints kind and payload', () {
        checkEvent(
          WindowsMidiShimUnknownEvent(kind: 99, payload: [1]),
          WindowsMidiShimUnknownEvent(kind: 99, payload: [1]),
          [
            WindowsMidiShimUnknownEvent(kind: 98, payload: [1]),
            WindowsMidiShimUnknownEvent(kind: 99, payload: [2]),
          ],
          'WindowsMidiShimUnknownEvent(kind: 99, payload: [1])',
        );
      });

      test('copies the payload and keeps it unmodifiable', () {
        final payload = [1, 2];
        final event = WindowsMidiShimUnknownEvent(kind: 1, payload: payload);
        payload[0] = 9;
        expect(event.payload, equals([1, 2]));
        expect(() => event.payload[0] = 3, throwsUnsupportedError);
      });
    });
  });
}
