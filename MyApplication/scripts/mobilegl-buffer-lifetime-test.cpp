// 此文件由test-mobilegl-buffer-lifetime.py在真实BufferObject.cpp之后编译。
// 只替换GPU分配边界，所有映射、shadow释放、查询、flush和生命周期来自产品实现。
using namespace MobileGL;
using namespace MobileGL::MG_State::GLState;
namespace {
struct Backend {
    MapAlignedData gpu;
    bool available=true;
    unsigned acquire=0,flush=0,readback=0;
} backend;
void* acquire(BufferObject& buffer) {
    ++backend.acquire;
    if(!backend.available)return nullptr;
    if(backend.gpu.size()!=buffer.GetSize()) {
        backend.gpu.resize(buffer.GetSize());
        std::memcpy(backend.gpu.data(),buffer.MappedData(),buffer.GetSize());
    }
    return backend.gpu.data();
}
void flush(BufferObject&,Range1D,Flags<BufferMappingAccessBit>) {++backend.flush;}
void readback(BufferObject& buffer) {
    ++backend.readback;
    if(!buffer.IsBackendPersistentMapped())buffer.WritebackFromBackend({backend.gpu.data(),backend.gpu.size()},0);
}
const BufferBackendOps ops{.FlushMappedRange=flush,.AcquirePersistentMap=acquire,.ReadbackFromGpu=readback};
void check(bool value,const char* label) {
    if(!value){std::cerr<<"FAIL "<<label<<'\n';std::exit(23);}
}
void reset() {backend={};SetBufferBackendOps(&ops);}
}
int main(int argc,char** argv) {
    const bool expectOld=argc==2&&std::string(argv[1])=="--expect-pointer-move";
    if(argc==2&&std::string(argv[1])=="--expect-unbacked-read") {
        reset();backend.available=false;BufferObject buffer(9);
        buffer.AllocateImmutableStorage(256,nullptr,GL_MAP_READ_BIT|GL_MAP_PERSISTENT_BIT|GL_MAP_COHERENT_BIT);
        void* mapped=buffer.AcquireMemoryRange({0,256},BufferMappingAccessBit::Read|BufferMappingAccessBit::Persistent|BufferMappingAccessBit::Coherent);
        check(mapped!=nullptr&&buffer.IsMapped()&&!buffer.IsBackendPersistentMapped(),"old actual readable persistent map silently falls back");
        std::cout<<"PASS negative: actual implementation publishes readable persistent shadow without backend mapping\n";return 0;
    }
    // 旧实现负对照只比较地址，绝不再次解引用已经释放的shadow。
    reset();
    {
        BufferObject buffer(1);buffer.AllocateImmutableStorage(256,nullptr,GL_MAP_WRITE_BIT|GL_MAP_PERSISTENT_BIT);
        auto* original=buffer.AcquireMemoryRange({0,256},BufferMappingAccessBit::Write|BufferMappingAccessBit::Persistent|BufferMappingAccessBit::FlushExplicit);
        buffer.EnsureGpuResidentStorage();
        const bool stable=original==buffer.GetMappedPointer();
        if(expectOld){check(!stable,"old implementation must reproduce pointer replacement");std::cout<<"PASS old actual BufferObject replaces published persistent pointer\n";return 0;}
        check(stable,"explicit persistent mapping survives GPU residency");
        check(buffer.GetMappingAccess()&BufferMappingAccessBit::FlushExplicit,"caller explicit-flush flag preserved");
        std::memset(original,0x5a,16);buffer.FlushMemoryRange(0,16);
        check(buffer.MappedData()[0]==0x5a,"subsequent app write reaches authoritative storage");
        check(backend.flush==0,"coherent backing does not stage-copy or orphan a published mapping");
        buffer.ReleaseMemory();check(buffer.GetMappedPointer()==nullptr,"unmap clears public pointer");
    }
    // 读映射与不带显式flush的映射同样必须在发布前确定存储。
    for(auto access:{BufferMappingAccessBit::Read|BufferMappingAccessBit::Persistent,
                    BufferMappingAccessBit::Write|BufferMappingAccessBit::Persistent|BufferMappingAccessBit::Coherent}) {
        reset();BufferObject buffer(2);buffer.AllocateImmutableStorage(256,nullptr,GL_MAP_READ_BIT|GL_MAP_WRITE_BIT|GL_MAP_PERSISTENT_BIT|GL_MAP_COHERENT_BIT);
        void* original=buffer.AcquireMemoryRange({64,128},access);
        check(original!=nullptr,"persistent range map succeeds");
        buffer.EnsureGpuResidentStorage();check(original==buffer.GetMappedPointer(),"persistent read/coherent pointer remains stable");
        check(reinterpret_cast<uintptr_t>(original)%64==0,"map alignment retained");
        backend.gpu[64]=0x4d;buffer.MarkGpuWritten();buffer.SyncGpuWrites();
        check(static_cast<unsigned char*>(original)[0]==0x4d,"GPU result visible at original address");
        buffer.ReleaseMemory();
    }
    // 后端初次拒绝后不能在下一次用途升级时挪走fallback指针；unmap以后才允许升级。
    reset();backend.available=false;
    {
        BufferObject buffer(3);buffer.AllocateImmutableStorage(256,nullptr,GL_MAP_WRITE_BIT|GL_MAP_PERSISTENT_BIT);
        void* original=buffer.AcquireMemoryRange({0,256},BufferMappingAccessBit::Write|BufferMappingAccessBit::Persistent|BufferMappingAccessBit::FlushExplicit);
        backend.available=true;const unsigned attempts=backend.acquire;
        check(!buffer.EnsureGpuResidentStorage(),"mapped shadow cannot migrate after backend recovers");
        check(backend.acquire==attempts,"late migration must not call allocation boundary");
        check(original==buffer.GetMappedPointer(),"fallback address retained");
        backend.gpu.assign(256,0x3c);buffer.MarkGpuWritten();buffer.SyncGpuWrites();
        check(static_cast<unsigned char*>(original)[0]==0x3c,"fallback readback updates retained shadow");
        buffer.ReleaseMemory();check(buffer.EnsureGpuResidentStorage(),"unmapped storage may become resident");
    }
    // 可读persistent指针必须直接观察未来GPU写入，不能用仅在API读回时更新的shadow冒充。
    reset();backend.available=false;
    {
        BufferObject buffer(5);buffer.AllocateImmutableStorage(256,nullptr,GL_MAP_READ_BIT|GL_MAP_PERSISTENT_BIT);
        check(buffer.AcquireMemoryRange({0,256},BufferMappingAccessBit::Read|BufferMappingAccessBit::Persistent)==nullptr,
            "failed readable persistent backing is not disguised as a shadow map");
        check(!buffer.IsMapped()&&buffer.GetMappedPointer()==nullptr,"failed mapping rolls back publication state");
        backend.available=true;
        check(buffer.AcquireMemoryRange({0,256},BufferMappingAccessBit::Read|BufferMappingAccessBit::Persistent)!=nullptr,
            "mapping may retry after backend recovers");
        buffer.ReleaseMemory();
    }
    // 普通只读映射也不能被内部用途升级挪走；普通显式flush仍只复制指定范围。
    reset();
    {
        BufferObject buffer(4);unsigned char initial[128]{};buffer.Respecify(128,initial);
        void* mapped=buffer.AcquireMemory(true,true,false);check(!buffer.EnsureGpuResidentStorage(),"ordinary live map pinned");
        check(buffer.GetMappedPointer()==mapped,"ordinary map pointer retained");buffer.ReleaseMemory();
        auto* staged=static_cast<unsigned char*>(buffer.AcquireMemoryRange({32,64},BufferMappingAccessBit::Write|BufferMappingAccessBit::FlushExplicit));
        std::memset(staged,0x7a,32);buffer.FlushMemoryRange(4,4);buffer.ReleaseMemory();
        check(buffer.MappedData()[36]==0x7a&&buffer.MappedData()[32]==0,"nonpersistent flush stays range-limited");
    }
    SetBufferBackendOps(nullptr);
    std::cout<<"PASS real BufferObject: published pointer lifetime, explicit/read/coherent maps, fallback, readback, alignment and nonpersistent flush\n";
}
