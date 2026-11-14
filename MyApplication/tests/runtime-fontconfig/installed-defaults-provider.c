/* 仅为 installed-provider 探针的控制流/失败恢复边界构造 C ABI。
 * 字体结果是固定替身，不替代实际 FC 缓存格式、系统字体或目标设备资格。 */
#include <fontconfig/fontconfig.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
struct _FcConfig { int generation; };
struct _FcStrList { int at; const char* item; };
struct _FcCache { int fonts; };
struct _FcPattern { char* query; };
struct _FcCharSet { int unused; };
static int generation;
extern void FT_Get_BDF_Property(void);
void (*const ft_reference)(void) = FT_Get_BDF_Property;
static int mode(const char* value) { const char* actual = getenv("AMCL_INSTALLED_MODE"); return actual && strcmp(actual,value)==0; }
static const char* cache_root(void) { return getenv("AMCL_INSTALLED_CACHE"); }
static void filename(char* path) { snprintf(path,4096,"%s/fixture-le64.cache-9",cache_root()); }
FcConfig* FcInitLoadConfig(void) { FcConfig* c=malloc(sizeof(*c)); if(c)c->generation=++generation; return c; }
void FcConfigDestroy(FcConfig* c) { free(c); }
static FcStrList* list(const char* value) { FcStrList* l=calloc(1,sizeof(*l));if(l)l->item=value;return l; }
FcStrList* FcConfigGetCacheDirs(FcConfig* c) { (void)c;return list(mode("bad-cache")?"/wrong-cache":cache_root()); }
FcStrList* FcConfigGetFontDirs(FcConfig* c) { (void)c;return list(mode("no-fonts")?"/not-fonts":"/system/fonts"); }
FcChar8* FcStrListNext(FcStrList* l) { return l->at++?NULL:(FcChar8*)l->item; }
void FcStrListDone(FcStrList* l) { free(l); }
FcCache* FcDirCacheRead(const FcChar8* dir,FcBool force,FcConfig* config) {
    (void)dir;(void)config;
    if(!force || mode("read-fails"))return NULL;
    char parent[4096],path[4096];snprintf(parent,sizeof(parent),"%s",cache_root());
    *strrchr(parent,'/')=0;mkdir(parent,0700);mkdir(cache_root(),0700);filename(path);
    int fd=open(path,O_WRONLY|O_CREAT|O_TRUNC,0600);if(fd<0)return NULL;
    const char payload[]="fixture cache body: control-flow only";
    if(write(fd,payload,sizeof(payload))!=(ssize_t)sizeof(payload)){close(fd);return NULL;}
    fsync(fd);close(fd);FcCache* c=malloc(sizeof(*c));if(c)c->fonts=2;return c;
}
FcCache* FcDirCacheLoad(const FcChar8* dir,FcConfig* config,FcChar8** path) {
    (void)dir;if(mode("no-disk"))return NULL;
    char name[4096];filename(name);
    if(mode("warm-rewrite") && config->generation>1){int fd=open(name,O_WRONLY|O_APPEND);if(fd>=0){write(fd,"changed",7);close(fd);}}
    int fd=open(name,O_RDONLY);if(fd<0)return NULL;char byte;int ok=read(fd,&byte,1)==1;close(fd);if(!ok)return NULL;
    *path=(FcChar8*)strdup(name);FcCache* c=malloc(sizeof(*c));if(c)c->fonts=2;return c;
}
void FcDirCacheUnload(FcCache* c){free(c);}
int FcCacheNumFont(const FcCache* c){return c->fonts;}
void FcStrFree(FcChar8* p){free(p);}
FcBool FcConfigBuildFonts(FcConfig* c){
    (void)c;if(mode("mutate-slot")){char path[4096];snprintf(path,sizeof(path),"%s/sentinel",getenv("AMCL_INSTALLED_ROOT"));
    int fd=open(path,O_WRONLY|O_TRUNC);if(fd>=0){write(fd,"mutated",7);close(fd);}}
    return FcTrue;
}
FcPattern* FcNameParse(const FcChar8* query){FcPattern* p=malloc(sizeof(*p));if(p)p->query=strdup((const char*)query);return p;}
void FcPatternDestroy(FcPattern* p){if(p){free(p->query);free(p);}}
FcBool FcConfigSubstitute(FcConfig* c,FcPattern* p,FcMatchKind k){(void)c;(void)p;(void)k;return FcTrue;}
void FcDefaultSubstitute(FcPattern* p){(void)p;}
FcPattern* FcFontMatch(FcConfig* c,FcPattern* p,FcResult* r){(void)c;*r=FcResultMatch;return FcNameParse((FcChar8*)p->query);}
FcResult FcPatternGetString(const FcPattern* p,const char* key,int index,FcChar8** value){
    (void)p;(void)index;*value=(FcChar8*)(strcmp(key,"file")==0?"/system/fonts/fixture.ttf":"Fixture Sans");return FcResultMatch;
}
FcResult FcPatternGetCharSet(const FcPattern* p,const char* key,int index,FcCharSet** value){
    (void)p;(void)key;(void)index;static FcCharSet chars;*value=&chars;return FcResultMatch;
}
FcBool FcCharSetHasChar(const FcCharSet* c,FcChar32 value){(void)c;return !(mode("missing-glyph") && value==0x4e2d);}
