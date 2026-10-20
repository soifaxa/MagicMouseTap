#ifndef MultitouchSupport_h
#define MultitouchSupport_h

#import <CoreFoundation/CoreFoundation.h>

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;
    uint32_t state;
    int32_t fingerID;
    int32_t handID;
    MTVector normalized;
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;
    int32_t field14;
    int32_t field15;
    float zDensity;
} MTTouch;

typedef void *MTDeviceRef;
typedef void (*MTContactCallbackFunction)(
    MTDeviceRef device,
    MTTouch *touches,
    int numTouches,
    double timestamp,
    int frame
);

CFArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTUnregisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
OSStatus MTDeviceStart(MTDeviceRef, int);
OSStatus MTDeviceStop(MTDeviceRef);
bool MTDeviceIsBuiltIn(MTDeviceRef);

#endif /* MultitouchSupport_h */
