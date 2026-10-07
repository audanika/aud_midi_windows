// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// Compares lists element by element, for the value equality of the records
/// of this package.
extension WindowsMidiListEquality<T> on List<T> {
  // ...........................................................................
  /// Whether [other] has the same length and equal elements in the same
  /// order.
  bool equals(List<T> other) {
    if (identical(this, other)) return true;
    if (length != other.length) return false;
    for (var i = 0; i < length; i++) {
      if (this[i] != other[i]) return false;
    }
    return true;
  }
}
