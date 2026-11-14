#include "../../platform/mobilegl_capture_request.h"
#include <iostream>
int main() {
    using amcl::graphics::ParseMobileglCaptureRequest;
    const std::vector<std::string> valid{"-Damcl.mobilegl.capture=aged-near", "-Damcl.mobilegl.captureMatch=uMcColorTexture,uCombinedMcDhColorTexture"};
    auto request=ParseMobileglCaptureRequest(valid,"/private/app",42,true);
    if(!request.enabled || request.path!="/private/app/tmp/mgl-capture-aged-near-42.jsonl")return 1;
    if(ParseMobileglCaptureRequest(valid,"/private/app",42,false).enabled)return 2;
    if(ParseMobileglCaptureRequest(valid,"relative",42,true).enabled)return 3;
    if(ParseMobileglCaptureRequest(valid,"/private/app",0,true).enabled)return 4;
    // 所有非法输入必须关闭诊断，不产生可写路径，不把它们重新解释成游戏参数或shell。
    for(const auto& tag: {std::string("../other"),std::string("a/b"),std::string(""),std::string(33,'a')}) {
        auto args=valid;args[0]="-Damcl.mobilegl.capture="+tag;
        auto bad=ParseMobileglCaptureRequest(args,"/private/app",42,true);if(bad.enabled||!bad.path.empty())return 5;
    }
    for(const auto& filter: {"",",a","a,","a,,b","a b","a,b,c,d,e,f,g,h,i"}) {
        auto args=valid;args[1]=std::string("-Damcl.mobilegl.captureMatch=")+filter;
        if(ParseMobileglCaptureRequest(args,"/private/app",42,true).enabled)return 6;
    }
    auto duplicate=valid;duplicate.push_back(valid[0]);if(ParseMobileglCaptureRequest(duplicate,"/private/app",42,true).enabled)return 7;
    duplicate=valid;duplicate.push_back(valid[1]);if(ParseMobileglCaptureRequest(duplicate,"/private/app",42,true).enabled)return 8;
    std::cout<<"mobilegl capture request: developer gate, path containment, bounds and duplicate guards passed\n";
}
