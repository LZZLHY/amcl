#include "system_clipboard.h"

#include <database/pasteboard/oh_pasteboard.h>
#include <database/udmf/udmf.h>
#include <database/udmf/uds.h>
#include <cstring>

namespace amcl::clipboard {
int32_t WritePlainText(const char* text) {
    // 沿用桌面端纯文本大小边界，为每次复制创建并释放独立的系统对象。
    if (!text || std::strlen(text) > 4 * 1024 * 1024) return -1;
    OH_Pasteboard* board = OH_Pasteboard_Create();
    OH_UdmfData* data = OH_UdmfData_Create();
    OH_UdmfRecord* record = OH_UdmfRecord_Create();
    OH_UdsPlainText* plain = OH_UdsPlainText_Create();
    int32_t result = -1;
    if (board && data && record && plain && OH_UdsPlainText_SetContent(plain, text) == 0 &&
        OH_UdmfRecord_AddPlainText(record, plain) == 0 && OH_UdmfData_AddRecord(data, record) == 0) {
        result = OH_Pasteboard_SetData(board, data);
    }
    if (plain) OH_UdsPlainText_Destroy(plain);
    if (record) OH_UdmfRecord_Destroy(record);
    if (data) OH_UdmfData_Destroy(data);
    if (board) OH_Pasteboard_Destroy(board);
    return result;
}
}
