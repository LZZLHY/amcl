/* Stub X11/extensions/Xrandr.h for headless cross-compilation */
#ifndef _X11_EXTENSIONS_XRANDR_H_
#define _X11_EXTENSIONS_XRANDR_H_

#include <X11/Xlib.h>
#include <X11/extensions/Xrender.h>

typedef XID RROutput;
typedef XID RRCrtc;
typedef XID RRMode;
typedef unsigned short Rotation;
typedef unsigned short SizeID;
typedef unsigned short SubpixelOrder;
typedef unsigned short Connection;

typedef struct {
    int width, height;
    int mwidth, mheight;
} XRRScreenSize;

typedef struct _XRRScreenConfiguration XRRScreenConfiguration;
typedef struct _XRRScreenResources XRRScreenResources;
typedef struct _XRROutputInfo XRROutputInfo;
typedef struct _XRRCrtcInfo XRRCrtcInfo;

#define RR_Rotate_0 1
#define RR_Connected 0
#define RR_Disconnected 1

#endif
