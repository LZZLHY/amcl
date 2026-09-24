/* Stub X11/Xlib.h for headless cross-compilation */
#ifndef _X11_XLIB_H_
#define _X11_XLIB_H_

#include <X11/X.h>
#include <stddef.h>

typedef struct _XDisplay Display;
typedef struct _XGC *GC;
typedef struct _XImage XImage;
typedef struct _XEvent XEvent;

typedef struct {
    short x, y;
    unsigned short width, height;
} XRectangle;

typedef struct {
    short x, y;
} XPoint;

typedef struct {
    Pixmap pixel;
    unsigned short red, green, blue;
    char flags;
    char pad;
} XColor;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
} XAnyEvent;

typedef struct {
    int depth;
    int bits_per_pixel;
    int scanline_pad;
} XPixmapFormatValues;

typedef struct {
    VisualID visualid;
    int screen_class;
    unsigned long red_mask, green_mask, blue_mask;
    int bits_per_rgb;
    int map_entries;
} Visual;

typedef struct {
    int depth;
    int nvisuals;
    Visual *visuals;
} Depth;

typedef struct {
    int width, height;
    int mwidth, mheight;
    int ndepths;
    Depth *depths;
    int root_depth;
    Visual *root_visual;
    GC default_gc;
    Colormap cmap;
    unsigned long white_pixel;
    unsigned long black_pixel;
} Screen;

struct _XImage {
    int width, height;
    int xoffset;
    int format;
    char *data;
    int byte_order;
    int bitmap_unit;
    int bitmap_bit_order;
    int bitmap_pad;
    int depth;
    int bytes_per_line;
    int bits_per_pixel;
    unsigned long red_mask;
    unsigned long green_mask;
    unsigned long blue_mask;
    char *obdata;
    struct funcs {
        struct _XImage *(*create_image)();
        int (*destroy_image)(struct _XImage *);
        unsigned long (*get_pixel)(struct _XImage *, int, int);
        int (*put_pixel)(struct _XImage *, int, int, unsigned long);
        struct _XImage *(*sub_image)();
        int (*add_pixel)(struct _XImage *, long);
    } f;
};

/* Minimal function stubs - these won't be called in headless mode */
#define DefaultScreen(dpy) 0
#define ScreenOfDisplay(dpy, scr) ((Screen*)NULL)
#define DisplayWidth(dpy, scr) 0
#define DisplayHeight(dpy, scr) 0
#define DefaultVisual(dpy, scr) ((Visual*)NULL)
#define DefaultColormap(dpy, scr) ((Colormap)0)
#define DefaultDepth(dpy, scr) 0
#define DefaultGC(dpy, scr) ((GC)NULL)
#define BlackPixel(dpy, scr) 0L
#define WhitePixel(dpy, scr) 0L
#define RootWindow(dpy, scr) ((Window)0)
#define XFree(p) (0)
#define ConnectionNumber(dpy) 0

#endif /* _X11_XLIB_H_ */
