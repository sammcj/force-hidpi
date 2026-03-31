// display_info.h - Display enumeration and info for force-hidpi
#ifndef DISPLAY_INFO_H
#define DISPLAY_INFO_H

#import <CoreGraphics/CoreGraphics.h>
#import <stdbool.h>
#import <stdint.h>

typedef struct {
    CGDirectDisplayID displayID;
    uint32_t vendorID;
    uint32_t productID;
    uint32_t nativeWidth;
    uint32_t nativeHeight;
    double refreshRate;
    bool isBuiltin;
    bool isMirrored;
    char productName[64];
    // DCP pipe budget info
    uint32_t maxVideoSrcDownscalingWidth;
    int32_t maxSrcRectWidthForPipe[4];
    int32_t maxSrcRectHeightForPipe[4];
    uint32_t maxSrcBufferWidth;
    uint32_t maxSrcBufferHeight;
    uint32_t pipeIDs[4];
    uint32_t pipeCount;
    uint32_t maxW;
    uint32_t maxH;
    uint32_t maxBpc;
    uint64_t maxActivePixelRate;
    // Scale info
    float currentScale;
    uint32_t currentPixelWidth;
    uint32_t currentPixelHeight;
    int bitsPerSample;
} DisplayInfo;

bool loadSkyLight(void);
int enumerateDisplays(DisplayInfo *out, int maxCount);
int findTargetDisplay(DisplayInfo *displays, int count, int requestedIndex);
void printDisplayInfo(const DisplayInfo *info);
void printAllDisplayInfo(DisplayInfo *displays, int count);

#endif // DISPLAY_INFO_H
