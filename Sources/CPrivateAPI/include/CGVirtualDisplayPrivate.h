// CGVirtualDisplayPrivate.h - Forward declarations for CoreGraphics private API
// These classes exist in CoreGraphics.framework but aren't in public headers.
// Used by DisplayLink and other hardware vendors (semi-public, stable API).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

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
