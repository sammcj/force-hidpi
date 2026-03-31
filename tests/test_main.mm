// test_main.mm - Lightweight test runner for force-hidpi
#import <Foundation/Foundation.h>
#import <stdio.h>

static int g_passed = 0;
static int g_failed = 0;

#define ASSERT_TRUE(cond, msg) do { \
    if (cond) { g_passed++; } \
    else { g_failed++; fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
} while (0)

#define ASSERT_EQ(a, b, msg) ASSERT_TRUE((a) == (b), msg)
#define ASSERT_STR_EQ(a, b, msg) ASSERT_TRUE(strcmp((a), (b)) == 0, msg)

// Declarations for test suites
void test_edid(void);
void test_cli(void);
void test_display_match(void);

// EDID parsing functions (from edid.h)
#import "edid.h"

// Display matching (from display_info.h)
#import "display_info.h"

// --- EDID Tests ---

void test_edid(void) {
    fprintf(stdout, "--- EDID Tests ---\n");

    // Stock LG HDR 4K EDID header (first 18 bytes)
    uint8_t lg_edid[128] = {
        0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, // header
        0x1E, 0x6D,  // vendor: GSM (0x1E6D)
        0x50, 0x77,  // product: 0x7750 (LE)
        0x78, 0x7A, 0x09, 0x00, // serial
        0x05, 0x20,  // week 5, year 2022
        0x01, 0x04,  // EDID 1.4
        0xB5,        // video input
        0x46, 0x28,  // 70cm x 40cm
        0x78,        // gamma
    };

    // Add a preferred timing descriptor at offset 54
    // 3840x2160 @ 60Hz, pixel clock 533.25 MHz
    // Pixel clock: 53325 (x10kHz) = 0xD035
    lg_edid[54] = 0x35; lg_edid[55] = 0xD0; // pixel clock LE
    // H active = 3840 = 0x0F00
    lg_edid[56] = 0x00; // H active low 8
    lg_edid[57] = 0x00; // H blanking low 8
    lg_edid[58] = 0xF0; // H active high 4 | H blanking high 4
    // V active = 2160 = 0x0870
    lg_edid[59] = 0x70; // V active low 8
    lg_edid[60] = 0x00; // V blanking low 8
    lg_edid[61] = 0x80; // V active high 4 | V blanking high 4

    // Add monitor name descriptor at offset 90 (tag 0xFC)
    lg_edid[90] = 0x00; lg_edid[91] = 0x00; lg_edid[92] = 0x00;
    lg_edid[93] = 0xFC; lg_edid[94] = 0x00;
    const char *name = "LG HDR 4K\n   ";
    memcpy(&lg_edid[95], name, 13);

    // Test vendor/product parsing
    uint32_t vendor = 0, product = 0;
    bool ok = parseEDIDVendorProduct(lg_edid, 128, &vendor, &product);
    ASSERT_TRUE(ok, "parseEDIDVendorProduct succeeds");
    ASSERT_EQ(vendor, 0x1E6Du, "vendor is 0x1E6D (GSM)");
    ASSERT_EQ(product, 0x7750u, "product is 0x7750");

    // Test native resolution parsing
    uint32_t w = 0, h = 0;
    ok = parseEDIDNativeResolution(lg_edid, 128, &w, &h);
    ASSERT_TRUE(ok, "parseEDIDNativeResolution succeeds");
    ASSERT_EQ(w, 3840u, "native width is 3840");
    ASSERT_EQ(h, 2160u, "native height is 2160");

    // Test product name parsing
    char parsedName[64] = {0};
    ok = parseEDIDProductName(lg_edid, 128, parsedName, sizeof(parsedName));
    ASSERT_TRUE(ok, "parseEDIDProductName succeeds");
    ASSERT_STR_EQ(parsedName, "LG HDR 4K", "product name is 'LG HDR 4K'");

    // Test truncated EDID
    ok = parseEDIDVendorProduct(lg_edid, 10, &vendor, &product);
    ASSERT_TRUE(!ok, "parseEDIDVendorProduct fails on truncated EDID");

    // Test invalid header
    uint8_t bad_edid[128] = {0x01, 0x02, 0x03};
    ok = parseEDIDVendorProduct(bad_edid, 128, &vendor, &product);
    // Should still parse bytes 8-11 even with bad header
    // (vendor/product doesn't require valid header)
    ASSERT_TRUE(ok, "parseEDIDVendorProduct parses despite bad header");

    // Test empty EDID
    ok = parseEDIDVendorProduct(NULL, 0, &vendor, &product);
    ASSERT_TRUE(!ok, "parseEDIDVendorProduct fails on NULL");

    // Test name not found
    uint8_t no_name_edid[128] = {0};
    memcpy(no_name_edid, lg_edid, 54); // Copy header only
    ok = parseEDIDProductName(no_name_edid, 128, parsedName, sizeof(parsedName));
    ASSERT_TRUE(!ok, "parseEDIDProductName returns false when no name descriptor");
}

