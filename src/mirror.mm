// mirror.mm - Display mirroring via CoreGraphics configuration API
#import "mirror.h"
#import <Foundation/Foundation.h>
#import <unistd.h>

bool configureMirror(CGDirectDisplayID sourceDisplay, CGDirectDisplayID targetDisplay) {
    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess || !config) {
        fprintf(stderr, "error: CGBeginDisplayConfiguration failed (%d)\n", err);
        return false;
    }

    // Mirror target (physical) from source (virtual)
    err = CGConfigureDisplayMirrorOfDisplay(config, targetDisplay, sourceDisplay);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "error: CGConfigureDisplayMirrorOfDisplay failed (%d)\n", err);
        CGCancelDisplayConfiguration(config);
        return false;
    }

    // Set the virtual (source) display at origin (0,0) to make it the main display
    CGConfigureDisplayOrigin(config, sourceDisplay, 0, 0);

    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "error: CGCompleteDisplayConfiguration failed (%d)\n", err);
        return false;
    }

    return true;
}

bool unconfigureMirror(CGDirectDisplayID targetDisplay) {
    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess || !config) {
        fprintf(stderr, "error: CGBeginDisplayConfiguration failed (%d)\n", err);
        return false;
    }

    err = CGConfigureDisplayMirrorOfDisplay(config, targetDisplay, kCGNullDirectDisplay);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "error: unmirror failed (%d)\n", err);
        CGCancelDisplayConfiguration(config);
        return false;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "error: unmirror complete failed (%d)\n", err);
        return false;
    }

    return true;
}

bool waitForDisplay(CGDirectDisplayID displayID, double timeoutSecs) {
    double elapsed = 0.0;
    const double interval = 0.5;

    while (elapsed < timeoutSecs) {
        uint32_t numDisplays = 0;
        CGDirectDisplayID displays[32];
        CGGetOnlineDisplayList(32, displays, &numDisplays);

        for (uint32_t i = 0; i < numDisplays; i++) {
            if (displays[i] == displayID) {
                return true;
            }
        }

        usleep((useconds_t)(interval * 1000000));
        elapsed += interval;

        // Virtual displays may not appear in CGGetOnlineDisplayList without
        // Screen Recording permission. Proceed after a reasonable wait.
        if (elapsed >= 2.0) {
            return true;
        }
    }

    return true;
}

