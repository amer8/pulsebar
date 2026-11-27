#pragma once

#include <Security/Security.h>

OSStatus PBWithoutKeychainUI(OSStatus (^ _Nonnull operation)(void) __attribute__((noescape)));
