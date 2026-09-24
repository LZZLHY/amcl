/* Stub X11/Xutil.h for headless cross-compilation */
#ifndef _X11_XUTIL_H_
#define _X11_XUTIL_H_

#include <X11/Xlib.h>

/* Region is an opaque pointer to _XRegion */
typedef struct _XRegion *Region;

typedef struct {
    long flags;
    int x, y;
    int width, height;
    int min_width, min_height;
    int max_width, max_height;
    int width_inc, height_inc;
    struct { int x; int y; } min_aspect, max_aspect;
    int base_width, base_height;
    int win_gravity;
} XSizeHints;

typedef struct {
    long flags;
    Bool input;
    int initial_state;
    Pixmap icon_pixmap;
    Window icon_window;
    int icon_x, icon_y;
    Pixmap icon_mask;
    XID window_group;
} XWMHints;

typedef struct {
    unsigned char *value;
    Atom encoding;
    int format;
    unsigned long nitems;
} XTextProperty;

typedef struct {
    Visual *visual;
    VisualID visualid;
    int screen;
    int depth;
    int c_class;
    unsigned long red_mask;
    unsigned long green_mask;
    unsigned long blue_mask;
    int colormap_size;
    int bits_per_rgb;
} XVisualInfo;

#define VisualNoMask 0x0
#define VisualIDMask 0x1
#define VisualScreenMask 0x2
#define VisualDepthMask 0x4
#define VisualClassMask 0x8

#define PSize (1L << 3)
#define PMinSize (1L << 4)
#define PMaxSize (1L << 5)

#define StaticGray 0
#define GrayScale 1
#define StaticColor 2
#define PseudoColor 3
#define TrueColor 4
#define DirectColor 5

#define NormalState 1
#define IconicState 3

#endif /* _X11_XUTIL_H_ */
