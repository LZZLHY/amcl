/* 使用SDK精确签名的有状态故障服务验证真实控制源码，不替换任何核心实现。
 * 注入真实语义：同client重复open拒绝、count竞态、Send部分接受、关闭消费句柄、
 * 热插拔和服务失败。外设/商业OHOS的集成资格必须另外取得。
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "../../entry/src/main/cpp/javasound/midi_core.h"
#include "fake_provider.h"
static void deliver(OH_MIDIDevice* device, const AmclMidiPacket* packet) {
    OH_MIDIEvent event={packet->timestamp,packet->wordCount,(uint32_t*)packet->words};
    assert(device->inputOpen);device->received(device->user,&event,1);
}
typedef struct { AmclMidiUse* use; int result; } SendThread;
static void* sender(void* pointer) {
    SendThread* context=pointer;context->result=amcl_midi_send_short(context->use,0x643c90,-1);return NULL;
}
int main(void) {
    fixtures(); AmclMidiManager* manager=NULL;
    assert(!amcl_midi_manager_create(&manager,&api,amcl_midi_local_callbacks_v1()));
    AmclMidiEndpoint *in=NULL,*out=NULL;size_t inCount=0,outCount=0;
    assert(!amcl_midi_snapshot(manager,0,&in,&inCount) && inCount==2 && in[0].port.portIndex==9 && in[1].device.deviceType==OH_MIDI_DEVICE_TYPE_BLE);
    assert(!amcl_midi_snapshot(manager,1,&out,&outCount) && outCount==2 && out[0].port.portIndex==27);
    int inToken=in[0].token,outToken=out[0].token,bleToken=in[1].token;
    free(in);free(out);
    infoError=1;assert(amcl_midi_snapshot(manager,0,&in,&inCount)==OH_MIDI_STATUS_GENERIC_IPC_FAILURE && !in && !inCount);infoError=0;
    duplicatePort=1;assert(amcl_midi_snapshot(manager,0,&in,&inCount)==AMCL_MIDI_INVALID);duplicatePort=0;
    uint64_t inHandle=0,outHandle=0,duplicate=0;
    assert(!amcl_midi_open(manager,inToken,0,&inHandle));
    assert(!amcl_midi_open(manager,outToken,1,&outHandle) && openCalls==1);
    assert(amcl_midi_open(manager,outToken,1,&duplicate)==OH_MIDI_STATUS_PORT_ALREADY_OPEN);
    AmclMidiUse *input=amcl_midi_acquire(manager,inHandle,0),*output=amcl_midi_acquire(manager,outHandle,1);
    assert(input && output && !amcl_midi_read_begin(input));
    /* Java上游先启动线程再nStart，首次start不能将暂时存在的reader误判为重启冲突。 */
    assert(!amcl_midi_start(input));
    assert(amcl_midi_position(input)>=0);
    assert(!amcl_midi_send_short(output,0x643c90,0));uint64_t epoch=sent[0].timestamp;
    assert(!amcl_midi_send_short(output,0x643d90,INT64_C(4294967296)) && sent[1].timestamp-epoch==UINT64_C(4294967296000));
    assert(!amcl_midi_send_short(output,0xf8,-1) && sent[2].timestamp==0);
    unsigned before=sentCount;
    uint8_t sysex[3002];sysex[0]=0xf0;sysex[3001]=0xf7;
    for(unsigned i=1;i<3001;++i)sysex[i]=(uint8_t)(i&127);
    partial=1;assert(!amcl_midi_send_long(output,sysex,sizeof(sysex),777));
    assert(sentCount-before==500 && sendCalls<=13);
    unsigned bytes=0;
    for(unsigned i=before;i<sentCount;++i) {
        AmclMidiDecoded decoded;assert(amcl_midi_from_ump(sent[i].words,sent[i].wordCount,&decoded)==2 && decoded.group==11);
        assert(decoded.sysexForm==(i==before?1:i+1==sentCount?3:2));
        for(unsigned j=0;j<decoded.payloadSize;++j)assert(decoded.payload[j]==sysex[++bytes]);
        /* 输入协议独立注入同一字节流：系统port的真实group保留解析，Java无group字段。 */
        deliver(opened[0],&sent[i]);
    }
    assert(bytes==3000);
    AmclMidiMessage message;
    assert(amcl_midi_next(input,&message)==1 && message.isLong && message.length==sizeof(sysex) && !memcmp(message.data,sysex,sizeof(sysex)));
    before=sentCount;uint8_t malformed[]={0xf0,1,0x80,0xf7};assert(amcl_midi_send_long(output,malformed,sizeof(malformed),0)==AMCL_MIDI_INVALID && sentCount==before);
    const uint8_t start[]={0xf0,1,2,3},cont[]={0xf7,4,5,6,0xf7};
    assert(!amcl_midi_send_long(output,start,sizeof(start),10));assert(!amcl_midi_send_long(output,cont,sizeof(cont),20));
    assert(sent[before].timestamp==epoch+10000 && sent[before+1].timestamp==epoch+20000);
    /* 用户Receiver阻塞超过Java join期限时，JNI的真实hold仍保活对象；close撤销
     * 新获取，旧hold可安全看到closed并释放，而不是碰已释放或复用的堆地址。 */
    assert(!amcl_midi_close(manager,inHandle));assert(!amcl_midi_acquire(manager,inHandle,0));
    assert(amcl_midi_next(input,&message)==0);amcl_midi_read_end(input);amcl_midi_release(input);
    assert(closeCalls==0); /* 另一个output仍共享真实device。 */
    atomic_store(&blockSend,1);SendThread sendContext={output,0};pthread_t thread;
    assert(!pthread_create(&thread,NULL,sender,&sendContext));struct timespec pause={0,30000000};nanosleep(&pause,NULL);
    assert(!amcl_midi_close(manager,outHandle));assert(!pthread_join(thread,NULL));
    assert(sendContext.result==AMCL_MIDI_CLOSED);amcl_midi_release(output);atomic_store(&blockSend,0);
    assert(closeCalls==1);
    /* 已枚举BLE同样按真实ID打开，端口编号41/4并非固定0/1。 */
    uint64_t bleHandle;assert(!amcl_midi_open(manager,bleToken,0,&bleHandle));
    assert(!amcl_midi_close(manager,bleHandle));
    client->callbacks.onDeviceChange(client->user,OH_MIDI_DEVICE_CHANGE_ACTION_DISCONNECTED,infos[1]);
    client->callbacks.onDeviceChange(client->user,OH_MIDI_DEVICE_CHANGE_ACTION_CONNECTED,infos[1]);
    assert(amcl_midi_open(manager,bleToken,0,&bleHandle)==AMCL_MIDI_STALE);
    assert(!amcl_midi_snapshot(manager,0,&in,&inCount));assert(in[0].token==inToken && in[1].token!=bleToken);
    int replacement=in[1].token;free(in);
    assert(!amcl_midi_open(manager,replacement,0,&bleHandle));input=amcl_midi_acquire(manager,bleHandle,0);assert(input);
    assert(!amcl_midi_start(input));assert(!amcl_midi_read_begin(input));
    client->callbacks.onDeviceChange(client->user,OH_MIDI_DEVICE_CHANGE_ACTION_DISCONNECTED,infos[1]);
    assert(amcl_midi_next(input,&message)==OH_MIDI_STATUS_INVALID_DEVICE_HANDLE);
    amcl_midi_read_end(input);amcl_midi_release(input);
    closePortError=1;assert(amcl_midi_close(manager,bleHandle)==OH_MIDI_STATUS_GENERIC_IPC_FAILURE);closePortError=0;
    client->callbacks.onError(client->user,OH_MIDI_STATUS_SERVICE_DIED);
    assert(amcl_midi_snapshot(manager,0,&in,&inCount)==OH_MIDI_STATUS_SERVICE_DIED && !inCount);
    assert(!amcl_midi_snapshot(manager,0,&in,&inCount) && inCount==2 && in[0].token!=inToken);
    int recoveredInput = in[0].token; free(in);
    assert(!amcl_midi_snapshot(manager,1,&out,&outCount));int recoveredOutput = out[0].token;free(out);
    assert(!amcl_midi_open(manager,recoveredInput,0,&inHandle));
    assert(!amcl_midi_open(manager,recoveredOutput,1,&outHandle));
    input=amcl_midi_acquire(manager,inHandle,0);output=amcl_midi_acquire(manager,outHandle,1);
    assert(input && output && !amcl_midi_start(input) && !amcl_midi_read_begin(input));
    /* 真实typed callback写满通知环后再发一个事件：丢失的通知可能正是旧端口
     * 的断连。输入必须收到Changed而非无限等待，输出也不得继续向不确定身份发包。 */
    for(unsigned i=0;i<=AMCL_MIDI_NOTICE_CAPACITY;++i)
        client->callbacks.onDeviceChange(client->user,OH_MIDI_DEVICE_CHANGE_ACTION_CONNECTED,infos[1]);
    AmclMidiPacket uncertain = { .timestamp=0, .words={0x20903c64,0}, .wordCount=1 };
    deliver(opened[0],&uncertain);
    assert(amcl_midi_next(input,&message)==AMCL_MIDI_CHANGED);
    assert(amcl_midi_send_short(output,0x643c90,-1)==AMCL_MIDI_CHANGED);
    amcl_midi_read_end(input);amcl_midi_release(input);amcl_midi_release(output);
    assert(!amcl_midi_close(manager,inHandle) && !amcl_midi_close(manager,outHandle));
    assert(!amcl_midi_manager_destroy(manager) && !client && openCalls==closeCalls && destroyCalls==2);
    manager=NULL;createError=1;assert(amcl_midi_manager_create(&manager,&api,amcl_midi_local_callbacks_v1())==OH_MIDI_STATUS_GENERIC_IPC_FAILURE && !manager);createError=0;
    /* 不确定Destroy失败的保留路径在独立子进程检查：它有意不释放回调POD/API，
     * 不能让LSan的正常路径零泄漏断言与这项保留策略互相掩盖。 */
    pid_t child=fork();assert(child>=0);
    if(!child) {
        assert(!amcl_midi_manager_create(&manager,&api,amcl_midi_local_callbacks_v1()));
        destroyError=1;unsigned old=destroyCalls;
        assert(amcl_midi_manager_destroy(manager)==OH_MIDI_STATUS_GENERIC_IPC_FAILURE && destroyCalls==old+1);
        assert(amcl_midi_manager_destroy(manager)==OH_MIDI_STATUS_GENERIC_IPC_FAILURE && destroyCalls==old+1);
        _exit(0);
    }
    int status;assert(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
    puts("PASS MIDI core: real snapshot/port IDs, USB+BLE sharing, count race/error, 64-bit timestamps, 3000-byte batched SysEx/partial writes, close-during-JNI hold, bounded cancel, same-count hotplug, notice overflow Changes both active directions, service recovery and consumed-handle Destroy fault");
}
