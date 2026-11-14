#pragma once
#include "sdl_aux_runtime_abi.h"
namespace amcl::graphics {
struct GraphicsRuntimeBinding;
// 仅唯一graphics owner调用；其它映像通过公共C表转发，不能建立本地第二份角色账本。
int SdlAuxRuntimeOperation(const GraphicsRuntimeBinding&,uint32_t,
    const AmclSdlAuxRequestV1*,AmclSdlAuxResultV1*);
}
