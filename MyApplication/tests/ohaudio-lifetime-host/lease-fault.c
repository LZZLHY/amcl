/** 精确NOLOAD/owner身份故障注入；实际模块引用仍由系统loader维护，不伪造卸载。 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
int dladdr(const void* address,Dl_info* info) {
    int (*actual)(const void*,Dl_info*)=(int(*)(const void*,Dl_info*))dlsym(RTLD_NEXT,"dladdr");
    const int result=actual(address,info);const char* mode=getenv("AMCL_LEASE_FAULT");
    if(result && mode && strcmp(mode,"no-owner")==0 && info->dli_fname && strstr(info->dli_fname,"libopenal") &&
       (!info->dli_sname || strcmp(info->dli_sname,"alcOpenDevice")!=0)) {
        fprintf(stderr,"LEASE_FAULT no-owner address=%p\n",address);return 0;
    }
    return result;
}
void* dlopen(const char* path,int flags) {
    void* (*actual)(const char*,int)=(void*(*)(const char*,int))dlsym(RTLD_NEXT,"dlopen");
    const char* mode=getenv("AMCL_LEASE_FAULT");
    if(path && (flags&RTLD_NOLOAD) && strstr(path,"libopenal") && mode && strcmp(mode,"wrong-owner")==0) {
        void* foreign=actual("libforeign-owner.so",RTLD_NOW|RTLD_LOCAL);
        fprintf(stderr,"LEASE_FAULT actual-foreign-handle=%p\n",foreign);return foreign;
    }
    return actual(path,flags);
}
