// main.mm - Entry point for force-hidpi CLI tool
// Creates a virtual display via SkyLight private API and mirrors a physical 4K
// display from it to achieve 3840x2160 HiDPI on Apple Silicon where the DCP
// firmware caps HiDPI at 3360x1890.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <getopt.h>
#import <stdio.h>

#import "display_info.h"
#import "virtual_display.h"
#import "mirror.h"
#import "daemon.h"
#import "edid.h"
#import "quality.h"

#define FORCE_HIDPI_VERSION "0.1.0"
#define MAX_DISPLAYS 16

// Forward declarations for static helpers
static void populateEDIDInfo(DisplayInfo *info);
static int activateHiDPI(DisplayInfo *target, bool dryRun, bool daemonMode,
                         bool hdrMode, uint32_t scaleFactor);
static int finishActivation(CGDirectDisplayID vdID, DisplayInfo *target,
                            bool daemonMode, bool hdrMode);

static void printUsage(const char *progname) {
    fprintf(stdout,
        "Usage: %s [options]\n\n"
        "Options:\n"
        "  -i, --info       Enumerate and print all display info, then exit\n"
        "  -D, --daemon     Run as background daemon (write PID file)\n"
        "  -S, --stop       Stop a running daemon instance\n"
        "  -d, --display N  Target a specific display index\n"
        "  -s, --scale N    Pixel scale factor (default: 2, max: 4)\n"
        "                   Higher values supersample for sharper rendering\n"
        "                   at the cost of GPU load (3 = 11520x6480 backing)\n"
        "  -n, --dry-run    Show what would happen without applying changes\n"
        "      --no-hdr     Disable 16-bit compositing (use 8-bit SDR)\n"
        "  -h, --help       Show this help message\n"
        "  -V, --version    Print version and exit\n\n"
        "By default, uses 16-bit compositing (PQ EOTF with gamma correction)\n"
        "for higher quality rendering. Use --no-hdr for 8-bit compositing.\n",
        progname
    );
}

static struct option longOpts[] = {
    {"info",    no_argument,       NULL, 'i'},
    {"no-hdr",  no_argument,       NULL, 'H'},
    {"daemon",  no_argument,       NULL, 'D'},
    {"stop",    no_argument,       NULL, 'S'},
    {"display", required_argument, NULL, 'd'},
    {"scale",   required_argument, NULL, 's'},
    {"dry-run", no_argument,       NULL, 'n'},
    {"help",    no_argument,       NULL, 'h'},
    {"version", no_argument,       NULL, 'V'},
    {NULL, 0, NULL, 0}
};

// Parse EDID and populate the display's product name if not already set
static void populateEDIDInfo(DisplayInfo *info) {
    NSData *edid = getDisplayEDID(info->displayID);
    if (!edid) return;

    const uint8_t *bytes = (const uint8_t *)[edid bytes];
    size_t len = [edid length];

    if (info->productName[0] == '\0') {
        parseEDIDProductName(bytes, len, info->productName, sizeof(info->productName));
    }

    // Override vendor/product from EDID if CG returned zero
    if (info->vendorID == 0 || info->productID == 0) {
        parseEDIDVendorProduct(bytes, len, &info->vendorID, &info->productID);
    }
}

static int runInfoMode(void) {
    DisplayInfo displays[MAX_DISPLAYS];
    int count = enumerateDisplays(displays, MAX_DISPLAYS);
    if (count == 0) {
        fprintf(stderr, "No displays found.\n");
        return 1;
    }
    for (int i = 0; i < count; i++) {
        populateEDIDInfo(&displays[i]);
    }
    printAllDisplayInfo(displays, count);
    return 0;
}

static int runStopMode(void) {
    return stopRunningDaemon() ? 0 : 1;
}

// Perform the main HiDPI activation sequence
static int runActivate(int requestedDisplay, bool dryRun, bool daemonMode,
                       bool hdrMode, uint32_t scaleFactor) {
    DisplayInfo displays[MAX_DISPLAYS];
    int count = enumerateDisplays(displays, MAX_DISPLAYS);
    if (count == 0) {
        fprintf(stderr, "error: no displays found\n");
        return 1;
    }

    for (int i = 0; i < count; i++) {
        populateEDIDInfo(&displays[i]);
    }

    int targetIdx = findTargetDisplay(displays, count, requestedDisplay);
    if (targetIdx < 0) {
        fprintf(stderr, "error: no suitable 4K external display found\n");
        printAllDisplayInfo(displays, count);
        return 1;
    }

    DisplayInfo *target = &displays[targetIdx];
    return activateHiDPI(target, dryRun, daemonMode, hdrMode, scaleFactor);
}

