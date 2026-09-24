#pragma once
// 仅给生产绑定源码的故障注入测试使用；产品仍直接使用 OHOS 动态链接器。
#define RTLD_NOW 2
#define RTLD_LOCAL 0
struct Dl_info { const char* dli_fname; void* dli_fbase; const char* dli_sname; void* dli_saddr; };
void* dlopen(const char*, int);
void* dlsym(void*, const char*);
int dladdr(const void*, Dl_info*);
