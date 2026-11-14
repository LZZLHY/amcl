/* 真实SDK规定Flush后呈现位置归零，但FramesWritten仍为创建后的累计写入。
 * 保存原完整OHAudio替身作基座，只覆盖这两个接口的坐标关系，驱动实际DAUDIO入口。
 * 旧0025应精确返回77并报告第二段位置停在第一段末尾，不能用任意崩溃作为负例。 */
#define amcl_test_run amcl_previous_backend_matrix
#include "daudio_backend_test.c"
#undef amcl_test_run

int amcl_position_test(void)
{
    unsigned char pcm[16], output[32];
    void *line;
    INT64 position;
    memset(pcm, 0x21, sizeof(pcm));
    line = open_line(); assert(line && DAUDIO_Start(line, TRUE));
    assert(DAUDIO_Write(line, (char *)pcm, 16) == 16 && pump(current, output, 16) == 16);
    present(current);
    assert(DAUDIO_GetBytePosition(line, TRUE, 16) == 16 && !DAUDIO_StillDraining(line, TRUE));
    assert(DAUDIO_Flush(line, TRUE));
    assert(current->positionOrigin == 4 && current->written == 4);
    assert(DAUDIO_Write(line, (char *)pcm, 8) == 8 && pump(current, output, 8) == 8);
    present(current);
    position = DAUDIO_GetBytePosition(line, TRUE, 24);
    if (position == 16 && DAUDIO_StillDraining(line, TRUE)) {
        DAUDIO_Close(line, TRUE); clean();
        puts("EXPECTED-OLD-FLUSH-DEFECT: cumulative FramesWritten treated as reset presentation origin; expected24 actual16");
        return 77;
    }
    assert(position == 24 && !DAUDIO_StillDraining(line, TRUE));
    DAUDIO_Close(line, TRUE); clean();
    /* 真实尾部延迟模型：只提交用户4帧时系统报告0；实际再提交4帧静音才报告4。
     * 下一段用户位于平台[8,10)，在前面的[4,8)静音空隙中绝不能提前增长。 */
    line = open_line(); assert(line && DAUDIO_Start(line, TRUE));
    assert(DAUDIO_Write(line, (char *)pcm, 16) == 16 && pump(current, output, 16) == 16);
    assert(DAUDIO_GetBytePosition(line, TRUE, 16) == 0 && DAUDIO_StillDraining(line, TRUE));
    memset(output, 0xAA, sizeof(output));
    assert(pump(current, output, 16) == 16);
    for (int i = 0; i < 16; ++i) assert(output[i] == 0);
    __atomic_store_n(&current->presented, 4, __ATOMIC_SEQ_CST);
    assert(DAUDIO_GetBytePosition(line, TRUE, 16) == 16 && !DAUDIO_StillDraining(line, TRUE));
    assert(pump(current, output, 16) == 0); /* 已实际越过用户结束，静音必须停止。 */
    assert(DAUDIO_Write(line, (char *)pcm, 8) == 8 && pump(current, output, 8) == 8);
    __atomic_store_n(&current->presented, 6, __ATOMIC_SEQ_CST);
    assert(DAUDIO_GetBytePosition(line, TRUE, 24) == 16 && DAUDIO_StillDraining(line, TRUE));
    __atomic_store_n(&current->presented, 9, __ATOMIC_SEQ_CST);
    assert(DAUDIO_GetBytePosition(line, TRUE, 24) == 20);
    __atomic_store_n(&current->presented, 10, __ATOMIC_SEQ_CST);
    assert(DAUDIO_GetBytePosition(line, TRUE, 24) == 24 && !DAUDIO_StillDraining(line, TRUE));
    assert(DAUDIO_Stop(line, TRUE));
    assert(DAUDIO_GetBytePosition(line, TRUE, 24) == 24 && !AMCL_DAudio_GetError(line));
    DAUDIO_Close(line, TRUE); clean();
    /* 时间前进伴随frame短暂回退并不能证明新epoch；自动加旧frame会把8用户字节误报12。 */
    line = open_line(); assert(line && DAUDIO_Start(line, TRUE));
    assert(DAUDIO_Write(line, (char *)pcm, 16) == 16 && pump(current, output, 16) == 16);
    __atomic_store_n(&current->presented, 2, __ATOMIC_SEQ_CST);
    assert(DAUDIO_GetBytePosition(line, TRUE, 16) == 8);
    __atomic_store_n(&current->presented, 1, __ATOMIC_SEQ_CST);
    __atomic_store_n(&reportedTimestamp, INT64_C(2000000), __ATOMIC_SEQ_CST);
    position = DAUDIO_GetBytePosition(line, TRUE, 16);
    if (position == 12) {
        DAUDIO_Close(line, TRUE); clean();
        puts("EXPECTED-AUTO-REBASE-DEFECT: ambiguous frame regression advanced user bytes from8 to12");
        return 78;
    }
    assert(position == 8 && !AMCL_DAudio_GetError(line));
    __atomic_store_n(&current->presented, 4, __ATOMIC_SEQ_CST);
    assert(DAUDIO_GetBytePosition(line, TRUE, 16) == 16);
    DAUDIO_Close(line, TRUE); clean();
    puts("PASS real Flush reset coordinate with cumulative FramesWritten, subsequent data and drain");
    puts("PASS actual tail silence with zero user-count growth; later user excluded during gap; silence stops after real presentation; paused query uses confirmed cache");
    puts("PASS ambiguous clock regression preserves confirmed lower bound without invented origin");
    return 0;
}