// Create virtual display, configure mirror, and enter run loop
static int activateHiDPI(DisplayInfo *target, bool dryRun, bool daemonMode,
                         bool hdrMode, uint32_t scaleFactor) {
    fprintf(stdout, "Target: %s (0x%04x:0x%04x) %ux%u @ %.0fHz\n",
            target->productName[0] ? target->productName : "(unknown)",
            target->vendorID, target->productID,
            target->nativeWidth, target->nativeHeight, target->refreshRate);

    uint32_t pixelW = target->nativeWidth * scaleFactor;
    uint32_t pixelH = target->nativeHeight * scaleFactor;

    if (dryRun) {
        fprintf(stdout, "dry-run: would create virtual display %ux%u HiDPI "
                "(pixel buffer %ux%u, %ux scale) and mirror display 0x%x\n",
                target->nativeWidth, target->nativeHeight,
                pixelW, pixelH, scaleFactor,
                target->displayID);
        return 0;
    }

    // Check for existing instance
    pid_t existingPID = 0;
    if (isAlreadyRunning(&existingPID)) {
        fprintf(stderr, "error: force-hidpi already running (pid %d)\n", existingPID);
        return 1;
    }

    double hz = target->refreshRate > 0 ? target->refreshRate : 60.0;

    NSString *name = [NSString stringWithFormat:@"force-hidpi (%s)",
                      target->productName[0] ? target->productName : "4K HiDPI"];

    uint32_t eotf = hdrMode ? 1 : 0;
    CGDirectDisplayID vdID = createVirtualHiDPIDisplay(
        name, target->vendorID, target->productID,
        pixelW, pixelH,
        target->nativeWidth, target->nativeHeight, hz, eotf
    );
    if (vdID == 0) {
        fprintf(stderr, "error: failed to create virtual display\n");
        return 1;
    }

    if (scaleFactor > 2) {
        fprintf(stdout, "  Supersampling: %ux scale (%ux%u backing store)\n",
                scaleFactor, pixelW, pixelH);
    }

    return finishActivation(vdID, target, daemonMode, hdrMode);
}

// Wait for the virtual display, set up mirroring, and enter the event loop
static int finishActivation(CGDirectDisplayID vdID, DisplayInfo *target,
                            bool daemonMode, bool hdrMode) {
    fprintf(stdout, "Virtual display created: 0x%x\n", vdID);

    if (!waitForDisplay(vdID, 5.0)) {
        fprintf(stderr, "error: virtual display 0x%x did not appear\n", vdID);
        destroyVirtualDisplay();
        return 1;
    }

    if (!configureMirror(vdID, target->displayID)) {
        fprintf(stderr, "error: failed to configure mirroring\n");
        destroyVirtualDisplay();
        return 1;
    }

    // Apply quality settings
    if (hdrMode) {
        fprintf(stdout, "  HDR mode: 16-bit compositing with PQ gamma correction\n");
        applyPQGammaCorrection(vdID);
    }
    printQualityInfo(vdID);
    printQualityInfo(target->displayID);

    // Try to force 10-bit compositing on the virtual display
    tryForce10BitCompositing(vdID);

    // Match the physical display's colour profile to the virtual display
    matchColourProfile(target->displayID, vdID);
    printColourDiagnostics(vdID, target->displayID);

    const char *modeStr = hdrMode ? "HiDPI 16-bit" : "HiDPI 8-bit";
    fprintf(stdout, "force-hidpi: active on %s (%ux%u %s via hardware mirror)\n",
            target->productName[0] ? target->productName : "(display)",
            target->nativeWidth, target->nativeHeight, modeStr);

    if (daemonMode) {
        writePIDFile();
    }

    installSignalHandlers();
    runEventLoop();

    // Clean up on exit
    fprintf(stdout, "\nforce-hidpi: shutting down\n");
    unconfigureMirror(target->displayID);
    destroyVirtualDisplay();
    removePIDFile();

    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        bool infoMode = false;
        bool stopMode = false;
        bool daemonMode = false;
        bool dryRun = false;
        bool hdrMode = true;  // 16-bit compositing on by default
        uint32_t scaleFactor = 2;
        int requestedDisplay = -1;

        int ch;
        while ((ch = getopt_long(argc, argv, "iDSd:s:nHhV", longOpts, NULL)) != -1) {
            switch (ch) {
                case 'i': infoMode = true; break;
                case 'D': daemonMode = true; break;
                case 'S': stopMode = true; break;
                case 'd': requestedDisplay = atoi(optarg); break;
                case 's': {
                    int s = atoi(optarg);
                    if (s < 2 || s > 4) {
                        fprintf(stderr, "error: scale must be 2, 3, or 4\n");
                        return 1;
                    }
                    scaleFactor = (uint32_t)s;
                    break;
                }
                case 'n': dryRun = true; break;
                case 'H': hdrMode = false; break;  // --no-hdr disables
                case 'V':
                    fprintf(stdout, "force-hidpi %s\n", FORCE_HIDPI_VERSION);
                    return 0;
                case 'h':
                default:
                    printUsage(argv[0]);
                    return (ch == 'h') ? 0 : 1;
            }
        }

        if (!loadSkyLight()) {
            fprintf(stderr, "error: SkyLight framework unavailable\n");
            return 1;
        }

        if (stopMode) return runStopMode();
        if (infoMode) return runInfoMode();
        return runActivate(requestedDisplay, dryRun, daemonMode, hdrMode, scaleFactor);
    }
}
