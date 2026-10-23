/**
 * 手柄producer只冻结设备租约→neutral stream的映射。Native monotonic采样一次，不把
 * ArkTS ACTIVE uptime或sensor startup的同ns数值误作同域。资源改变不自动认领旧连接。
 */
#include "mapped_look_producer.h"
#include "../input/delivery/look_transport.h"
#include <map>
#include <mutex>
#include <chrono>
#include <cmath>
#include <new>
namespace {
struct Connection {uint64_t stream=0;AmclLookResourceV1 resource{};};
std::mutex producerMutex;
std::map<std::pair<uint64_t,uint64_t>,Connection> connections;
std::map<uint64_t,uint64_t> retired;
uint64_t now(){return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
    std::chrono::steady_clock::now().time_since_epoch()).count());}
bool sameResource(const AmclLookResourceV1& a,const AmclLookResourceV1& b){return a.gameSession==b.gameSession&&
    a.sessionEpoch==b.sessionEpoch&&a.surfaceEpoch==b.surfaceEpoch&&a.focusEpoch==b.focusEpoch&&a.modeEpoch==b.modeEpoch;}
}
bool amclMappedLookSupported(){const auto* port=amclLookExecutionGetPortV1();return port&&port->magic==AMCL_LOOK_EXECUTION_MAGIC&&
    port->version==1&&port->size==sizeof(*port)&&port->verifyOwner(port->ownerHost)>=0;}
bool amclMappedLookSet(uint64_t device,uint64_t connection,double vx,double vy){
    // Getter先拒fork再取producer mutex，继承的map/mutex永远不被child触碰。
    const auto* port=amclLookExecutionGetPortV1();if(!port||device>UINT32_MAX||!connection||connection>UINT32_MAX||
        !std::isfinite(vx)||!std::isfinite(vy))return false;
    AmclLookResourceV1 resource{};if(!inputBridge_getLookResourceV1(&resource))return false;
    std::lock_guard<std::mutex> lock(producerMutex);const auto dead=retired.find(device);
    if(dead!=retired.end()&&connection<=dead->second)return false;
    const auto key=std::make_pair(device,connection);auto it=connections.find(key);
    if(it!=connections.end()&&!sameResource(it->second.resource,resource))return false;
    if(it==connections.end()){
        // tombstone槽在接受首事实前分配，退休路径只修改已有值而不分配内存。
        try{retired.emplace(device,0);}catch(const std::bad_alloc&){return false;}
        if(connections.size()>=512)return false;AmclLookStreamV1 description{};description.size=sizeof(description);
        description.source=2;description.kind=AMCL_LOOK_MAPPED_RATE;description.unit=AMCL_LOOK_VIRTUAL_COUNTS_PER_SECOND;
        description.clock=AMCL_LOOK_OWNER_MONOTONIC;description.device=device;description.connection=connection;description.resource=resource;
        uint64_t stream=0;if(port->openStream(&description,&stream)<0)return false;
        try{it=connections.emplace(key,Connection{stream,resource}).first;}catch(const std::bad_alloc&){port->retireStream(stream);return false;}
    }
    return port->submitVelocity(it->second.stream,vx,vy,now())>=0;
}
bool amclMappedLookAdvance(){if(!amclLookExecutionGetPortV1())return false;
    // timer仅推动owner并封已加工量。旧设备/资源在owner处独立拒绝，不补后台历史。
    return inputBridge_submitLookV1(0,0,0,0,0)!=0;}
bool amclMappedLookRetire(uint64_t device,uint64_t connection){const auto* port=amclLookExecutionGetPortV1();
    if(!port||device>UINT32_MAX||!connection||connection>UINT32_MAX)return false;std::lock_guard<std::mutex> lock(producerMutex);
    const auto key=std::make_pair(device,connection);const auto it=connections.find(key);
    // 零速率/退休不依赖控制RELEASE成功，也不需要foreground/surface gate。
    if(it!=connections.end()){(void)port->retireStream(it->second.stream);connections.erase(it);}
    const auto dead=retired.find(device);if(dead!=retired.end()&&connection>dead->second)dead->second=connection;return true;
}
void amclMappedLookRetireAll(){const auto* port=amclLookExecutionGetPortV1();if(!port)return;std::lock_guard<std::mutex> lock(producerMutex);
    for(const auto& e:connections){(void)port->retireStream(e.second.stream);const auto dead=retired.find(e.first.first);
        if(dead!=retired.end()&&e.first.second>dead->second)dead->second=e.first.second;}
    connections.clear();}
