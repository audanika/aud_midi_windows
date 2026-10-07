// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// A stand-in for robuffer.h (Windows SDK), for the compile check of
// tool/test_native_core.sh on non-Windows hosts.

#pragma once

#include "unknwn.h"

namespace Windows {
namespace Storage {
namespace Streams {
struct IBufferByteAccess : IUnknown {
  virtual HRESULT Buffer(byte** value) = 0;
};
}  // namespace Streams
}  // namespace Storage
}  // namespace Windows
