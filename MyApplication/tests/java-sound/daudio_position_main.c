/* 原版反例与修复版共用的真实DSO入口，直接保留被测断言/退出码，不制造PASS。 */
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv)
{
    void *image;
    int (*run)(void), result;
    if (argc != 2) return 2;
    image = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!image) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    run = (int (*)(void))dlsym(image, "amcl_position_test");
    if (!run) return 2;
    result = run();
    if (dlclose(image)) return 2;
    return result;
}
