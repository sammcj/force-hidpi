// quality.h - Display quality tweaks and colour diagnostics
#ifndef QUALITY_H
#define QUALITY_H

#import <CoreGraphics/CoreGraphics.h>

// Print current quality state for a display
void printQualityInfo(CGDirectDisplayID displayID);

// Apply PQ-to-SDR gamma correction for HDR mode (fixes washed-out look)
bool applyPQGammaCorrection(CGDirectDisplayID displayID);

// Print colour space, ICC profile, and PPI comparison between virtual and physical displays
void printColourDiagnostics(CGDirectDisplayID virtualID, CGDirectDisplayID physicalID);

// Copy the physical display's colour profile to the virtual display.
// Tries SkyLight private API, then ColorSync fallback.
bool matchColourProfile(CGDirectDisplayID physicalID, CGDirectDisplayID virtualID);

// Attempt to force 10-bit compositing on the virtual display.
// Tries SLSSetDisplayOutputMode and SLSConfigureDisplayOutputMode.
bool tryForce10BitCompositing(CGDirectDisplayID displayID);

#endif // QUALITY_H
