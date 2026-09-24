#pragma once

#include <cstdlib>
#include <iostream>

/**
 * 宿主回归统一使用始终求值的检查：发布优化不能删掉驱动调用、管道同步或资源回收。
 * 条件只求值一次；失败时输出原表达式、源文件和行号，并以非零状态终止当前测试进程。
 * 它只供宿主测试使用，不参与产品错误处理；子进程失败仍由父进程的退出状态检查识别。
 */
namespace amcl::test {
[[noreturn]] inline void FailCheck(const char* expression, const char* file, int line)
{
    std::cerr << file << ':' << line << ": CHECK failed: " << expression << '\n';
    std::exit(EXIT_FAILURE);
}
}

// 保留现有 CHECK 接口；条件只求值一次，do/while 保证用于 if/else 时仍是一条语句。
#define CHECK(expression) \
    do { \
        if (!(expression)) { \
            ::amcl::test::FailCheck(#expression, __FILE__, __LINE__); \
        } \
    } while (false)
