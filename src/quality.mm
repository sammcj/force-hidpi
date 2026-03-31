// quality.mm - Display quality tweaks for virtual display compositing
#import "quality.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <math.h>
#import <stdio.h>

void printQualityInfo(CGDirectDisplayID displayID) {
    void *skylight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_NOW);
    if (!skylight) return;

    typedef uint32_t (*GetBPS)(CGDirectDisplayID);
    typedef uint32_t (*GetBPP)(CGDirectDisplayID);
    typedef bool (*IsHDR)(CGDirectDisplayID);
    typedef bool (*SupportsHDR)(CGDirectDisplayID);

    auto bps = (GetBPS)dlsym(skylight, "SLDisplayBitsPerSample");
    auto bpp = (GetBPP)dlsym(skylight, "SLDisplayBitsPerPixel");
    auto isHDR = (IsHDR)dlsym(skylight, "SLSDisplayIsHDRModeEnabled");
    auto supHDR = (SupportsHDR)dlsym(skylight, "SLSDisplaySupportsHDRMode");

    fprintf(stdout, "  Quality for display 0x%x:\n", displayID);
    if (bps) fprintf(stdout, "    BitsPerSample: %u\n", bps(displayID));
    if (bpp) fprintf(stdout, "    BitsPerPixel:  %u\n", bpp(displayID));
    if (isHDR) fprintf(stdout, "    HDR enabled:   %s\n",
                       isHDR(displayID) ? "yes" : "no");
    if (supHDR) fprintf(stdout, "    HDR supported: %s\n",
                        supHDR(displayID) ? "yes" : "no");
}

// Build a PQ (ST 2084) to SDR (gamma 2.2) correction lookup table.
// Input: PQ-encoded signal (0-1). Output: gamma 2.2 encoded (0-1).
static void buildPQtoSDRTable(float *table, uint32_t count) {
    const double m1 = 0.1593017578125;
    const double m2 = 78.84375;
    const double c1 = 0.8359375;
    const double c2 = 18.8515625;
    const double c3 = 18.6875;

    for (uint32_t i = 0; i < count; i++) {
        double pq = (double)i / (double)(count - 1);

        // PQ EOTF: PQ signal -> linear light (normalised to 10000 nits)
        double num = pow(pq, 1.0 / m2);
        double den = c2 - c3 * pow(pq, 1.0 / m2);
        double linear = 0;
        if (den > 0 && num > c1) {
            linear = pow((num - c1) / den, 1.0 / m1);
        }

        // Scale 10000 nit range to SDR (assume 100 nits reference)
        linear *= 100.0;
        if (linear > 1.0) linear = 1.0;
        if (linear < 0.0) linear = 0.0;

        // Encode as gamma 2.2 for SDR output
        table[i] = (float)pow(linear, 1.0 / 2.2);
    }
}

bool applyPQGammaCorrection(CGDirectDisplayID displayID) {
    const uint32_t tableSize = 256;
    float r[tableSize], g[tableSize], b[tableSize];
    buildPQtoSDRTable(r, tableSize);
    memcpy(g, r, sizeof(r));
    memcpy(b, r, sizeof(r));

    CGError err = CGSetDisplayTransferByTable(displayID, tableSize, r, g, b);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "error: CGSetDisplayTransferByTable failed (%d)\n", err);
        return false;
    }
    fprintf(stdout, "  Applied PQ-to-SDR gamma correction\n");
    return true;
}

// Get a display colour space description (name or ICC profile desc)
static NSString *colourSpaceDescription(CGColorSpaceRef cs) {
    if (!cs) return @"(none)";

    CFStringRef name = CGColorSpaceGetName(cs);
    if (name) return (__bridge NSString *)name;

    // No name - try to get description from ICC profile data
    CFDataRef icc = CGColorSpaceCopyICCData(cs);
    if (icc) {
        CFIndex len = CFDataGetLength(icc);
        NSString *desc = [NSString stringWithFormat:@"ICC profile (%ld bytes)", (long)len];
        CFRelease(icc);
        return desc;
    }

    CGColorSpaceModel model = CGColorSpaceGetModel(cs);
    switch (model) {
        case kCGColorSpaceModelRGB: return @"RGB (unnamed)";
        case kCGColorSpaceModelCMYK: return @"CMYK (unnamed)";
        case kCGColorSpaceModelLab: return @"Lab (unnamed)";
        default: return @"(unknown model)";
    }
}

