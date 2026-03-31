// virtual_display.mm - Create a virtual HiDPI display via SkyLight private API
//
// Compiled without ARC (-fno-objc-arc) because NSInvocation's
// getReturnValue/setArgument for struct and NSError** types are
// incompatible with ARC's retain/release semantics.
#import "virtual_display.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// Module-level storage so destroyVirtualDisplay works from signal handlers
static id sVirtualDisplay = nil;

// Forward declarations
static id tryDictConfig(Class cls, SEL dictSel, NSString *name,
                        uint32_t vendor, uint32_t product, CGSize maxPixels);
static id tryInvocationConfig(Class cls, NSString *name,
                              uint32_t vendor, uint32_t product, CGSize maxPixels);
static CGDirectDisplayID getVirtualDisplayID(id vd);
static bool applySettings(id vd, id settings);

// Create an SLVirtualDisplayMode via dictionary representation
// eotf: 0=SDR (8-bit), 1=PQ (16-bit)
static id createMode(CGSize pixels, CGSize points, double hz, uint32_t eotf) {
    Class cls = NSClassFromString(@"SLVirtualDisplayMode");
    if (!cls) return nil;

    SEL dictSel = NSSelectorFromString(@"modeWithDictionaryRepresentation:");
    if (![cls respondsToSelector:dictSel]) return nil;

    NSDictionary *dict = @{
        @"SLVirtualDisplayModeSizeInPixels": @{
            @"Width": @(pixels.width), @"Height": @(pixels.height)
        },
        @"SLVirtualDisplayModeSizeInPoints": @{
            @"Width": @(points.width), @"Height": @(points.height)
        },
        @"SLVirtualDisplayModeRefreshRate": @(hz),
        @"SLVirtualDisplayModeOptions": @0,
        @"SLVirtualDisplayModeEOTF": @(eotf),
    };

    @try {
        id mode = [cls performSelector:dictSel withObject:dict];
        return mode;
    } @catch (NSException *e) {
        fprintf(stderr, "error: mode creation failed: %s\n", [[e description] UTF8String]);
        return nil;
    }
}

// Create SLVirtualDisplaySettings via NSInvocation
static id createSettings(id nativeMode) {
    Class cls = NSClassFromString(@"SLVirtualDisplaySettings");
    if (!cls || !nativeMode) return nil;

    // Dictionary path is unreliable on macOS 26, use NSInvocation directly
    SEL initSel = NSSelectorFromString(
        @"initWithNativeMode:preferredMode:optionalModes:rotations:error:");
    id instance = [cls alloc];
    NSMethodSignature *sig = [instance methodSignatureForSelector:initSel];
    if (!sig) return nil;

    NSArray *empty = @[];
    NSError *error = nil;
    NSError **errPtr = &error;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:instance];
    [inv setSelector:initSel];
    [inv setArgument:&nativeMode atIndex:2];
    [inv setArgument:&nativeMode atIndex:3];
    [inv setArgument:&empty atIndex:4];
    [inv setArgument:&empty atIndex:5];
    [inv setArgument:&errPtr atIndex:6];
    @try {
        [inv invoke];
        id result = nil;
        [inv getReturnValue:&result];
        if (result) return result;
        if (error) {
            fprintf(stderr, "error: settings init: %s\n",
                    [[error description] UTF8String]);
        }
    } @catch (NSException *e) {
        fprintf(stderr, "error: settings exception: %s\n",
                [[e description] UTF8String]);
    }
    return nil;
}

// Create SLVirtualDisplayConfiguration, dictionary first then NSInvocation
static id createConfig(NSString *name, uint32_t vendor, uint32_t product, CGSize maxPixels) {
    Class cls = NSClassFromString(@"SLVirtualDisplayConfiguration");
    if (!cls) return nil;

    SEL dictSel = NSSelectorFromString(@"configurationWithDictionaryRepresentation:");
    if ([cls respondsToSelector:dictSel]) {
        id config = tryDictConfig(cls, dictSel, name, vendor, product, maxPixels);
        if (config) return config;
    }

    return tryInvocationConfig(cls, name, vendor, product, maxPixels);
}

