// 真实解析器/空间规则的边界测试；不尝试申请大堆，不将策略通过当成设备内存够用。
#include "../../jvm/jvm_heap_backing.h"
#include "../../jvm/jvm_heap_options.h"
#include <cassert>
#include <cstdio>
using namespace amcl::jvm;
int main() {
    HeapBackingRequest r; std::string error; uint64_t required=0;
    assert(ResolveHeapBackingRequest({},8,true,"implicit",nullptr,nullptr,r,error)&&!r.enabled);
    for(int major:{17,21,25}) {
        assert(ResolveHeapBackingRequest({"-Damcl.heapfile=1"},major,false,nullptr,nullptr,nullptr,r,error));
        assert(r.enabled && r.privateDirectory && r.explicitDirectory.empty());
        assert(ResolveHeapBackingRequest({"-XX:AllocateHeapAt=/private/heap"},major,false,nullptr,nullptr,nullptr,r,error));
        assert(r.enabled && !r.privateDirectory && r.explicitDirectory=="/private/heap");
    }
    assert(!ResolveHeapBackingRequest({"-Damcl.heapfile=1"},8,true,nullptr,nullptr,nullptr,r,error));
    assert(!ResolveHeapBackingRequest({"-Damcl.heapfile=1"},0,false,nullptr,nullptr,nullptr,r,error));
    for(const auto& extra:{"-XX:+IgnoreUnrecognizedVMOptions","-XX:Flags=x","-XX:VMOptionsFile=x"})
        assert(!ResolveHeapBackingRequest({"-Damcl.heapfile=1",extra},17,false,nullptr,nullptr,nullptr,r,error));
    assert(ResolveHeapBackingRequest({"-Damcl.heapfile=1","-XX:-IgnoreUnrecognizedVMOptions"},17,false,nullptr,nullptr,nullptr,r,error));
    for(int env=0;env<3;++env)
        assert(!ResolveHeapBackingRequest({"-Damcl.heapfile=1"},17,false,env==0?"x":nullptr,env==1?"x":nullptr,env==2?"x":nullptr,r,error));
    for(const auto& path:{"","relative"})
        assert(!ResolveHeapBackingRequest({std::string("-XX:AllocateHeapAt=")+path},17,false,nullptr,nullptr,nullptr,r,error));
    assert(!ResolveHeapBackingRequest({"-Damcl.heapfile=1","-XX:AllocateHeapAt=/x"},17,false,nullptr,nullptr,nullptr,r,error));
    assert(!ResolveHeapBackingRequest({"-XX:AllocateHeapAt=/x","-XX:AllocateHeapAt=/y"},17,false,nullptr,nullptr,nullptr,r,error));
    constexpr uint64_t mib=1048576;
    assert(!ValidateHeapFileSpace(4096*mib,false,0,required,error) && error=="heapfile_disk_unknown");
    assert(!ValidateHeapFileSpace(4096*mib,true,4096*mib,required,error) && required==5184*mib);
    assert(ValidateHeapFileSpace(4096*mib,true,required,required,error));
    assert(!ValidateHeapFileSpace(UINT64_MAX,true,UINT64_MAX,required,error));
    assert(!ValidateHeapFileSpace(0,true,UINT64_MAX,required,error));
    // marker不影响容量；磁盘针对最后显式最大堆，而不是UI/默认desired。
    HeapOptions heap;
    assert(ResolveHeapOptions(3840,{"-Damcl.heapfile=1"},false,heap,error) && heap.maximumBytes==3840*mib);
    assert(ResolveHeapOptions(3840,{"-Xmx4096m","-Damcl.heapfile=1","-XX:MaxHeapSize=8192m"},false,heap,error));
    assert(heap.maximumBytes==8192*mib);
    assert(!ValidateHeapFileSpace(heap.maximumBytes,true,8000*mib,required,error) && required==9280*mib);
    std::puts("heap backing policy: capacity, carriers, strict mode, final Xmx and disk bounds passed");
}