void printColourDiagnostics(CGDirectDisplayID virtualID, CGDirectDisplayID physicalID) {
    fprintf(stdout, "\n  Colour diagnostics:\n");

    CGColorSpaceRef vdCS = CGDisplayCopyColorSpace(virtualID);
    CGColorSpaceRef physCS = CGDisplayCopyColorSpace(physicalID);

    fprintf(stdout, "    Virtual colour space:  %s\n",
            [colourSpaceDescription(vdCS) UTF8String]);
    fprintf(stdout, "    Physical colour space: %s\n",
            [colourSpaceDescription(physCS) UTF8String]);

    if (vdCS && physCS) {
        CFDataRef vdICC = CGColorSpaceCopyICCData(vdCS);
        CFDataRef physICC = CGColorSpaceCopyICCData(physCS);
        bool iccMatch = false;
        if (vdICC && physICC) {
            iccMatch = CFEqual(vdICC, physICC);
        }
        fprintf(stdout, "    ICC profiles match:    %s\n", iccMatch ? "YES" : "NO");
        if (vdICC && physICC && !iccMatch) {
            fprintf(stdout, "    Virtual ICC size:  %ld bytes\n", CFDataGetLength(vdICC));
            fprintf(stdout, "    Physical ICC size: %ld bytes\n", CFDataGetLength(physICC));
        }
        if (vdICC) CFRelease(vdICC);
        if (physICC) CFRelease(physICC);
    }

    // Physical size and PPI comparison
    CGSize vdSize = CGDisplayScreenSize(virtualID);
    CGSize physSize = CGDisplayScreenSize(physicalID);
    size_t vdPxW = CGDisplayPixelsWide(virtualID);
    size_t vdPxH = CGDisplayPixelsHigh(virtualID);
    size_t physPxW = CGDisplayPixelsWide(physicalID);
    size_t physPxH = CGDisplayPixelsHigh(physicalID);

    fprintf(stdout, "    Virtual size:  %.0f x %.0f mm (%zux%zu px",
            vdSize.width, vdSize.height, vdPxW, vdPxH);
    if (vdSize.width > 0) {
        fprintf(stdout, ", %.1f PPI", (double)vdPxW / (vdSize.width / 25.4));
    }
    fprintf(stdout, ")\n");

    fprintf(stdout, "    Physical size: %.0f x %.0f mm (%zux%zu px",
            physSize.width, physSize.height, physPxW, physPxH);
    if (physSize.width > 0) {
        fprintf(stdout, ", %.1f PPI", (double)physPxW / (physSize.width / 25.4));
    }
    fprintf(stdout, ")\n");

    if (vdCS) CGColorSpaceRelease(vdCS);
    if (physCS) CGColorSpaceRelease(physCS);
}

bool matchColourProfile(CGDirectDisplayID physicalID, CGDirectDisplayID virtualID) {
    CGColorSpaceRef physCS = CGDisplayCopyColorSpace(physicalID);
    if (!physCS) {
        fprintf(stderr, "  warning: could not read physical display colour space\n");
        return false;
    }

    // Check if they already match
    CGColorSpaceRef vdCS = CGDisplayCopyColorSpace(virtualID);
    if (vdCS) {
        CFDataRef vdICC = CGColorSpaceCopyICCData(vdCS);
        CFDataRef physICC = CGColorSpaceCopyICCData(physCS);
        if (vdICC && physICC && CFEqual(vdICC, physICC)) {
            fprintf(stdout, "  Colour profiles already match\n");
            CFRelease(vdICC);
            CFRelease(physICC);
            CGColorSpaceRelease(vdCS);
            CGColorSpaceRelease(physCS);
            return true;
        }
        if (vdICC) CFRelease(vdICC);
        if (physICC) CFRelease(physICC);
        CGColorSpaceRelease(vdCS);
    }

    void *skylight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_NOW);
    if (!skylight) {
        CGColorSpaceRelease(physCS);
        return false;
    }

    typedef CGError (*SetCSFunc)(CGDirectDisplayID, CGColorSpaceRef);

    const char *symbols[] = {
        "SLSSetDisplayColorSpace",
        "CGSSetDisplayColorSpace",
        "SLDisplaySetColorSpace",
        NULL
    };

    for (int i = 0; symbols[i]; i++) {
        auto setCS = (SetCSFunc)dlsym(skylight, symbols[i]);
        if (setCS) {
            CGError err = setCS(virtualID, physCS);
            if (err == kCGErrorSuccess) {
                fprintf(stdout, "  Matched colour profile via %s\n", symbols[i]);
                CGColorSpaceRelease(physCS);
                return true;
            }
            fprintf(stderr, "  %s returned %d\n", symbols[i], err);
        }
    }

    // Fallback: try ColorSync
    void *colorsync = dlopen(
        "/System/Library/Frameworks/ColorSync.framework/ColorSync",
        RTLD_NOW);
    if (colorsync) {
        typedef void* (*CSCreateWithDisplay)(uint32_t);
        typedef bool (*CSInstallForDisplay)(void*, uint32_t);

        auto csCreate = (CSCreateWithDisplay)dlsym(
            colorsync, "ColorSyncProfileCreateWithDisplayID");
        auto csInstall = (CSInstallForDisplay)dlsym(
            colorsync, "ColorSyncProfileInstallForDisplay");

        if (csCreate && csInstall) {
            void *profile = csCreate(physicalID);
            if (profile) {
                bool ok = csInstall(profile, virtualID);
                if (ok) {
                    fprintf(stdout, "  Matched colour profile via ColorSync\n");
                    CFRelease((CFTypeRef)profile);
                    CGColorSpaceRelease(physCS);
                    return true;
                }
                CFRelease((CFTypeRef)profile);
            }
        }
    }

    fprintf(stderr, "  warning: could not match colour profiles\n");
    CGColorSpaceRelease(physCS);
    return false;
}

bool tryForce10BitCompositing(CGDirectDisplayID displayID) {
    void *skylight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_NOW);
    if (!skylight) return false;

    typedef uint32_t (*GetBPS)(CGDirectDisplayID);
    auto getBPS = (GetBPS)dlsym(skylight, "SLDisplayBitsPerSample");
    uint32_t currentBPS = getBPS ? getBPS(displayID) : 0;

    fprintf(stdout, "  10-bit probe: virtual display compositing at %u-bit\n", currentBPS);

    if (currentBPS >= 10) {
        fprintf(stdout, "  Already compositing at %u-bit\n", currentBPS);
        return true;
    }

    fprintf(stderr, "  Virtual display composites at %u-bit vs physical 10-bit.\n"
                    "  16-bit compositing is enabled by default (disable with --no-hdr).\n",
                    currentBPS);
    return false;
}
