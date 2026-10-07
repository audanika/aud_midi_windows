// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// A stand-in for combaseapi.h declarations (Windows SDK), for the compile
// check of tool/test_native_core.sh on non-Windows hosts.

#pragma once

#include "windows.h"

typedef enum _APTTYPE {
  APTTYPE_CURRENT = -1,
  APTTYPE_STA = 0,
  APTTYPE_MTA = 1,
  APTTYPE_NA = 2,
  APTTYPE_MAINSTA = 3
} APTTYPE;

typedef enum _APTTYPEQUALIFIER {
  APTTYPEQUALIFIER_NONE = 0,
  APTTYPEQUALIFIER_IMPLICIT_MTA = 1,
  APTTYPEQUALIFIER_NA_ON_MTA = 2,
  APTTYPEQUALIFIER_NA_ON_STA = 3,
  APTTYPEQUALIFIER_NA_ON_IMPLICIT_MTA = 4,
  APTTYPEQUALIFIER_NA_ON_MAINSTA = 5,
  APTTYPEQUALIFIER_APPLICATION_STA = 6,
  APTTYPEQUALIFIER_RESERVED_1 = 7
} APTTYPEQUALIFIER;

HRESULT CoGetApartmentType(APTTYPE* pAptType, APTTYPEQUALIFIER* pAptQualifier);

struct CO_MTA_USAGE_COOKIE__ {
  int unused;
};
typedef struct CO_MTA_USAGE_COOKIE__* CO_MTA_USAGE_COOKIE;

HRESULT CoIncrementMTAUsage(CO_MTA_USAGE_COOKIE* pCookie);
