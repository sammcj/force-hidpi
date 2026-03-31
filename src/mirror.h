// mirror.h - Display mirroring configuration
#ifndef MIRROR_H
#define MIRROR_H

#import <CoreGraphics/CoreGraphics.h>
#import <stdbool.h>

bool configureMirror(CGDirectDisplayID sourceDisplay, CGDirectDisplayID targetDisplay);
bool unconfigureMirror(CGDirectDisplayID targetDisplay);
bool waitForDisplay(CGDirectDisplayID displayID, double timeoutSecs);

#endif // MIRROR_H
