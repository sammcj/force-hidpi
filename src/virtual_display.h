// virtual_display.h - Virtual HiDPI display creation via SkyLight
#ifndef VIRTUAL_DISPLAY_H
#define VIRTUAL_DISPLAY_H

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// Returns the CGDirectDisplayID of the created virtual display, or 0 on failure.
// eotf: 0 = SDR (8-bit), 1 = PQ/HDR10 (16-bit, needs gamma correction)
CGDirectDisplayID createVirtualHiDPIDisplay(NSString *name, uint32_t vendorID, uint32_t productID,
                                            uint32_t maxPixelW, uint32_t maxPixelH,
                                            uint32_t pointW, uint32_t pointH,
                                            double hz, uint32_t eotf);
void destroyVirtualDisplay(void);

#endif // VIRTUAL_DISPLAY_H
