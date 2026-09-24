/* Stub X11/extensions/XShm.h for headless cross-compilation */
#ifndef _X11_EXTENSIONS_XSHM_H_
#define _X11_EXTENSIONS_XSHM_H_

#include <X11/Xlib.h>

typedef unsigned long ShmSeg;

typedef struct {
    ShmSeg shmseg;
    int shmid;
    char *shmaddr;
    Bool readOnly;
} XShmSegmentInfo;

#endif /* _X11_EXTENSIONS_XSHM_H_ */
