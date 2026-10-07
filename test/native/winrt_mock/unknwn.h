// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// A stand-in for unknwn.h, for the compile check of
// tool/test_native_core.sh on non-Windows hosts.

#pragma once

#include "windows.h"

struct IUnknown {
  virtual HRESULT QueryInterface(const void* riid, void** ppvObject) = 0;
  virtual unsigned long AddRef() = 0;
  virtual unsigned long Release() = 0;
};
