// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// A stand-in for the few Win32 declarations of src/aud_midi_windows.cpp,
// for the compile check of tool/test_native_core.sh on non-Windows hosts.

#pragma once

#include <cstdint>

typedef int32_t HRESULT;
typedef int BOOL;
typedef unsigned char byte;
typedef long long LONGLONG;

typedef union _LARGE_INTEGER {
  struct {
    uint32_t LowPart;
    int32_t HighPart;
  } u;
  LONGLONG QuadPart;
} LARGE_INTEGER;

BOOL QueryPerformanceCounter(LARGE_INTEGER* value);
BOOL QueryPerformanceFrequency(LARGE_INTEGER* value);

#define FAILED(hr) (((HRESULT)(hr)) < 0)
#define SUCCEEDED(hr) (((HRESULT)(hr)) >= 0)
