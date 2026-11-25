#pragma once

#include <database/udmf/uds.h>

/* 用不透明对象检查生产代码的分配、传递和清理顺序。 */
typedef struct OH_UdmfData OH_UdmfData;
typedef struct OH_UdmfRecord OH_UdmfRecord;
OH_UdmfData *OH_UdmfData_Create(void);
void OH_UdmfData_Destroy(OH_UdmfData *data);
int OH_UdmfData_AddRecord(OH_UdmfData *data, OH_UdmfRecord *record);
OH_UdmfRecord *OH_UdmfRecord_Create(void);
void OH_UdmfRecord_Destroy(OH_UdmfRecord *record);
int OH_UdmfRecord_AddPlainText(OH_UdmfRecord *record, OH_UdsPlainText *plain);
