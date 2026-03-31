// display_info.mm - Display enumeration via SkyLight and IOKit
#import "display_info.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>

// SkyLight function pointer types
typedef CFTypeRef (*SLDisplayCopyDisplayModeFunc)(CGDirectDisplayID);
typedef uint32_t (*SLModeU32Func)(CFTypeRef);
typedef double (*SLModeDblFunc)(CFTypeRef);
typedef uint32_t (*SLDispU32Func)(CGDirectDisplayID);

// Resolved SkyLight function pointers
static SLDisplayCopyDisplayModeFunc sl_CopyDisplayMode = NULL;
static SLModeU32Func sl_ModeGetWidth = NULL;
static SLModeU32Func sl_ModeGetPixelWidth = NULL;
static SLModeU32Func sl_ModeGetPixelHeight = NULL;
static SLModeDblFunc sl_ModeGetPixelDensity = NULL;
static SLModeDblFunc sl_ModeGetRefreshRate = NULL;
static SLDispU32Func sl_BitsPerSample = NULL;

// Forward declarations for static helpers
static void populateSkyLightMode(DisplayInfo *info);
static void populateDCPBudget(DisplayInfo *info, int displayIndex);
static void parseMFBMaxSrcPixels(DisplayInfo *info, CFDictionaryRef dict);
static void populateConnectionMapping(DisplayInfo *info);
static void matchConnectionEntry(DisplayInfo *info, CFArrayRef mapping);
static void extractConnectionValues(DisplayInfo *info, CFDictionaryRef entry);
static void printHiDPIStatus(const DisplayInfo *info);

bool loadSkyLight(void) {
    void *handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_NOW
    );
    if (!handle) {
        fprintf(stderr, "error: failed to load SkyLight framework\n");
        return false;
    }

    sl_CopyDisplayMode = (SLDisplayCopyDisplayModeFunc)dlsym(handle, "SLDisplayCopyDisplayMode");
    sl_ModeGetWidth = (SLModeU32Func)dlsym(handle, "SLDisplayModeGetWidth");
    sl_ModeGetPixelWidth = (SLModeU32Func)dlsym(handle, "SLDisplayModeGetPixelWidth");
    sl_ModeGetPixelHeight = (SLModeU32Func)dlsym(handle, "SLDisplayModeGetPixelHeight");
    sl_ModeGetPixelDensity = (SLModeDblFunc)dlsym(handle, "SLDisplayModeGetPixelDensity");
    sl_ModeGetRefreshRate = (SLModeDblFunc)dlsym(handle, "SLDisplayModeGetRefreshRate");
    sl_BitsPerSample = (SLDispU32Func)dlsym(handle, "SLDisplayBitsPerSample");

    if (!sl_CopyDisplayMode || !sl_ModeGetWidth || !sl_ModeGetPixelWidth) {
        fprintf(stderr, "error: failed to resolve required SkyLight symbols\n");
        return false;
    }
    return true;
}

// Populate scale and pixel dimensions from SkyLight current mode
static void populateSkyLightMode(DisplayInfo *info) {
    if (!sl_CopyDisplayMode) return;

    CFTypeRef mode = sl_CopyDisplayMode(info->displayID);
    if (!mode) return;

    uint32_t pointW = sl_ModeGetWidth ? sl_ModeGetWidth(mode) : 0;
    info->currentPixelWidth = sl_ModeGetPixelWidth ? sl_ModeGetPixelWidth(mode) : 0;
    info->currentPixelHeight = sl_ModeGetPixelHeight ? sl_ModeGetPixelHeight(mode) : 0;
    info->refreshRate = sl_ModeGetRefreshRate ? sl_ModeGetRefreshRate(mode) : 0;
    info->currentScale = (pointW > 0)
        ? (float)info->currentPixelWidth / (float)pointW
        : 1.0f;
    info->bitsPerSample = sl_BitsPerSample ? (int)sl_BitsPerSample(info->displayID) : 8;

    CFRelease(mode);
}

// Check if an IOMobileFramebufferShim service is the internal display
static bool isInternalShim(io_service_t service) {
    CFTypeRef pclk = IORegistryEntryCreateCFProperty(
        service, CFSTR("PixelClock"), kCFAllocatorDefault, 0);
    uint64_t val = 0;
    if (pclk && CFGetTypeID(pclk) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)pclk, kCFNumberSInt64Type, &val);
    }
    if (pclk) CFRelease(pclk);
    return val > 0;
}

