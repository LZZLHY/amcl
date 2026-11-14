/* 固定0025/r16-r17实验基线：只返回用户PCM，耗尽后返回0。仅供TestHooks因果
 * 对照，不是可选生产后端；保留此输入可复现实测旧时间戳停滞，不能随0028改变基线。 */
#ifndef AMCL_TIMING_ZERO_RETURN_REFERENCE_H
#define AMCL_TIMING_ZERO_RETURN_REFERENCE_H
static inline int32_t amcl_timing_zero_return_reference(OH_AudioRenderer *renderer, void *opaque, void *data, int32_t byteSize)
{
    AmclCallback *ctx = (AmclCallback *)opaque;
    AmclLine *line = enter_callback(ctx);
    int bytes = 0, expected = 0;
    (void)renderer;
    if (line && data && byteSize > 0 &&
        __atomic_load_n(&line->copyEnabled, __ATOMIC_SEQ_CST) &&
        !__atomic_load_n(&line->error, __ATOMIC_SEQ_CST) &&
        __atomic_load_n(&line->interrupt, __ATOMIC_SEQ_CST) != AUDIOSTREAM_INTERRUPT_HINT_PAUSE &&
        __atomic_compare_exchange_n(&line->copyBusy, &expected, 1, 0,
                                    __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
        const uint64_t read = __atomic_load_n(&line->read, __ATOMIC_RELAXED);
        const uint64_t written = __atomic_load_n(&line->written, __ATOMIC_ACQUIRE);
        const uint64_t available = written - read;
        int limit = byteSize - byteSize % line->frameSize;
        bytes = available < (uint64_t)limit ? (int)available : limit;
        if (bytes) {
            const int offset = (int)(read % (uint64_t)line->capacity);
            int first = line->capacity - offset;
            if (first > bytes) first = bytes;
            memcpy(data, line->ring + offset, (size_t)first);
            if (first < bytes) memcpy((char *)data + first, line->ring, (size_t)(bytes - first));
            /* 一个计数同时代表已消费和待平台呈现，避免读取两个原子造成重复/遗漏计数。 */
            __atomic_store_n(&line->read, read + (uint64_t)bytes, __ATOMIC_RELEASE);
        }
        __atomic_store_n(&line->copyBusy, 0, __ATOMIC_RELEASE);
    }
    leave_callback(ctx);
    return bytes;
}

#endif
