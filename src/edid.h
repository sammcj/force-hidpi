// edid.h - EDID parsing and retrieval for display identification
#ifndef EDID_H
#define EDID_H

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <stdbool.h>
#import <stdint.h>

bool parseEDIDVendorProduct(const uint8_t *edid, size_t len, uint32_t *vendor, uint32_t *product);
bool parseEDIDNativeResolution(const uint8_t *edid, size_t len, uint32_t *width, uint32_t *height);
bool parseEDIDProductName(const uint8_t *edid, size_t len, char *name, size_t nameLen);
NSData *getDisplayEDID(CGDirectDisplayID displayID);

#endif // EDID_H