// Read DCP budget from the matching IOMobileFramebufferShim service
static void readShimBudget(DisplayInfo *info, io_service_t service) {
    CFTypeRef val = IORegistryEntryCreateCFProperty(
        service, CFSTR("MaxVideoSrcDownscalingWidth"), kCFAllocatorDefault, 0);
    if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)val, kCFNumberSInt32Type,
                         &info->maxVideoSrcDownscalingWidth);
    }
    if (val) CFRelease(val);

    CFTypeRef pixDict = IORegistryEntryCreateCFProperty(
        service, CFSTR("IOMFBMaxSrcPixels"), kCFAllocatorDefault, 0);
    if (pixDict && CFGetTypeID(pixDict) == CFDictionaryGetTypeID()) {
        parseMFBMaxSrcPixels(info, (CFDictionaryRef)pixDict);
    }
    if (pixDict) CFRelease(pixDict);
}

// Read DCP budget properties from IOMobileFramebufferShim services.
// Internal displays match the shim with PixelClock > 0.
// External displays match the first active external shim
// (MaxVideoSrcDownscalingWidth > 0, PixelClock == 0).
// All external shims share the same budget values so any active one works.
static void populateDCPBudget(DisplayInfo *info, int displayIndex) {
    (void)displayIndex;
    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IOMobileFramebufferShim"),
        &iter);
    if (kr != KERN_SUCCESS || !iter) return;

    io_service_t service;
    while ((service = IOIteratorNext(iter)) != 0) {
        bool shimInternal = isInternalShim(service);
        if (shimInternal == info->isBuiltin) {
            // For external: only use shims with active downscaling width
            if (!info->isBuiltin) {
                CFTypeRef dw = IORegistryEntryCreateCFProperty(
                    service, CFSTR("MaxVideoSrcDownscalingWidth"),
                    kCFAllocatorDefault, 0);
                uint32_t dwVal = 0;
                if (dw && CFGetTypeID(dw) == CFNumberGetTypeID()) {
                    CFNumberGetValue((CFNumberRef)dw, kCFNumberSInt32Type, &dwVal);
                }
                if (dw) CFRelease(dw);
                if (dwVal == 0) {
                    IOObjectRelease(service);
                    continue;
                }
            }
            readShimBudget(info, service);
            IOObjectRelease(service);
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
}

// Parse the IOMFBMaxSrcPixels dictionary into DisplayInfo fields
static void parseMFBMaxSrcPixels(DisplayInfo *info, CFDictionaryRef dict) {
    // MaxSrcRectWidthForPipe array
    CFArrayRef wArr = (CFArrayRef)CFDictionaryGetValue(dict, CFSTR("MaxSrcRectWidthForPipe"));
    if (wArr && CFGetTypeID(wArr) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(wArr);
        if (count > 4) count = 4;
        for (CFIndex i = 0; i < count; i++) {
            CFNumberRef n = (CFNumberRef)CFArrayGetValueAtIndex(wArr, i);
            if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &info->maxSrcRectWidthForPipe[i]);
        }
    }

    // MaxSrcRectHeightForPipe array
    CFArrayRef hArr = (CFArrayRef)CFDictionaryGetValue(dict, CFSTR("MaxSrcRectHeightForPipe"));
    if (hArr && CFGetTypeID(hArr) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(hArr);
        if (count > 4) count = 4;
        for (CFIndex i = 0; i < count; i++) {
            CFNumberRef n = (CFNumberRef)CFArrayGetValueAtIndex(hArr, i);
            if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &info->maxSrcRectHeightForPipe[i]);
        }
    }

    // MaxSrcBufferWidth / MaxSrcBufferHeight
    CFNumberRef bw = (CFNumberRef)CFDictionaryGetValue(dict, CFSTR("MaxSrcBufferWidth"));
    if (bw) CFNumberGetValue(bw, kCFNumberSInt32Type, &info->maxSrcBufferWidth);

    CFNumberRef bh = (CFNumberRef)CFDictionaryGetValue(dict, CFSTR("MaxSrcBufferHeight"));
    if (bh) CFNumberGetValue(bh, kCFNumberSInt32Type, &info->maxSrcBufferHeight);
}

