#pragma once

/* 替代系统纯文本记录，测试可检查复制进来的 UTF-8 字节。 */
typedef struct OH_UdsPlainText OH_UdsPlainText;
OH_UdsPlainText *OH_UdsPlainText_Create(void);
void OH_UdsPlainText_Destroy(OH_UdsPlainText *plain);
int OH_UdsPlainText_SetContent(OH_UdsPlainText *plain, const char *text);
