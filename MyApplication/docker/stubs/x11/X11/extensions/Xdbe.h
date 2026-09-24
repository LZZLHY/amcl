/* Stub X11/extensions/Xdbe.h for headless cross-compilation */
#ifndef _X11_EXTENSIONS_XDBE_H_
#define _X11_EXTENSIONS_XDBE_H_

#include <X11/Xlib.h>

typedef Drawable XdbeBackBuffer;

typedef struct {
    Window window;
    XdbeBackBuffer buffer;
} XdbeBackBufferAttributes;

typedef struct {
    VisualID visual;
    int depth;
    int perflevel;
} XdbeVisualInfo;

typedef struct {
    int count;
    XdbeVisualInfo *visinfo;
} XdbeScreenVisualInfo;

#define XdbeUndefined 0
#define XdbeBackground 1
#define XdbeUntouched 2
#define XdbeCopied 3

typedef struct {
    Window swap_window;
    int swap_action;
} XdbeSwapInfo;

#endif
