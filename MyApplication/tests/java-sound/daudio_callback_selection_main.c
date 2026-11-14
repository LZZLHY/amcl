/* 每个失败变体使用独立进程和真实DSO，避免全局dl缓存掩盖缺失getter或错位回调。 */
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "../../entry/src/main/cpp/audio/audio_runtime.h"
#include <ohaudio/native_audiostreambuilder.h>
int32_t amcl_foreign_render_data(OH_AudioRenderer *renderer, void *opaque, void *data, int32_t size)
{ (void)renderer; (void)opaque; (void)data; (void)size; return 0; }
int main(int argc, char **argv)
{
    void *host, *image, *held;
    int (*run)(int);
    int accepted;
    assert(argc == 4 || argc == 5); accepted = atoi(argv[3]);
    /* 用旧R12实际控制层证明新宿主拒绝旁路；不借新版后端的env检查伪造此反例。 */
    if (argc == 5) assert(setenv(AMCL_AUDIO_HOST_ENV, "published-but-inactive", 1) == 0);
    host = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
    image = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    if (!host || !image) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    run = (int (*)(int))dlsym(image, "amcl_selection_test");
    assert(run && run(accepted) == 0);
    assert(!dlclose(image) && !dlclose(host));
    held = dlopen(argv[1], RTLD_NOW | RTLD_NOLOAD);
    if (accepted) {
        assert(held); dlclose(held);
        held = dlopen(argv[2], RTLD_NOW | RTLD_NOLOAD);
        assert(held); dlclose(held);
        puts("PASS failed platform Release retains both host callback and JNI code images");
    } else {
        assert(!held);
        held = dlopen(argv[2], RTLD_NOW | RTLD_NOLOAD);
        assert(!held);
        puts("PASS rejected callback selection leaves no host/JNI lease");
    }
    return 0;
}
