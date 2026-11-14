/* 固定外部字节序列逐包对照：跨Java调用时间、长于旧1024缓冲的SysEx、实时插入、
 * running status和错误状态。未接受的候选状态不写回，模拟平台Send拒绝后的安全重试。
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../../entry/src/main/cpp/javasound/midi_stream.h"
int main(void) {
    AmclMidiStream state = {0}; AmclMidiOutput packet; size_t offset = 0;
    const uint8_t gm[] = {0xf0,0x7e,0x7f,0x09,0x01,0xf7};
    assert(amcl_midi_stream_next(&state,0,gm,sizeof(gm),&offset,123,&packet)==1);
    assert(offset==sizeof(gm) && packet.words[0]==0x30047e7f && packet.words[1]==0x09010000 && packet.timestamp==123);
    uint8_t longData[3002]; longData[0]=0xf0;longData[3001]=0xf7;
    for(unsigned i=1;i<3001;++i)longData[i]=(uint8_t)(i&127);
    offset=0;unsigned count=0,payload=0;
    while(offset<sizeof(longData)) {
        assert(amcl_midi_stream_next(&state,5,longData,sizeof(longData),&offset,456,&packet)==1);
        AmclMidiDecoded decoded;assert(amcl_midi_from_ump(packet.words,packet.count,&decoded)==AMCL_MIDI_UMP_SYSEX7);
        assert(decoded.group==5 && packet.timestamp==456);
        assert(decoded.sysexForm==(count==0?1:offset==sizeof(longData)?3:2));
        for(unsigned i=0;i<decoded.payloadSize;++i)assert(decoded.payload[i]==longData[1+payload++]);
        ++count;
    }
    assert(count==500 && payload==3000 && !state.sysexOpen);
    const uint8_t start[]={0xf0,1,2,3};offset=0;
    assert(amcl_midi_stream_next(&state,0,start,sizeof(start),&offset,100,&packet)==1 && packet.words[0]==0x30130102 && packet.words[1]==0x03000000 && packet.timestamp==100);
    assert(!amcl_midi_stream_next(&state,0,start,sizeof(start),&offset,100,&packet));
    const uint8_t continuation[]={4,5,6,0xf8,7,0xf7};offset=0;
    assert(amcl_midi_stream_next(&state,0,continuation,sizeof(continuation),&offset,200,&packet)==1 && packet.words[0]==0x30230405 && packet.words[1]==0x06000000 && packet.timestamp==200);
    assert(amcl_midi_stream_next(&state,0,continuation,sizeof(continuation),&offset,200,&packet)==1 && packet.words[0]==0x10f80000 && packet.timestamp==200);
    assert(amcl_midi_stream_next(&state,0,continuation,sizeof(continuation),&offset,200,&packet)==1 && packet.words[0]==0x30310700 && packet.timestamp==200);
    const uint8_t running[]={0x90,60,100,61,0xf8,101,0xf2,1,2};offset=0;
    const uint32_t expected[]={0x20903c64,0x10f80000,0x20903d65,0x10f20102};
    for(unsigned i=0;i<4;++i)assert(amcl_midi_stream_next(&state,0,running,sizeof(running),&offset,999,&packet)==1 && packet.words[0]==expected[i]);
    assert(!state.running && offset==sizeof(running));
    uint8_t bad[]={42};offset=0;assert(amcl_midi_stream_next(&state,0,bad,1,&offset,0,&packet)<0);
    memset(&state,0,sizeof(state)); AmclMidiStream candidate=state; offset=0;
    assert(amcl_midi_stream_next(&candidate,0,gm,sizeof(gm),&offset,123,&packet)==1);
    /* 发送失败时保留state，重试从同样字节产生相同消息，不推进内部半包状态。 */
    assert(!memcmp(&state,&(AmclMidiStream){0},sizeof(state)));
    candidate=state;offset=0;assert(amcl_midi_stream_next(&candidate,0,gm,sizeof(gm),&offset,123,&packet)==1 && packet.words[0]==0x30047e7f);
    puts("PASS MIDI byte-stream: independent GM vector, 3000-byte SysEx/500 packets, continuation timestamp, realtime/running-status, invalid input and transactional retry");
}
