/* 把后端作为真实 DSO 装载；测试代码租约不能由 executable 的假 NOLOAD 成功替代。 */
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv)
{
    void *image;
    int (*run)(void);
    assert(argc == 2);
    image = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!image) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    run = (int (*)(void))dlsym(image, "amcl_test_run");
    assert(run && run() == 0);
    assert(dlclose(image) == 0);
    /* 测试最后故意让系统 Release 失败，必须仍保留真实代码引用。 */
    image = dlopen(argv[1], RTLD_NOW | RTLD_NOLOAD);
    assert(image);
    assert(dlclose(image) == 0);
    puts("PASS DAUDIO callback image remains loaded after failed platform Release");
    return 0;
}
