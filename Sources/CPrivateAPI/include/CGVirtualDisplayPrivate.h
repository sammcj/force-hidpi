// CGVirtualDisplayPrivate.h - Forward declarations for CoreGraphics private API
// These classes exist in CoreGraphics.framework but aren't in public headers.
// Used by DisplayLink and other hardware vendors (semi-public, stable API).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>

// IOAVService - private IOKit API for DDC/CI over I2C on Apple Silicon.
// Replaces the Intel-era IOFramebufferService path. Resolved by the dynamic
// linker against the IOKit framework; no dlopen required.
typedef CFTypeRef IOAVService;
extern IOAVService _Nullable IOAVServiceCreateWithService(CFAllocatorRef _Nullable allocator, io_service_t service);
extern IOReturn IOAVServiceWriteI2C(IOAVService service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);

// CoreDisplay helpers used to correlate a CGDirectDisplayID with an IORegistry entry.
extern CFDictionaryRef _Nullable CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h
                  refreshRate:(double)hz;
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h
                  refreshRate:(double)hz transferFunction:(unsigned int)tf;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNumber;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (retain, nonatomic) dispatch_queue_t queue;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic) unsigned int rotation;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)desc;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
