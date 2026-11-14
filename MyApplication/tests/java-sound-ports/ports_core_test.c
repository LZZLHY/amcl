/* 生产核心的错误/所有权/设备替换/并发回归；只替换SDK供应者及分配器，不复制实现。 */
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ports_fake_device.h"
static long allocations, fail_at, live;
static void *ports_allocate(size_t n,size_t size)
{
    long call=__atomic_add_fetch(&allocations,1,__ATOMIC_SEQ_CST);void*p;
    if(call==fail_at)return NULL;
    p=calloc(n,size);if(p)__atomic_add_fetch(&live,1,__ATOMIC_SEQ_CST);return p;
}
static void ports_free(void*p){if(p)__atomic_sub_fetch(&live,1,__ATOMIC_SEQ_CST);free(p);}
#define AMCL_PORTS_TEST 1
#define AMCL_PORTS_ALLOC ports_allocate
#define free ports_free
#include "../../entry/src/main/cpp/javasound/ports_ohos.c"
#undef free

static void refresh(size_t wanted,uint64_t *generation)
{
    size_t count=999;int native_error=-1;
    assert(amcl_ports_refresh(&count,generation,&native_error)==AMCL_PORTS_OK);
    /* 返回时别的并发调用可能已持有它自己的SDK数组；全局零持有量在join后核对。 */
    assert(count==wanted&&native_error==0);
}
static void *worker(void *ignored)
{
    int i; (void)ignored;
    for(i=0;i<50;++i){uint64_t gen,handle;AmclPortInfo info;int native_error;
        refresh(4,&gen);assert(amcl_ports_info_at(0,gen,&info)==AMCL_PORTS_OK);
        assert(amcl_ports_open(info.token,&handle,&native_error)==AMCL_PORTS_OK);amcl_ports_info_free(&info);
        assert(amcl_ports_check_present(handle,&native_error)==AMCL_PORTS_OK);assert(amcl_ports_close(handle)==AMCL_PORTS_OK);
    }
    return NULL;
}
int main(void)
{
    uint64_t gen,old_gen,token,handle,saved;AmclPortInfo info,copy;int error,result,i;size_t count;pthread_t threads[4];long allocation_points,open_points,begin,before_live;
    ports_fake_scenario(0);refresh(4,&gen);old_gen=gen;
    assert(amcl_ports_info_at(0,gen,&info)==AMCL_PORTS_OK);token=info.token;
    assert(!strcmp(info.name,"扬声器🙂"));amcl_ports_info_free(&info);
    assert(amcl_ports_info_at(3,gen,&info)==AMCL_PORTS_OK&&strlen(info.name)>200);amcl_ports_info_free(&info);
    ports_fake_scenario(1);refresh(4,&gen);assert(gen==old_gen);
    assert(amcl_ports_info_at(0,gen,&info)==AMCL_PORTS_OK&&info.token==token);amcl_ports_info_free(&info);
    assert(amcl_ports_open(token,&handle,&error)==AMCL_PORTS_OK);
    ports_fake_scenario(2);refresh(4,&gen);assert(gen!=old_gen);
    assert(amcl_ports_info_at(0,old_gen,&info)==AMCL_PORTS_STALE);
    assert(amcl_ports_check_present(handle,&error)==AMCL_PORTS_STALE);
    assert(amcl_ports_handle_info(handle,&copy)==AMCL_PORTS_OK&&!strcmp(copy.name,"扬声器🙂"));amcl_ports_info_free(&copy);
    assert(amcl_ports_open(token,&old_gen,&error)==AMCL_PORTS_STALE);
    assert(amcl_ports_close(handle)==AMCL_PORTS_OK&&amcl_ports_close(handle)==AMCL_PORTS_STALE);
    /* 每一个真实分配点单独失败；失败后原代次/设备仍完整，SDK数组与私有内存全部收敛。 */
    ports_fake_scenario(0);refresh(4,&gen);ports_fake_scenario(2);begin=allocations;refresh(4,&gen);
    allocation_points=allocations-begin;assert(allocation_points>=9);
    for(i=1;i<=allocation_points;++i){
        ports_fake_scenario(0);fail_at=0;refresh(4,&old_gen);
        ports_fake_scenario(2);fail_at=allocations+i;
        result=amcl_ports_refresh(&count,&gen,&error);fail_at=0;
        assert(result==AMCL_PORTS_NO_MEMORY);assert(amcl_ports_generation()==old_gen&&ports_fake_arrays()==0);
        assert(amcl_ports_info_at(0,old_gen,&info)==AMCL_PORTS_OK&&!strcmp(info.name,"扬声器🙂"));amcl_ports_info_free(&info);
    }
    for(i=4;i<=11;++i){
        ports_fake_scenario(0);refresh(4,&old_gen);ports_fake_scenario(i);
        assert(amcl_ports_refresh(&count,&gen,&error)!=AMCL_PORTS_OK);
        assert(amcl_ports_generation()==old_gen&&ports_fake_arrays()==0);
    }
    for(i=14;i<=18;++i){
        ports_fake_scenario(0);refresh(4,&old_gen);ports_fake_scenario(i);
        assert(amcl_ports_refresh(&count,&gen,&error)==AMCL_PORTS_PLATFORM_ERROR);
        assert(error==AUDIOCOMMON_RESULT_ERROR_SYSTEM&&amcl_ports_generation()==old_gen&&ports_fake_arrays()==0);
    }
    /* open不仅刷新快照，还分配句柄及两份字符串；逐点失败后既无半句柄也无字符串泄漏。 */
    ports_fake_scenario(0);refresh(4,&gen);assert(amcl_ports_info_at(0,gen,&info)==AMCL_PORTS_OK);
    token=info.token;amcl_ports_info_free(&info);begin=allocations;
    assert(amcl_ports_open(token,&handle,&error)==AMCL_PORTS_OK);open_points=allocations-begin;
    assert(amcl_ports_close(handle)==AMCL_PORTS_OK&&open_points==allocation_points+3);
    before_live=live;
    for(i=1;i<=open_points;++i){
        fail_at=allocations+i;result=amcl_ports_open(token,&handle,&error);fail_at=0;
        assert(result==AMCL_PORTS_NO_MEMORY&&handle==0&&amcl_ports_test_handles()==0);
        assert(live==before_live&&ports_fake_arrays()==0);
    }
    for(i=1;i<=2;++i){
        fail_at=allocations+i;result=amcl_ports_info_at(0,gen,&copy);fail_at=0;
        assert(result==AMCL_PORTS_NO_MEMORY&&copy.name==NULL&&copy.address==NULL&&live==before_live);
    }
    /* 接近jlong边界也不绕回0/负值；失败保持此前缓存、句柄和代次。 */
    saved=next_handle;next_handle=INT64_MAX;
    assert(amcl_ports_open(token,&handle,&error)==AMCL_PORTS_INVALID&&handle==0);next_handle=saved;
    saved=next_token;next_token=INT64_MAX;ports_fake_scenario(2);
    assert(amcl_ports_refresh(&count,&old_gen,&error)==AMCL_PORTS_INVALID&&amcl_ports_generation()==gen);next_token=saved;
    saved=current_generation;current_generation=INT64_MAX;
    assert(amcl_ports_refresh(&count,&old_gen,&error)==AMCL_PORTS_INVALID&&amcl_ports_generation()==INT64_MAX);current_generation=saved;
    ports_fake_scenario(3);refresh(0,&gen);assert(amcl_ports_info_at(0,gen,&info)==AMCL_PORTS_STALE);
    ports_fake_scenario(0);refresh(4,&gen);
    for(i=0;i<4;++i)assert(!pthread_create(&threads[i],NULL,worker,NULL));
    for(i=0;i<4;++i)assert(!pthread_join(threads[i],NULL));
    assert(ports_fake_arrays()==0);
    amcl_ports_test_reset();assert(live==0&&ports_fake_arrays()==0);
    printf("PASS actual ports core: real descriptor identity/reorder/replacement, %ld refresh + %ld open + 2 copy allocation faults, 13 provider faults, counter bounds, empty-list and 200 concurrent handle cycles; no writable controls\n",allocation_points,open_points);
    return 0;
}
