/* Stub X11/extensions/Xrender.h for headless cross-compilation */
#ifndef _X11_EXTENSIONS_XRENDER_H_
#define _X11_EXTENSIONS_XRENDER_H_

#include <X11/Xlib.h>
#include <X11/Xutil.h>

typedef unsigned long Glyph;
typedef unsigned long GlyphSet;
typedef unsigned long Picture;
typedef unsigned long PictFormat;

typedef struct {
    short red;
    short redMask;
    short green;
    short greenMask;
    short blue;
    short blueMask;
    short alpha;
    short alphaMask;
} XRenderDirectFormat;

typedef struct {
    PictFormat id;
    int type;
    int depth;
    XRenderDirectFormat direct;
    Colormap colormap;
} XRenderPictFormat;

typedef struct {
    unsigned short red;
    unsigned short green;
    unsigned short blue;
    unsigned short alpha;
} XRenderColor;

typedef struct {
    Glyph glyph;
    unsigned short width, height;
    short x, y;
    short xOff, yOff;
} XGlyphInfo;

typedef struct _XTransform {
    int matrix[3][3];
} XTransform;

#define PictFormatID (1 << 0)
#define PictFormatType (1 << 1)
#define PictFormatDepth (1 << 2)
#define PictFormatRed (1 << 3)
#define PictFormatRedMask (1 << 4)
#define PictFormatGreen (1 << 5)
#define PictFormatGreenMask (1 << 6)
#define PictFormatBlue (1 << 7)
#define PictFormatBlueMask (1 << 8)
#define PictFormatAlpha (1 << 9)
#define PictFormatAlphaMask (1 << 10)
#define PictFormatColormap (1 << 11)

#define PictTypeIndexed 0
#define PictTypeDirect 1

#define PictStandardARGB32 0
#define PictStandardRGB24 1
#define PictStandardA8 2
#define PictStandardA4 3
#define PictStandardA1 4

#define PictOpSrc 1
#define PictOpOver 3

#define CPRepeat (1 << 0)
#define CPSubwindowMode (1 << 8)

#define RepeatNone 0
#define RepeatNormal 1
#define RepeatPad 2
#define RepeatReflect 3

#endif /* _X11_EXTENSIONS_XRENDER_H_ */
