/* 仅本轮host的外部解析观察器：不替换任何函数返回，不改MobileGL/重放器状态。
 * 只记录调用来自既有replay可执行文件的GL/EGL dlsym，排除真实backend内部系统解析。
 * RTLD_DEFAULT回退即使碰巧回到同库也单独标记；文件缺头/尾、错PID/foreign不能qualified。
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <time.h>
static int evidence_fd=-1;
static char provider[PATH_MAX],run_id[128];
static _Atomic unsigned total=0,foreign=0,fallback=0,missing=0,write_errors=0;
static __thread int entering=0;
static int maps_written=0;
static void *(*real_lookup)(void *,const char *)=NULL;
static const char *base(const char *s){const char *p=strrchr(s?s:"",'/');return p?p+1:s;}
__attribute__((constructor)) static void begin_evidence(void){
 const char *path=getenv("AMCL_PROVIDER_OBSERVER_LOG"),*expected=getenv("AMCL_PROVIDER_OBSERVER_LIBRARY"),*run=getenv("AMCL_RUN_ID");
 if(!path||!expected||!run||!realpath(expected,provider))_Exit(91);
 snprintf(run_id,sizeof run_id,"%s",run);
 evidence_fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
 if(evidence_fd<0)_Exit(92);
 if(dprintf(evidence_fd,"{\"kind\":\"begin\",\"pid\":%ld,\"runId\":\"%s\",\"provider\":\"%s\"}\n",(long)getpid(),run_id,provider)<0)_Exit(93);
}
void *dlsym(void *handle,const char *name){
 if(!real_lookup)real_lookup=(void *(*)(void *,const char *))dlvsym(RTLD_NEXT,"dlsym","GLIBC_2.2.5");
 if(!real_lookup)_Exit(94);
 void *result=real_lookup(handle,name);
 if(entering||evidence_fd<0||!name)return result;
 entering=1;
 Dl_info caller={0},owner={0};
 const int relevant=(strncmp(name,"egl",3)==0||(name[0]=='g'&&name[1]=='l'&&name[2]>='A'&&name[2]<='Z'))&&
     dladdr(__builtin_return_address(0),&caller)&&caller.dli_fname&&strcmp(base(caller.dli_fname),"mobilegl_trace_replay")==0;
 if(relevant){
  /* 实际context后的首次GL字符串解析时，独立收取当前进程已映射DSO清单。
   * 只读/proc，不替换地址；loader/ICD是否真的进入进程不能仅从环境变量推断。 */
  if(!maps_written && strcmp(name,"glGetString")==0){
   const char *path=getenv("AMCL_PROVIDER_OBSERVER_MAPS");int in=open("/proc/self/maps",O_RDONLY|O_CLOEXEC);
   int out=path?open(path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600):-1;char buffer[4096];ssize_t n;
   if(in<0||out<0)atomic_fetch_add(&write_errors,1);
   else {while((n=read(in,buffer,sizeof buffer))>0)if(write(out,buffer,(size_t)n)!=n){atomic_fetch_add(&write_errors,1);break;}if(n<0)atomic_fetch_add(&write_errors,1);}
   if(in>=0)close(in);if(out>=0&&close(out)!=0)atomic_fetch_add(&write_errors,1);maps_written=1;
  }
  char actual[PATH_MAX]="";const int have_owner=result&&dladdr(result,&owner)&&owner.dli_fname&&realpath(owner.dli_fname,actual);
  const char *verdict=!result?"MISSING":(!have_owner||strcmp(actual,provider)!=0?"FOREIGN":(handle==RTLD_DEFAULT?"FALLBACK":"OWN"));
  atomic_fetch_add(&total,1);if(!result)atomic_fetch_add(&missing,1);else if(!have_owner||strcmp(actual,provider)!=0)atomic_fetch_add(&foreign,1);
  if(handle==RTLD_DEFAULT)atomic_fetch_add(&fallback,1);
  if(dprintf(evidence_fd,"{\"kind\":\"resolve\",\"pid\":%ld,\"runId\":\"%s\",\"symbol\":\"%s\",\"address\":\"%p\",\"imageBase\":\"%p\",\"library\":\"%s\",\"verdict\":\"%s\"}\n",(long)getpid(),run_id,name,result,owner.dli_fbase,actual,verdict)<0)atomic_fetch_add(&write_errors,1);
 }
 entering=0;return result;
}
__attribute__((destructor)) static void end_evidence(void){
 if(evidence_fd<0)return;
 const unsigned t=atomic_load(&total),f=atomic_load(&foreign),b=atomic_load(&fallback),m=atomic_load(&missing),w=atomic_load(&write_errors);
 if(dprintf(evidence_fd,"{\"kind\":\"end\",\"pid\":%ld,\"runId\":\"%s\",\"completed\":true,\"resolutions\":%u,\"foreign\":%u,\"fallback\":%u,\"missing\":%u,\"writeErrors\":%u}\n",(long)getpid(),run_id,t,f,b,m,w)<0)_Exit(95);
 if(close(evidence_fd)!=0)_Exit(96);evidence_fd=-1;
}
