// probe_depth.mm - Probe SkyLight display depth and output mode APIs
// Build: clang++ -std=c++17 -ObjC++ -fno-objc-arc -mmacosx-version-min=14.0 -ldl -framework CoreGraphics -framework Foundation -o $TMPDIR/probe_depth tests/probe_depth.mm
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <stdio.h>
#import <signal.h>
#import <setjmp.h>

static sigjmp_buf jumpBuf;
static volatile sig_atomic_t inProbe = 0;

static void crashHandler(int sig) {
    if (inProbe) {
        siglongjmp(jumpBuf, sig);
    }
}

// Safely call a function that might segfault
#define SAFE_CALL_INT(label, func, arg, fallback) do { \
    inProbe = 1; \
    int _sig = sigsetjmp(jumpBuf, 1); \
    if (_sig == 0) { \
        int32_t _val = func(arg); \
        inProbe = 0; \
        fprintf(stdout, "  %-30s %d\n", label ":", _val); \
    } else { \
        inProbe = 0; \
        fprintf(stdout, "  %-30s CRASHED (signal %d)\n", label ":", _sig); \
    } \
} while(0)

#define SAFE_CALL_UINT(label, func, arg) do { \
    inProbe = 1; \
    int _sig = sigsetjmp(jumpBuf, 1); \
    if (_sig == 0) { \
        uint32_t _val = func(arg); \
        inProbe = 0; \
        fprintf(stdout, "  %-30s %u\n", label ":", _val); \
    } else { \
        inProbe = 0; \
        fprintf(stdout, "  %-30s CRASHED (signal %d)\n", label ":", _sig); \
    } \
} while(0)

#define SAFE_CALL_BOOL(label, func, arg) do { \
    inProbe = 1; \
    int _sig = sigsetjmp(jumpBuf, 1); \
    if (_sig == 0) { \
        bool _val = func(arg); \
        inProbe = 0; \
        fprintf(stdout, "  %-30s %s\n", label ":", _val ? "yes" : "no"); \
    } else { \
        inProbe = 0; \
        fprintf(stdout, "  %-30s CRASHED (signal %d)\n", label ":", _sig); \
    } \
} while(0)

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Install crash handler
        struct sigaction sa = {};
        sa.sa_handler = crashHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);

        void *sl = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW);
        if (!sl) {
            fprintf(stderr, "Failed to load SkyLight\n");
            return 1;
        }

        typedef int32_t (*GetDepth)(CGDirectDisplayID);
        typedef uint32_t (*GetPixelFormat)(CGDirectDisplayID);
        typedef uint32_t (*GetBPS)(CGDirectDisplayID);
        typedef uint32_t (*GetBPP)(CGDirectDisplayID);
        typedef uint32_t (*GetSPP)(CGDirectDisplayID);
        typedef bool (*IsHDR)(CGDirectDisplayID);
        typedef bool (*SupportsHDR)(CGDirectDisplayID);

        auto getDepth = (GetDepth)dlsym(sl, "SLSGetDisplayDepth");
        auto getPixFmt = (GetPixelFormat)dlsym(sl, "SLSGetDisplayPixelFormat");
        auto getBPS = (GetBPS)dlsym(sl, "SLDisplayBitsPerSample");
        auto getBPP = (GetBPP)dlsym(sl, "SLDisplayBitsPerPixel");
        auto getSPP = (GetSPP)dlsym(sl, "SLDisplaySamplesPerPixel");
        auto isHDR = (IsHDR)dlsym(sl, "SLSDisplayIsHDRModeEnabled");
        auto supHDR = (SupportsHDR)dlsym(sl, "SLSDisplaySupportsHDRMode");

        fprintf(stdout, "Symbol resolution:\n");
        fprintf(stdout, "  SLSGetDisplayDepth:       %s\n", getDepth ? "OK" : "NOT FOUND");
        fprintf(stdout, "  SLSGetDisplayPixelFormat:  %s\n", getPixFmt ? "OK" : "NOT FOUND");
        fprintf(stdout, "  SLDisplayBitsPerSample:    %s\n", getBPS ? "OK" : "NOT FOUND");
        fprintf(stdout, "  SLDisplayBitsPerPixel:     %s\n", getBPP ? "OK" : "NOT FOUND");
        fprintf(stdout, "  SLDisplaySamplesPerPixel:  %s\n", getSPP ? "OK" : "NOT FOUND");
        fprintf(stdout, "  SLSDisplayIsHDRModeEnabled:%s\n", isHDR ? "OK" : "NOT FOUND");
        fprintf(stdout, "  SLSDisplaySupportsHDRMode: %s\n", supHDR ? "OK" : "NOT FOUND");

        uint32_t numDisplays = 0;
        CGDirectDisplayID displays[16];
        CGGetOnlineDisplayList(16, displays, &numDisplays);
        fprintf(stdout, "\nFound %u displays\n", numDisplays);

        for (uint32_t i = 0; i < numDisplays; i++) {
            CGDirectDisplayID did = displays[i];
            bool builtin = CGDisplayIsBuiltin(did);
            bool mirrored = CGDisplayIsInMirrorSet(did);
            size_t pw = CGDisplayPixelsWide(did);
            size_t ph = CGDisplayPixelsHigh(did);

            fprintf(stdout, "\n=== Display 0x%x (%s%s) %zux%zu ===\n",
                    did, builtin ? "builtin" : "external",
                    mirrored ? ", mirrored" : "", pw, ph);
            fflush(stdout);

            if (getDepth) SAFE_CALL_INT("SLSGetDisplayDepth", getDepth, did, -1);
            if (getPixFmt) SAFE_CALL_UINT("SLSGetDisplayPixelFormat", getPixFmt, did);
            if (getBPS) SAFE_CALL_UINT("BitsPerSample", getBPS, did);
            if (getBPP) SAFE_CALL_UINT("BitsPerPixel", getBPP, did);
            if (getSPP) SAFE_CALL_UINT("SamplesPerPixel", getSPP, did);
            if (isHDR) SAFE_CALL_BOOL("HDR enabled", isHDR, did);
            if (supHDR) SAFE_CALL_BOOL("HDR supported", supHDR, did);

            // Colour space
            CGColorSpaceRef cs = CGDisplayCopyColorSpace(did);
            if (cs) {
                CFStringRef name = CGColorSpaceGetName(cs);
                fprintf(stdout, "  %-30s %s\n", "ColorSpace:",
                        name ? [(__bridge NSString *)name UTF8String] : "(unnamed)");
                CGColorSpaceRelease(cs);
            }

            // Pixel encoding from display mode
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
            if (mode) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                CFStringRef enc = CGDisplayModeCopyPixelEncoding(mode);
                #pragma clang diagnostic pop
                if (enc) {
                    fprintf(stdout, "  %-30s %s\n", "PixelEncoding:",
                            [(__bridge NSString *)enc UTF8String]);
                    CFRelease(enc);
                }
                fprintf(stdout, "  %-30s %d\n", "IODisplayModeID:",
                        CGDisplayModeGetIODisplayModeID(mode));
                CGDisplayModeRelease(mode);
            }
            fflush(stdout);
        }

        fprintf(stdout, "\nDone.\n");
        return 0;
    }
}
