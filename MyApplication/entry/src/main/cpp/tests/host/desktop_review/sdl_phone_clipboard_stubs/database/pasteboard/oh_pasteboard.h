#pragma once

#include <database/udmf/udmf.h>

/* 宿主没有系统剪贴板服务，由测试驱动该 NDK 调用的回执。 */
typedef struct OH_Pasteboard OH_Pasteboard;
OH_Pasteboard *OH_Pasteboard_Create(void);
void OH_Pasteboard_Destroy(OH_Pasteboard *board);
int OH_Pasteboard_SetData(OH_Pasteboard *board, OH_UdmfData *data);