// Search IOKit registry for ConnectionMapping and populate pipe info
static void populateConnectionMapping(DisplayInfo *info) {
    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IOMobileFramebufferShim"),
        &iter
    );
    if (kr != KERN_SUCCESS || !iter) return;

    io_service_t service;
    while ((service = IOIteratorNext(iter)) != 0) {
        CFTypeRef mapping = IORegistryEntryCreateCFProperty(
            service, CFSTR("ConnectionMapping"), kCFAllocatorDefault, 0
        );
        if (!mapping) {
            IOObjectRelease(service);
            continue;
        }

        if (CFGetTypeID(mapping) == CFArrayGetTypeID()) {
            matchConnectionEntry(info, (CFArrayRef)mapping);
        }
        CFRelease(mapping);
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
}

// Find the entry in ConnectionMapping matching this display's product name
static void matchConnectionEntry(DisplayInfo *info, CFArrayRef mapping) {
    NSString *targetName = [NSString stringWithUTF8String:info->productName];
    CFIndex count = CFArrayGetCount(mapping);

    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef entry = (CFDictionaryRef)CFArrayGetValueAtIndex(mapping, i);
        if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID()) continue;

        CFStringRef name = (CFStringRef)CFDictionaryGetValue(entry, CFSTR("ProductName"));
        if (!name) continue;

        NSString *entryName = (__bridge NSString *)name;
        if (![entryName isEqualToString:targetName]) continue;

        extractConnectionValues(info, entry);
        return;
    }
}

// Extract pipe IDs and limits from a ConnectionMapping dictionary entry
static void extractConnectionValues(DisplayInfo *info, CFDictionaryRef entry) {
    // PipeIDs
    CFArrayRef pipes = (CFArrayRef)CFDictionaryGetValue(entry, CFSTR("PipeIDs"));
    if (pipes && CFGetTypeID(pipes) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(pipes);
        if (count > 4) count = 4;
        info->pipeCount = (uint32_t)count;
        for (CFIndex i = 0; i < count; i++) {
            CFNumberRef n = (CFNumberRef)CFArrayGetValueAtIndex(pipes, i);
            if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &info->pipeIDs[i]);
        }
    }

    // MaxPipes
    CFNumberRef mp = (CFNumberRef)CFDictionaryGetValue(entry, CFSTR("MaxPipes"));
    if (mp) {
        uint32_t v;
        CFNumberGetValue(mp, kCFNumberSInt32Type, &v);
        if (v > info->pipeCount) info->pipeCount = v;
    }

    // Scalar values
    CFNumberRef mw = (CFNumberRef)CFDictionaryGetValue(entry, CFSTR("MaxW"));
    if (mw) CFNumberGetValue(mw, kCFNumberSInt32Type, &info->maxW);

    CFNumberRef mh = (CFNumberRef)CFDictionaryGetValue(entry, CFSTR("MaxH"));
    if (mh) CFNumberGetValue(mh, kCFNumberSInt32Type, &info->maxH);

    CFNumberRef mb = (CFNumberRef)CFDictionaryGetValue(entry, CFSTR("MaxBpc"));
    if (mb) CFNumberGetValue(mb, kCFNumberSInt32Type, &info->maxBpc);

    CFNumberRef mr = (CFNumberRef)CFDictionaryGetValue(entry, CFSTR("MaxActivePixelRate"));
    if (mr) CFNumberGetValue(mr, kCFNumberSInt64Type, &info->maxActivePixelRate);
}

int enumerateDisplays(DisplayInfo *out, int maxCount) {
    uint32_t numDisplays = 0;
    CGDirectDisplayID displayList[16];
    CGGetOnlineDisplayList(16, displayList, &numDisplays);

    int count = 0;
    for (uint32_t i = 0; i < numDisplays && count < maxCount; i++) {
        DisplayInfo *info = &out[count];
        memset(info, 0, sizeof(DisplayInfo));

        info->displayID = displayList[i];
        info->isBuiltin = CGDisplayIsBuiltin(info->displayID);
        info->isMirrored = CGDisplayIsInMirrorSet(info->displayID);
        info->vendorID = CGDisplayVendorNumber(info->displayID);
        info->productID = CGDisplayModelNumber(info->displayID);
        info->nativeWidth = (uint32_t)CGDisplayPixelsWide(info->displayID);
        info->nativeHeight = (uint32_t)CGDisplayPixelsHigh(info->displayID);

        populateSkyLightMode(info);
        populateDCPBudget(info, (int)i);
        populateConnectionMapping(info);

        count++;
    }
    return count;
}

