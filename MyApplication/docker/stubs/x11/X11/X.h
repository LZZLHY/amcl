/* Stub X11/X.h for headless cross-compilation */
#ifndef _X11_X_H_
#define _X11_X_H_

typedef unsigned long XID;
typedef unsigned long Mask;
typedef unsigned long Atom;
typedef unsigned long VisualID;
typedef unsigned long Time;
typedef XID Window;
typedef XID Drawable;
typedef XID Font;
typedef XID Pixmap;
typedef XID Cursor;
typedef XID Colormap;
typedef XID GContext;
typedef XID KeySym;
typedef unsigned char KeyCode;
typedef int Bool;
typedef int Status;

#define None 0L
#define True 1
#define False 0
#define AllocNone 0
#define AllocAll 1
#define InputOutput 1
#define InputOnly 2
#define CopyFromParent 0L
#define NoEventMask 0L
#define KeyPressMask (1L<<0)
#define KeyReleaseMask (1L<<1)
#define ButtonPressMask (1L<<2)
#define ButtonReleaseMask (1L<<3)
#define ExposureMask (1L<<15)
#define StructureNotifyMask (1L<<17)
#define FocusChangeMask (1L<<21)
#define GCFunction (1L<<0)
#define GCForeground (1L<<2)
#define GCBackground (1L<<3)
#define GXcopy 0x3
#define GXxor 0x6
#define ZPixmap 2
#define LSBFirst 0
#define MSBFirst 1

#endif /* _X11_X_H_ */