// Attempt dictionary-based configuration creation
static id tryDictConfig(Class cls, SEL dictSel, NSString *name,
                        uint32_t vendor, uint32_t product, CGSize maxPixels) {
    NSArray *sizeFormats = @[
        @[@{@"Width": @(698.0), @"Height": @(392.0)},
          @{@"Width": @(maxPixels.width), @"Height": @(maxPixels.height)}],
        @[@{@"width": @(698.0), @"height": @(392.0)},
          @{@"width": @(maxPixels.width), @"height": @(maxPixels.height)}],
    ];

    for (NSArray *fmt in sizeFormats) {
        NSDictionary *dict = @{
            @"SLVirtualDisplayConfigurationName": name,
            @"SLVirtualDisplayConfigurationVendorID": @(vendor),
            @"SLVirtualDisplayConfigurationProductID": @(product),
            @"SLVirtualDisplayConfigurationSerialNumber": @(1),
            @"SLVirtualDisplayConfigurationSizeInMillimeters": fmt[0],
            @"SLVirtualDisplayConfigurationMaximumSizeInPixels": fmt[1],
        };
        @try {
            id config = [cls performSelector:dictSel withObject:dict];
            if (config) return config;
        } @catch (NSException *) {
            continue;
        }
    }
    return nil;
}

// NSInvocation-based configuration init
static id tryInvocationConfig(Class cls, NSString *name,
                              uint32_t vendor, uint32_t product, CGSize maxPixels) {
    SEL initSel = NSSelectorFromString(
        @"initWithName:vendorID:productID:serialNumber:"
        @"sizeInMillimeters:maximumSizeInPixels:chromaticities:error:");

    if (![cls instancesRespondToSelector:initSel]) return nil;

    id instance = [cls alloc];
    if (!instance) return nil;

    NSMethodSignature *sig = [instance methodSignatureForSelector:initSel];
    if (!sig) {
        [instance release];
        return nil;
    }

    typedef struct { float w; float h; } SizeF;
    typedef struct { unsigned int w; unsigned int h; } SizeUI;
    typedef struct { SizeF r; SizeF g; SizeF b; SizeF white; } Chrom;

    uint64_t vendor64 = vendor;
    uint64_t product64 = product;
    uint64_t serial64 = 1;
    SizeF sizeMM = {698.0f, 392.0f};
    SizeUI maxPx = {(unsigned int)maxPixels.width, (unsigned int)maxPixels.height};
    Chrom chrom = {
        {0.64f, 0.33f}, {0.30f, 0.60f}, {0.15f, 0.06f}, {0.3127f, 0.3290f}
    };

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:instance];
    [inv setSelector:initSel];
    [inv retainArguments];
    [inv setArgument:&name atIndex:2];
    [inv setArgument:&vendor64 atIndex:3];
    [inv setArgument:&product64 atIndex:4];
    [inv setArgument:&serial64 atIndex:5];
    [inv setArgument:&sizeMM atIndex:6];
    [inv setArgument:&maxPx atIndex:7];
    [inv setArgument:&chrom atIndex:8];
    NSError *error = nil;
    NSError **errPtr = &error;
    [inv setArgument:&errPtr atIndex:9];

    @try {
        [inv invoke];
        id result = nil;
        [inv getReturnValue:&result];
        if (result) return result;
        if (error) {
            fprintf(stderr, "error: config init failed: %s\n",
                    [[error description] UTF8String]);
        }
    } @catch (NSException *e) {
        fprintf(stderr, "error: config exception: %s\n",
                [[e description] UTF8String]);
    }
    return nil;
}

