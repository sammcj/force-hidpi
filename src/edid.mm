// edid.mm - EDID parsing and retrieval from IOKit display services
#import "edid.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>

bool parseEDIDVendorProduct(const uint8_t *edid, size_t len,
                            uint32_t *vendor, uint32_t *product) {
    if (!edid || len < 12 || !vendor || !product) return false;

    // Bytes 8-9: manufacturer ID (big-endian compressed PNP)
    *vendor = ((uint32_t)edid[8] << 8) | edid[9];

    // Bytes 10-11: product code (little-endian)
    *product = ((uint32_t)edid[11] << 8) | edid[10];

    return true;
}

bool parseEDIDNativeResolution(const uint8_t *edid, size_t len,
                               uint32_t *width, uint32_t *height) {
    if (!edid || len < 68 || !width || !height) return false;

    // Preferred timing descriptor is at offset 54
    // Byte 56: lower 8 bits of horizontal active pixels
    // Byte 58 high nibble: upper 4 bits of horizontal active pixels
    uint32_t hActive = edid[56] | ((uint32_t)(edid[58] >> 4) << 8);

    // Byte 59: lower 8 bits of vertical active lines
    // Byte 61 high nibble: upper 4 bits of vertical active lines
    uint32_t vActive = edid[59] | ((uint32_t)(edid[61] >> 4) << 8);

    if (hActive == 0 || vActive == 0) return false;

    *width = hActive;
    *height = vActive;
    return true;
}

bool parseEDIDProductName(const uint8_t *edid, size_t len,
                          char *name, size_t nameLen) {
    if (!edid || len < 128 || !name || nameLen == 0) return false;

    // Scan descriptor blocks at offsets 54, 72, 90, 108
    // Tag 0xFC = monitor name
    const int offsets[] = {54, 72, 90, 108};
    for (int i = 0; i < 4; i++) {
        int off = offsets[i];
        if ((size_t)(off + 18) > len) continue;

        // Data descriptors have bytes 0-1 = 0x0000, byte 3 = tag
        if (edid[off] != 0 || edid[off + 1] != 0) continue;
        if (edid[off + 3] != 0xFC) continue;

        // Name is in bytes 5-17 of the descriptor, padded with 0x0A
        size_t copied = 0;
        for (int j = 5; j < 18 && copied < nameLen - 1; j++) {
            uint8_t ch = edid[off + j];
            if (ch == 0x0A || ch == 0x00) break;
            name[copied++] = (char)ch;
        }
        name[copied] = '\0';
        return copied > 0;
    }

    return false;
}

// Try to get EDID via IOService port matching the display ID
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSData *getEDIDFromIOService(CGDirectDisplayID displayID) {
    io_service_t service = CGDisplayIOServicePort(displayID);
    if (service == MACH_PORT_NULL) return nil;

    CFDataRef edidData = (CFDataRef)IORegistryEntryCreateCFProperty(
        service, CFSTR("IODisplayEDID"), kCFAllocatorDefault, 0
    );
    if (edidData) {
        NSData *result = [NSData dataWithData:(__bridge NSData *)edidData];
        CFRelease(edidData);
        return result;
    }
    return nil;
}
#pragma clang diagnostic pop

// Search DCPAVServiceProxy services for EDID property
static NSData *getEDIDFromDCPAV(CGDirectDisplayID displayID) {
    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("DCPAVServiceProxy"),
        &iter
    );
    if (kr != KERN_SUCCESS || !iter) return nil;

    NSData *result = nil;
    io_service_t service;
    while ((service = IOIteratorNext(iter)) != 0) {
        CFDataRef edidData = (CFDataRef)IORegistryEntryCreateCFProperty(
            service, CFSTR("EDID"), kCFAllocatorDefault, 0
        );
        if (edidData) {
            result = [NSData dataWithData:(__bridge NSData *)edidData];
            CFRelease(edidData);
            IOObjectRelease(service);
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    return result;
}

// Recursively search a service and its children for Metadata containing
// an EDID that matches the given vendor/product IDs
static NSData *searchMetadataForEDID(io_service_t service, uint32_t vendorID,
                                     uint32_t productID) {
    // Check this node
    CFTypeRef metadata = IORegistryEntryCreateCFProperty(
        service, CFSTR("Metadata"), kCFAllocatorDefault, 0);
    if (metadata && CFGetTypeID(metadata) == CFDictionaryGetTypeID()) {
        CFDataRef edidData = (CFDataRef)CFDictionaryGetValue(
            (CFDictionaryRef)metadata, CFSTR("EDID"));
        if (edidData && CFGetTypeID(edidData) == CFDataGetTypeID()) {
            const uint8_t *bytes = CFDataGetBytePtr(edidData);
            size_t len = (size_t)CFDataGetLength(edidData);
            uint32_t edidVendor = 0, edidProduct = 0;
            if (parseEDIDVendorProduct(bytes, len, &edidVendor, &edidProduct)) {
                if (edidVendor == vendorID && edidProduct == productID) {
                    NSData *result = [NSData dataWithData:(__bridge NSData *)edidData];
                    CFRelease(metadata);
                    return result;
                }
            }
        }
    }
    if (metadata) CFRelease(metadata);

    // Search children
    io_iterator_t children = 0;
    if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS) {
        io_service_t child;
        while ((child = IOIteratorNext(children)) != 0) {
            NSData *result = searchMetadataForEDID(child, vendorID, productID);
            IOObjectRelease(child);
            if (result) {
                IOObjectRelease(children);
                return result;
            }
        }
        IOObjectRelease(children);
    }
    return nil;
}

// Search IOMobileFramebufferShim services and their children for EDID
static NSData *getEDIDFromDisplayHints(CGDirectDisplayID displayID) {
    uint32_t vendorID = CGDisplayVendorNumber(displayID);
    uint32_t productID = CGDisplayModelNumber(displayID);
    if (vendorID == 0 && productID == 0) return nil;

    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IOMobileFramebufferShim"),
        &iter
    );
    if (kr != KERN_SUCCESS || !iter) return nil;

    NSData *result = nil;
    io_service_t service;
    while ((service = IOIteratorNext(iter)) != 0) {
        result = searchMetadataForEDID(service, vendorID, productID);
        IOObjectRelease(service);
        if (result) break;
    }
    IOObjectRelease(iter);
    return result;
}

NSData *getDisplayEDID(CGDirectDisplayID displayID) {
    // Try the direct IOService path first (deprecated but still functional)
    NSData *edid = getEDIDFromIOService(displayID);
    if (edid) return edid;

    // Try DisplayHints Metadata (matches by vendor/product)
    edid = getEDIDFromDisplayHints(displayID);
    if (edid) return edid;

    // Fall back to searching DCPAVServiceProxy
    return getEDIDFromDCPAV(displayID);
}
