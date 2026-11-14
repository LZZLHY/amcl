/* 仅用于实际 SDK AArch64 ELF 门禁夹具：DAUDIO 实现完整编入，JNI/格式回调的符号锚
 * 不执行 Java。该 .so 只能授予产物结构资格，不能冒充完整 JDK 或设备音频通过。 */
#include "DirectAudio.h"
void Java_com_sun_media_sound_DirectAudioDevice_nOpen(void) {}
void DAUDIO_AddAudioFormat(void *creator, int bits, int frame, int channels, float rate,
                          int encoding, int sign, int endian)
{
    (void)creator; (void)bits; (void)frame; (void)channels;
    (void)rate; (void)encoding; (void)sign; (void)endian;
}