int findTargetDisplay(DisplayInfo *displays, int count, int requestedIndex) {
    if (requestedIndex >= 0) {
        return (requestedIndex < count) ? requestedIndex : -1;
    }

    // Find the first external display with native width >= 3840
    for (int i = 0; i < count; i++) {
        if (!displays[i].isBuiltin && displays[i].nativeWidth >= 3840) {
            return i;
        }
    }
    return -1;
}

// Print HiDPI status assessment
static void printHiDPIStatus(const DisplayInfo *info) {
    uint32_t neededW = info->nativeWidth * 2;
    int32_t pipeBudget = info->maxSrcRectWidthForPipe[0];

    if (pipeBudget <= 0) {
        fprintf(stdout, "    HiDPI Status: UNKNOWN (no DCP budget data)\n");
        return;
    }

    if ((uint32_t)pipeBudget >= neededW) {
        fprintf(stdout, "    HiDPI Status: OK (pipe 0 budget %d >= %u needed for %ux%u@2x)\n",
                pipeBudget, neededW, info->nativeWidth, info->nativeHeight);
    } else {
        fprintf(stdout, "    HiDPI Status: BLOCKED (pipe 0 budget %d < %u needed for %ux%u@2x)\n",
                pipeBudget, neededW, info->nativeWidth, info->nativeHeight);
    }
}

void printDisplayInfo(const DisplayInfo *info) {
    const char *typeStr = info->isBuiltin ? "built-in" : "external";
    fprintf(stdout, "  Display 0x%x: %s (0x%04x:0x%04x) [%s]\n",
            info->displayID,
            info->productName[0] ? info->productName : "(unknown)",
            info->vendorID, info->productID, typeStr);

    fprintf(stdout, "    Resolution:  %ux%u @ %.0fHz (pixel: %ux%u, scale: %.1fx)\n",
            info->nativeWidth, info->nativeHeight, info->refreshRate,
            info->currentPixelWidth, info->currentPixelHeight, info->currentScale);

    fprintf(stdout, "    Colour:      %d-bit\n", info->bitsPerSample);

    if (info->pipeCount > 0) {
        fprintf(stdout, "    Connection:  PipeIDs=(");
        for (uint32_t p = 0; p < info->pipeCount; p++) {
            fprintf(stdout, "%s%u", p > 0 ? "," : "", info->pipeIDs[p]);
        }
        fprintf(stdout, "), MaxPipes=%u\n", info->pipeCount);
    }

    if (info->maxVideoSrcDownscalingWidth > 0) {
        fprintf(stdout, "    DCP Budget:\n");
        fprintf(stdout, "      MaxVideoSrcDownscalingWidth: %u\n",
                info->maxVideoSrcDownscalingWidth);
        fprintf(stdout, "      MaxSrcRectWidthForPipe:  [%d, %d, %d, %d]\n",
                info->maxSrcRectWidthForPipe[0], info->maxSrcRectWidthForPipe[1],
                info->maxSrcRectWidthForPipe[2], info->maxSrcRectWidthForPipe[3]);
        fprintf(stdout, "      MaxSrcRectHeightForPipe: [%d, %d, %d, %d]\n",
                info->maxSrcRectHeightForPipe[0], info->maxSrcRectHeightForPipe[1],
                info->maxSrcRectHeightForPipe[2], info->maxSrcRectHeightForPipe[3]);
        fprintf(stdout, "      MaxSrcBufferWidth: %u, MaxSrcBufferHeight: %u\n",
                info->maxSrcBufferWidth, info->maxSrcBufferHeight);
    }

    if (info->maxW > 0) {
        fprintf(stdout, "    Display Hints:\n");
        fprintf(stdout, "      MaxW=%u, MaxH=%u, MaxBpc=%u\n",
                info->maxW, info->maxH, info->maxBpc);
        fprintf(stdout, "      MaxActivePixelRate: %llu\n", info->maxActivePixelRate);
    }

    printHiDPIStatus(info);
}

void printAllDisplayInfo(DisplayInfo *displays, int count) {
    fprintf(stdout, "Detected %d display%s:\n\n", count, count == 1 ? "" : "s");
    for (int i = 0; i < count; i++) {
        printDisplayInfo(&displays[i]);
        fprintf(stdout, "\n");
    }
}