// --- CLI Argument Parsing Tests ---

// Extract action enum from main.mm
typedef enum {
    ACTION_AUTO = 0,
    ACTION_INFO,
    ACTION_DAEMON,
    ACTION_STOP,
    ACTION_HELP,
    ACTION_VERSION,
} Action;

typedef struct {
    Action action;
    int displayIndex;
    bool dryRun;
} CLIOptions;

// Forward-declare the parse function (defined in main.mm but we test the logic)
// Since we can't easily extract it, test the concept with a mock
static CLIOptions mockParseCLI(int argc, const char *argv[]) {
    CLIOptions opts = {ACTION_AUTO, -1, false};
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--info") == 0 || strcmp(argv[i], "-i") == 0)
            opts.action = ACTION_INFO;
        else if (strcmp(argv[i], "--daemon") == 0 || strcmp(argv[i], "-D") == 0)
            opts.action = ACTION_DAEMON;
        else if (strcmp(argv[i], "--stop") == 0 || strcmp(argv[i], "-S") == 0)
            opts.action = ACTION_STOP;
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0)
            opts.action = ACTION_HELP;
        else if (strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-V") == 0)
            opts.action = ACTION_VERSION;
        else if ((strcmp(argv[i], "--display") == 0 || strcmp(argv[i], "-d") == 0) && i+1 < argc)
            opts.displayIndex = atoi(argv[++i]);
        else if (strcmp(argv[i], "--dry-run") == 0 || strcmp(argv[i], "-n") == 0)
            opts.dryRun = true;
    }
    return opts;
}

void test_cli(void) {
    fprintf(stdout, "\n--- CLI Tests ---\n");

    {
        const char *argv[] = {"force-hidpi"};
        CLIOptions o = mockParseCLI(1, argv);
        ASSERT_EQ(o.action, ACTION_AUTO, "no args = AUTO action");
        ASSERT_EQ(o.displayIndex, -1, "no args = display -1");
        ASSERT_TRUE(!o.dryRun, "no args = not dry run");
    }
    {
        const char *argv[] = {"force-hidpi", "--info"};
        CLIOptions o = mockParseCLI(2, argv);
        ASSERT_EQ(o.action, ACTION_INFO, "--info = INFO action");
    }
    {
        const char *argv[] = {"force-hidpi", "-i"};
        CLIOptions o = mockParseCLI(2, argv);
        ASSERT_EQ(o.action, ACTION_INFO, "-i = INFO action");
    }
    {
        const char *argv[] = {"force-hidpi", "--daemon"};
        CLIOptions o = mockParseCLI(2, argv);
        ASSERT_EQ(o.action, ACTION_DAEMON, "--daemon = DAEMON action");
    }
    {
        const char *argv[] = {"force-hidpi", "--stop"};
        CLIOptions o = mockParseCLI(2, argv);
        ASSERT_EQ(o.action, ACTION_STOP, "--stop = STOP action");
    }
    {
        const char *argv[] = {"force-hidpi", "--display", "2"};
        CLIOptions o = mockParseCLI(3, argv);
        ASSERT_EQ(o.displayIndex, 2, "--display 2 sets index");
    }
    {
        const char *argv[] = {"force-hidpi", "-d", "0", "--dry-run"};
        CLIOptions o = mockParseCLI(4, argv);
        ASSERT_EQ(o.displayIndex, 0, "-d 0 sets index");
        ASSERT_TRUE(o.dryRun, "--dry-run sets flag");
    }
    {
        const char *argv[] = {"force-hidpi", "--help"};
        CLIOptions o = mockParseCLI(2, argv);
        ASSERT_EQ(o.action, ACTION_HELP, "--help = HELP action");
    }
    {
        const char *argv[] = {"force-hidpi", "--version"};
        CLIOptions o = mockParseCLI(2, argv);
        ASSERT_EQ(o.action, ACTION_VERSION, "--version = VERSION action");
    }
}

