/* AMCL 自有 OHOS JavaSound 扩展；不改变上游 DAUDIO 或公开 Java 方法的签名。 */
#ifndef AMCL_OHOS_DAUDIO_H
#define AMCL_OHOS_DAUDIO_H

/* 返回该 line 首个真实平台错误；0 表示尚无错误。调用方须持有 Java lockNative。 */
int AMCL_DAudio_GetError(void *id);

/* 只供位置/available这类查询报告尚未交给Java的首错；写/读/drain仍可重复报告永久失败。
 * Mark只在JNI已持有待传播异常时调用，防止“观察错误”本身吞掉失败。 */
int AMCL_DAudio_GetPendingError(void *id);
void AMCL_DAudio_MarkErrorReported(void *id);

/* 清理本条 line 后返回本次 Release/退出等待错误；成功返回0，id已无效不可再次使用。
 * 原 DAUDIO_Close void ABI 保留，OHOS JNI 专用此入口在释放 wrapper 后报告未受检异常。 */
int AMCL_DAudio_Close(void *id);

#endif