// Retrieve the displayID from an SLVirtualDisplay via NSInvocation
static CGDirectDisplayID getVirtualDisplayID(id vd) {
    SEL sel = NSSelectorFromString(@"displayID");
    NSMethodSignature *sig = [vd methodSignatureForSelector:sel];
    if (!sig) return 0;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:vd];
    [inv setSelector:sel];
    [inv invoke];

    CGDirectDisplayID result = 0;
    [inv getReturnValue:&result];
    return result;
}

// Apply settings to the virtual display
static bool applySettings(id vd, id settings) {
    SEL sel = NSSelectorFromString(@"applySettings:error:");
    NSMethodSignature *sig = [vd methodSignatureForSelector:sel];
    if (!sig) return false;

    NSError *error = nil;
    NSError **errPtr = &error;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:vd];
    [inv setSelector:sel];
    [inv setArgument:&settings atIndex:2];
    [inv setArgument:&errPtr atIndex:3];

    BOOL ok = NO;
    @try {
        [inv invoke];
        [inv getReturnValue:&ok];
    } @catch (NSException *e) {
        fprintf(stderr, "error: applySettings exception: %s\n",
                [[e description] UTF8String]);
        return false;
    }

    if (!ok && error) {
        fprintf(stderr, "error: applySettings: %s\n",
                [[error description] UTF8String]);
    }
    return (bool)ok;
}

CGDirectDisplayID createVirtualHiDPIDisplay(NSString *name, uint32_t vendorID,
                                            uint32_t productID,
                                            uint32_t maxPixelW, uint32_t maxPixelH,
                                            uint32_t pointW, uint32_t pointH,
                                            double hz, uint32_t eotf) {
    @autoreleasepool {
        id mode = createMode(
            CGSizeMake(maxPixelW, maxPixelH),
            CGSizeMake(pointW, pointH), hz, eotf);
        if (!mode) {
            fprintf(stderr, "error: failed to create virtual display mode\n");
            return 0;
        }

        id settings = createSettings(mode);
        if (!settings) {
            fprintf(stderr, "error: failed to create virtual display settings\n");
            return 0;
        }

        id config = createConfig(name, vendorID, productID,
                                 CGSizeMake(maxPixelW, maxPixelH));
        if (!config) {
            fprintf(stderr, "error: failed to create virtual display config\n");
            return 0;
        }

        Class vdClass = NSClassFromString(@"SLVirtualDisplay");
        if (!vdClass) {
            fprintf(stderr, "error: SLVirtualDisplay class not found\n");
            return 0;
        }

        NSError *error = nil;
        NSError **errPtr = &error;
        SEL createSel = NSSelectorFromString(@"initWithConfiguration:error:");
        id vd = [vdClass alloc];
        NSMethodSignature *sig = [vd methodSignatureForSelector:createSel];
        if (!sig) {
            fprintf(stderr, "error: no initWithConfiguration:error: signature\n");
            return 0;
        }

        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:vd];
        [inv setSelector:createSel];
        [inv setArgument:&config atIndex:2];
        [inv setArgument:&errPtr atIndex:3];

        @try {
            [inv invoke];
            [inv getReturnValue:&vd];
        } @catch (NSException *e) {
            fprintf(stderr, "error: display creation: %s\n",
                    [[e description] UTF8String]);
            return 0;
        }

        if (!vd) {
            fprintf(stderr, "error: failed to create virtual display: %s\n",
                    error ? [[error description] UTF8String] : "unknown");
            return 0;
        }

        sVirtualDisplay = [vd retain];

        if (!applySettings(vd, settings)) {
            fprintf(stderr, "warning: failed to apply settings, using defaults\n");
        }

        return getVirtualDisplayID(vd);
    }
}

void destroyVirtualDisplay(void) {
    if (!sVirtualDisplay) return;

    @try {
        [sVirtualDisplay performSelector:NSSelectorFromString(@"destroy")];
    } @catch (NSException *e) {
        fprintf(stderr, "warning: destroy: %s\n", [[e description] UTF8String]);
    }
    [sVirtualDisplay release];
    sVirtualDisplay = nil;
}