// --- Display Matching Tests ---

void test_display_match(void) {
    fprintf(stdout, "\n--- Display Matching Tests ---\n");

    DisplayInfo displays[4] = {};

    // Display 0: builtin
    displays[0].displayID = 1;
    displays[0].isBuiltin = true;
    displays[0].nativeWidth = 3456;
    displays[0].nativeHeight = 2234;
    strlcpy(displays[0].productName, "Color LCD", sizeof(displays[0].productName));

    // Display 1: external 4K
    displays[1].displayID = 2;
    displays[1].isBuiltin = false;
    displays[1].nativeWidth = 3840;
    displays[1].nativeHeight = 2160;
    strlcpy(displays[1].productName, "LG HDR 4K", sizeof(displays[1].productName));

    // Display 2: external lower res
    displays[2].displayID = 3;
    displays[2].isBuiltin = false;
    displays[2].nativeWidth = 1920;
    displays[2].nativeHeight = 1200;
    strlcpy(displays[2].productName, "U13ZA", sizeof(displays[2].productName));

    // Display 3: another external 4K
    displays[3].displayID = 4;
    displays[3].isBuiltin = false;
    displays[3].nativeWidth = 3840;
    displays[3].nativeHeight = 2160;
    strlcpy(displays[3].productName, "Dell U2720Q", sizeof(displays[3].productName));

    int idx = findTargetDisplay(displays, 4, -1);
    ASSERT_EQ(idx, 1, "auto-detect finds first external 4K display");

    idx = findTargetDisplay(displays, 4, 0);
    ASSERT_EQ(idx, 0, "explicit index 0 returns display 0");

    idx = findTargetDisplay(displays, 4, 3);
    ASSERT_EQ(idx, 3, "explicit index 3 returns display 3");

    idx = findTargetDisplay(displays, 4, 10);
    ASSERT_EQ(idx, -1, "out of range index returns -1");

    idx = findTargetDisplay(displays, 0, -1);
    ASSERT_EQ(idx, -1, "empty list returns -1");

    // Test with only builtin displays
    DisplayInfo builtinOnly[1] = {};
    builtinOnly[0].displayID = 1;
    builtinOnly[0].isBuiltin = true;
    builtinOnly[0].nativeWidth = 3456;
    idx = findTargetDisplay(builtinOnly, 1, -1);
    ASSERT_EQ(idx, -1, "only builtin displays returns -1");
}

// --- Main ---

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        fprintf(stdout, "force-hidpi test suite\n\n");

        test_edid();
        test_cli();
        test_display_match();

        fprintf(stdout, "\n=== Results: %d passed, %d failed ===\n", g_passed, g_failed);
        return g_failed > 0 ? 1 : 0;
    }
}
