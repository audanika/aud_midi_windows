// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// A group terminal block of a USB MIDI 2.0 device, as Windows MIDI Services
/// reports it (USB MIDI 2.0 class specification, MidiGroupTerminalBlock).
///
/// Devices that declare no function blocks describe their groups this way.
final class WindowsMidiGroupTerminalBlock {
  /// Creates the description of the group terminal block [number].
  ///
  /// - [direction] [directionBidirectional], [directionInput] (the block
  ///   receives) or [directionOutput] (the block sends).
  /// - [protocol] the MidiGroupTerminalBlockProtocol value, e.g. 0x11 for
  ///   MIDI 2.0.
  const WindowsMidiGroupTerminalBlock({
    required this.number,
    this.name = '',
    this.direction = directionBidirectional,
    this.protocol = 0,
    required this.firstGroup,
    required this.groupCount,
  });

  // ...........................................................................
  /// The number of the block.
  final int number;

  /// The name of the block, empty when unknown.
  final String name;

  /// The direction of the block, seen from the device.
  final int direction;

  /// The protocol of the block.
  final int protocol;

  /// The first group of the block, 0 to 15.
  final int firstGroup;

  /// The number of groups of the block.
  final int groupCount;

  // ...........................................................................
  /// The block receives and sends.
  static const int directionBidirectional = 0;

  /// The block receives messages: the app sends to it.
  static const int directionInput = 1;

  /// The block sends messages: the app receives from it.
  static const int directionOutput = 2;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowsMidiGroupTerminalBlock &&
          other.number == number &&
          other.name == name &&
          other.direction == direction &&
          other.protocol == protocol &&
          other.firstGroup == firstGroup &&
          other.groupCount == groupCount;

  @override
  int get hashCode =>
      Object.hash(number, name, direction, protocol, firstGroup, groupCount);

  @override
  String toString() =>
      "WindowsMidiGroupTerminalBlock(number: $number, name: '$name', "
      'direction: $direction, protocol: $protocol, '
      'firstGroup: $firstGroup, groupCount: $groupCount)';
}
