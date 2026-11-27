#include "LoginKeychain.h"

// PulseBar's existing tokens are in the file-based login keychain. Its ACL
// dialogs use the legacy interaction setting, rather than an LAContext.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus PBWithoutKeychainUI(OSStatus (^operation)(void)) {
    Boolean allowed;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&allowed);
    if (status != errSecSuccess) return status;
    if (!allowed) return operation();

    status = SecKeychainSetUserInteractionAllowed(false);
    if (status != errSecSuccess) return status;
    OSStatus result = operation();
    status = SecKeychainSetUserInteractionAllowed(allowed);
    return status == errSecSuccess ? result : status;
}
#pragma clang diagnostic pop
