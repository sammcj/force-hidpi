// probe_eotf_range.mm - Test what BitsPerSample each EOTF value produces
// Build: clang++ -std=c++17 -ObjC++ -fno-objc-arc -mmacosx-version-min=14.0 -ldl -framework CoreGraphics -framework Foundation -o $TMPDIR/probe_eotf_range tests/probe_eotf_range.mm
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdio.h>
#import <unistd.h>

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
        return [cls performSelector:dictSel withObject:dict];
    } @catch (NSException *e) {
        return nil;
    }
}

static id createSettings(id nativeMode) {
    Class cls = NSClassFromString(@"SLVirtualDisplaySettings");
    if (!cls || !nativeMode) return nil;

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
        return result;
    } @catch (NSException *e) {
        return nil;
    }
}

// NSInvocation-based config creation (dictionary path fails on macOS 26)
static id createConfig(NSString *name, CGSize maxPixels) {
    Class cls = NSClassFromString(@"SLVirtualDisplayConfiguration");
    if (!cls) return nil;

    SEL initSel = NSSelectorFromString(
        @"initWithName:vendorID:productID:serialNumber:"
        @"sizeInMillimeters:maximumSizeInPixels:chromaticities:error:");
    if (![cls instancesRespondToSelector:initSel]) {
        fprintf(stderr, "  No initWithName:... selector\n");
        return nil;
    }

    id instance = [cls alloc];
    NSMethodSignature *sig = [instance methodSignatureForSelector:initSel];
    if (!sig) return nil;

    typedef struct { float w; float h; } SizeF;
    typedef struct { unsigned int w; unsigned int h; } SizeUI;
    typedef struct { SizeF r; SizeF g; SizeF b; SizeF white; } Chrom;

    uint64_t vendor64 = 0x1e6d;
    uint64_t product64 = 0x9999;
    uint64_t serial64 = 1;
    SizeF sizeMM = {698.0f, 392.0f};
    SizeUI maxPx = {(unsigned int)maxPixels.width, (unsigned int)maxPixels.height};
    Chrom chrom = {
        {0.64f, 0.33f}, {0.30f, 0.60f}, {0.15f, 0.06f}, {0.3127f, 0.3290f}
    };

    id inst = [cls alloc];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:inst];
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
            fprintf(stderr, "  Config error: %s\n", [[error description] UTF8String]);
        }
    } @catch (NSException *e) {
        fprintf(stderr, "  Config exception: %s\n", [[e description] UTF8String]);
    }
    return nil;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        void *sl = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW);
        if (!sl) { fprintf(stderr, "No SkyLight\n"); return 1; }

        typedef uint32_t (*GetBPS)(CGDirectDisplayID);
        typedef uint32_t (*GetBPP)(CGDirectDisplayID);
        auto getBPS = (GetBPS)dlsym(sl, "SLDisplayBitsPerSample");
        auto getBPP = (GetBPP)dlsym(sl, "SLDisplayBitsPerPixel");

        // Test EOTF values 0..5
        for (uint32_t eotf = 0; eotf <= 5; eotf++) {
            fprintf(stdout, "\n=== EOTF=%u ===\n", eotf);
            fflush(stdout);

            id mode = createMode(CGSizeMake(7680, 4320), CGSizeMake(3840, 2160), 60.0, eotf);
            if (!mode) {
                fprintf(stdout, "  Mode creation failed\n");
                continue;
            }
            fprintf(stdout, "  Mode: OK\n");

            id settings = createSettings(mode);
            if (!settings) {
                fprintf(stdout, "  Settings creation failed\n");
                continue;
            }
            fprintf(stdout, "  Settings: OK\n");

            id config = createConfig(
                [NSString stringWithFormat:@"eotf-test-%u", eotf],
                CGSizeMake(7680, 4320));
            if (!config) {
                fprintf(stdout, "  Config creation failed\n");
                continue;
            }
            fprintf(stdout, "  Config: OK\n");

            Class vdClass = NSClassFromString(@"SLVirtualDisplay");
            NSError *error = nil;
            NSError **errPtr = &error;
            SEL createSel = NSSelectorFromString(@"initWithConfiguration:error:");
            id vd = [vdClass alloc];
            NSMethodSignature *sig = [vd methodSignatureForSelector:createSel];
            if (!sig) { fprintf(stdout, "  No init sig\n"); continue; }

            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:vd];
            [inv setSelector:createSel];
            [inv setArgument:&config atIndex:2];
            [inv setArgument:&errPtr atIndex:3];

            @try {
                [inv invoke];
                [inv getReturnValue:&vd];
            } @catch (NSException *e) {
                fprintf(stdout, "  Create exception: %s\n", [[e description] UTF8String]);
                continue;
            }

            if (!vd) {
                fprintf(stdout, "  Display creation returned nil: %s\n",
                        error ? [[error description] UTF8String] : "unknown");
                continue;
            }

            // Apply settings
            SEL applySel = NSSelectorFromString(@"applySettings:error:");
            NSMethodSignature *applySig = [vd methodSignatureForSelector:applySel];
            if (applySig) {
                NSError *applyErr = nil;
                NSError **applyErrPtr = &applyErr;
                NSInvocation *applyInv = [NSInvocation invocationWithMethodSignature:applySig];
                [applyInv setTarget:vd];
                [applyInv setSelector:applySel];
                [applyInv setArgument:&settings atIndex:2];
                [applyInv setArgument:&applyErrPtr atIndex:3];
                BOOL ok = NO;
                @try {
                    [applyInv invoke];
                    [applyInv getReturnValue:&ok];
                } @catch (NSException *) {}
                fprintf(stdout, "  applySettings: %s\n", ok ? "OK" : "FAILED");
            }

            // Get display ID
            SEL didSel = NSSelectorFromString(@"displayID");
            NSMethodSignature *didSig = [vd methodSignatureForSelector:didSel];
            CGDirectDisplayID did = 0;
            if (didSig) {
                NSInvocation *didInv = [NSInvocation invocationWithMethodSignature:didSig];
                [didInv setTarget:vd];
                [didInv setSelector:didSel];
                [didInv invoke];
                [didInv getReturnValue:&did];
            }

            // Wait for it to appear
            usleep(2000000);

            fprintf(stdout, "  DisplayID: 0x%x\n", did);
            if (getBPS) fprintf(stdout, "  BitsPerSample: %u\n", getBPS(did));
            if (getBPP) fprintf(stdout, "  BitsPerPixel:  %u\n", getBPP(did));

            // Pixel encoding
            CGDisplayModeRef cgMode = CGDisplayCopyDisplayMode(did);
            if (cgMode) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                CFStringRef enc = CGDisplayModeCopyPixelEncoding(cgMode);
                #pragma clang diagnostic pop
                if (enc) {
                    fprintf(stdout, "  PixelEncoding:  %s\n",
                            [(__bridge NSString *)enc UTF8String]);
                    CFRelease(enc);
                }
                CGDisplayModeRelease(cgMode);
            }

            // Destroy
            @try {
                [vd performSelector:NSSelectorFromString(@"destroy")];
            } @catch (NSException *) {}

            usleep(500000);
        }

        fprintf(stdout, "\nDone.\n");
        return 0;
    }
}
