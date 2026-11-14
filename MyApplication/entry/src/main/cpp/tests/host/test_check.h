#pragma once
#include <cstdio>
#include <cstdlib>

// 宿主回归必须在发行编译选项下仍执行每个被测表达式，包含启动、关闭和权限操作的副作用。
// 表达式只求值一次；失败保留文件、行号和表达式，随后以非零进程结果终止本用例。
#define AMCL_TEST_CHECK(expression)                                                        \
    do {                                                                                  \
        if (!(expression)) {                                                              \
            std::fprintf(stderr, "%s:%d CHECK failed: %s\n", __FILE__, __LINE__, #expression); \
            std::abort();                                                                 \
        }                                                                                 \
    } while (false)
