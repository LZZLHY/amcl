#include "mobilegl_program_scene.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <iomanip>
#include <sstream>
#include <utility>
#include <vector>

namespace amcl::graphics_semantics {
namespace {
using E=unsigned int;using U=unsigned int;using I=int;using B=unsigned char;using S=std::intptr_t;
constexpr E kFbo=0x8d40,kRb=0x8d41,kColor=0x8ce0,kComplete=0x8cd5,kRgba8=0x8058;
constexpr E kUbo=0x8a11,kTexture=0xde1,kRgba=0x1908,kByte=0x1401,kCurrent=0x8b8d;
constexpr E kVertex=0x8b31,kFragment=0x8b30;constexpr int kWidth=64;
constexpr const char* kVertexSource="#version 400 core\nvoid main(){vec2 p=vec2(gl_VertexID==1?3.0:-1.0,gl_VertexID==2?3.0:-1.0);gl_Position=vec4(p,0,1);}";
constexpr const char* kResourceSource="#version 400 core\nlayout(std140) uniform Colors{vec4 blockTint;};uniform sampler2D image0;uniform float gain;out vec4 selected;void main(){selected=texture(image0,vec2(.5))*blockTint*gain;}";
constexpr const char* kFloatSource="#version 400 core\nuniform uint a;uniform uint b;uniform uint expectedGap;out vec4 selected;void main(){float gap=float(a)-float(b);selected=gap==float(expectedGap)?vec4(0,1,0,1):vec4(1,0,0,1);}";
constexpr const char* kDoubleSource="#version 400 core\nuniform uint a;uniform uint b;uniform uint expectedGap;out vec4 selected;void main(){double gap=double(a)-double(b);selected=gap==double(expectedGap)?vec4(0,1,0,1):vec4(1,0,0,1);}";

// GL公共ABI签名；表仅属于本场景。P_LOAD供机器manifest提取完整函数清单。
struct Api {
    // 最后一次有界错误观测仅属于此场景/线程，不是provider全局状态。count是实际
    // 非零glGetError条数；drainComplete只在真正读到0时成立，不能因达上限猜已清空。
    unsigned errorCount=0;bool errorDrainComplete=false;
    E(*GetError)()=nullptr;void(*GetIntegerv)(E,I*)=nullptr;
    void(*Enable)(E)=nullptr;void(*Disable)(E)=nullptr;void(*ColorMask)(B,B,B,B)=nullptr;
    void(*ClearColor)(float,float,float,float)=nullptr;void(*Clear)(E)=nullptr;void(*Viewport)(I,I,I,I)=nullptr;
    void(*GenFramebuffers)(I,U*)=nullptr;void(*BindFramebuffer)(E,U)=nullptr;
    void(*DeleteFramebuffers)(I,const U*)=nullptr;E(*CheckFramebufferStatus)(E)=nullptr;
    void(*GenRenderbuffers)(I,U*)=nullptr;void(*BindRenderbuffer)(E,U)=nullptr;
    void(*RenderbufferStorage)(E,E,I,I)=nullptr;void(*FramebufferRenderbuffer)(E,E,E,U)=nullptr;
    void(*DeleteRenderbuffers)(I,const U*)=nullptr;
    U(*CreateShader)(E)=nullptr;void(*ShaderSource)(U,I,const char*const*,const I*)=nullptr;
    void(*CompileShader)(U)=nullptr;void(*GetShaderiv)(U,E,I*)=nullptr;
    void(*GetShaderInfoLog)(U,I,I*,char*)=nullptr;void(*DeleteShader)(U)=nullptr;
    U(*CreateProgram)()=nullptr;void(*AttachShader)(U,U)=nullptr;void(*LinkProgram)(U)=nullptr;
    void(*GetProgramiv)(U,E,I*)=nullptr;void(*GetProgramInfoLog)(U,I,I*,char*)=nullptr;
    void(*UseProgram)(U)=nullptr;void(*DeleteProgram)(U)=nullptr;B(*IsProgram)(U)=nullptr;
    I(*GetUniformLocation)(U,const char*)=nullptr;void(*GetUniformfv)(U,I,float*)=nullptr;
    void(*GetUniformiv)(U,I,I*)=nullptr;void(*GetUniformuiv)(U,I,U*)=nullptr;
    void(*Uniform1f)(I,float)=nullptr;void(*Uniform1i)(I,I)=nullptr;
    void(*Uniform1ui)(I,U)=nullptr;void(*ProgramUniform1f)(U,I,float)=nullptr;
    U(*GetUniformBlockIndex)(U,const char*)=nullptr;void(*UniformBlockBinding)(U,U,U)=nullptr;
    void(*GenBuffers)(I,U*)=nullptr;void(*BindBuffer)(E,U)=nullptr;
    void(*BufferData)(E,S,const void*,E)=nullptr;void(*BufferSubData)(E,S,S,const void*)=nullptr;
    void(*BindBufferBase)(E,U,U)=nullptr;void(*DeleteBuffers)(I,const U*)=nullptr;
    void(*GenTextures)(I,U*)=nullptr;void(*ActiveTexture)(E)=nullptr;void(*BindTexture)(E,U)=nullptr;
    void(*TexImage2D)(E,I,I,I,I,I,E,E,const void*)=nullptr;void(*TexParameteri)(E,E,I)=nullptr;
    void(*DeleteTextures)(I,const U*)=nullptr;void(*GenVertexArrays)(I,U*)=nullptr;
    void(*BindVertexArray)(U)=nullptr;void(*DeleteVertexArrays)(I,const U*)=nullptr;
    void(*DrawArrays)(E,I,I)=nullptr;void(*ReadPixels)(I,I,I,I,E,E,void*)=nullptr;void(*Finish)()=nullptr;
};

// 日志只作为JSON字符串，控制字符不得破坏JSONL边界。
std::string Quote(const std::string& value) {
    std::ostringstream out;out<<'"';
    for(unsigned char ch:value) {
        if(ch=='"'||ch=='\\')out<<'\\'<<ch;else if(ch=='\n')out<<"\\n";
        else if(ch=='\r')out<<"\\r";else if(ch=='\t')out<<"\\t";else if(ch<32)out<<'?';else out<<ch;
    }
    return out.str()+'"';
}
// query/pixel计数按判断条数，不按标量或GL调用数；一次失败不会被随后成功覆盖。
void Check(DepthRangeResult& r,const char* kind,const char* name,bool pass,const std::string& fields={}) {
    ++r.checks;if(!pass)++r.failures;
    if(std::string(kind)=="uniform-query"||std::string(kind)=="state-query")++r.queryChecks;
    if(std::string(kind)=="pixels")++r.pixelChecks;
    r.evidence+="{\"kind\":"+Quote(kind)+",\"case\":"+Quote(name)+",\"pass\":"+(pass?"true":"false")+fields+"}\n";
}
// 取全部有界错误，而非只记首错后静默吞尾部。旧1280可能与本次新增1282并存，
// 必须由count=1且实读末尾0证明只保留原错；32个非零仍未遇0会明确不完整并失败。
E Error(Api& api) {
    api.errorCount=0;api.errorDrainComplete=false;E first=0;
    for(unsigned i=0;i<32;++i){
        const E value=api.GetError();
        if(value==0){api.errorDrainComplete=true;break;}
        if(api.errorCount==0)first=value;
        ++api.errorCount;
    }
    return first;
}
// 对normal期望0和预期单个错误使用同一个严格谓词，不把额外GL错误误记为通过。
bool ExactError(const Api& api,E actual,E expected){
    return actual==expected&&api.errorDrainComplete&&api.errorCount==(expected?1u:0u);
}
std::string ErrorFields(const Api& api){
    return ",\"errorCount\":"+std::to_string(api.errorCount)+",\"errorDrainComplete\":"+
        (api.errorDrainComplete?"true":"false");
}
// 显式cleanup才发布检查；析构仅为异常兜底，context仍由caller生产owner退休。
struct Objects {
    Api& api;std::vector<U> programs,shaders;U fbo=0,color=0,ubo=0,texture=0,vao=0;bool retired=false;
    explicit Objects(Api& value):api(value){}
    void ForgetProgram(U id){programs.erase(std::remove(programs.begin(),programs.end(),id),programs.end());}
    void Retire(){
        if(retired)return;
        retired=true;api.UseProgram(0);api.BindFramebuffer(kFbo,0);api.BindVertexArray(0);
        for(U id:programs)api.DeleteProgram(id);
        for(U id:shaders)api.DeleteShader(id);
        if(ubo)api.DeleteBuffers(1,&ubo);
        if(texture)api.DeleteTextures(1,&texture);
        if(vao)api.DeleteVertexArrays(1,&vao);
        if(color)api.DeleteRenderbuffers(1,&color);
        if(fbo)api.DeleteFramebuffers(1,&fbo);
    }
    ~Objects(){if(!retired)Retire();}
};
// 固定源码诊断有界8191字节，长度非法或截断不能凭子串认定正确拒绝。
struct Verdict{
    I status=0;E error=0;unsigned errorCount=0;bool errorDrainComplete=false;
    I declaredLogLength=-1,returnedLogLength=-1;std::string log;bool completeLog=false;
};
// GL长度以字节计，不以UTF字符或关键字计。非空声明长度包含终止NUL，返回长度
// 不含NUL；空日志可声明0或1。实际字符串字节数也必须等于returned，截短但还包含
// Float64/阶段名的日志仍不完整，不通过放宽比较掩盖provider矛盾。
bool CompleteLog(const Verdict& v){
    if(v.returnedLogLength<0||v.returnedLogLength>=8192||
       v.log.size()!=static_cast<std::size_t>(v.returnedLogLength))return false;
    if(v.returnedLogLength==0)return v.declaredLogLength==0||v.declaredLogLength==1;
    return v.declaredLogLength==v.returnedLogLength+1;
}
Verdict Compile(Api& api,U shader,const char* body){
    api.ShaderSource(shader,1,&body,nullptr);api.CompileShader(shader);Verdict v;
    api.GetShaderiv(shader,0x8b81,&v.status);api.GetShaderiv(shader,0x8b84,&v.declaredLogLength);
    std::array<char,8193> log{};api.GetShaderInfoLog(shader,8192,&v.returnedLogLength,log.data());
    v.log.assign(log.data());v.completeLog=CompleteLog(v);v.error=Error(api);
    v.errorCount=api.errorCount;v.errorDrainComplete=api.errorDrainComplete;return v;
}
Verdict Link(Api& api,U program){
    api.LinkProgram(program);Verdict v;api.GetProgramiv(program,0x8b82,&v.status);
    api.GetProgramiv(program,0x8b84,&v.declaredLogLength);
    std::array<char,8193> log{};api.GetProgramInfoLog(program,8192,&v.returnedLogLength,log.data());
    v.log.assign(log.data());v.completeLog=CompleteLog(v);v.error=Error(api);
    v.errorCount=api.errorCount;v.errorDrainComplete=api.errorDrainComplete;return v;
}
std::string Fields(const Verdict& v){
    return ",\"status\":"+std::to_string(v.status)+",\"error\":"+std::to_string(v.error)+
        ",\"errorCount\":"+std::to_string(v.errorCount)+",\"errorDrainComplete\":"+(v.errorDrainComplete?"true":"false")+
        ",\"declaredLogLength\":"+std::to_string(v.declaredLogLength)+",\"returnedLogLength\":"+std::to_string(v.returnedLogLength)+
        ",\"logBytes\":"+std::to_string(v.log.size())+",\"logComplete\":"+(v.completeLog?"true":"false")+",\"log\":"+Quote(v.log);
}
bool VerdictError(const Verdict& v,E expected){
    return v.error==expected&&v.errorDrainComplete&&v.errorCount==(expected?1u:0u);
}
bool Accepted(const Verdict& v){return v.status==1&&VerdictError(v,0)&&v.completeLog;}
// 每次先清蓝再draw/read。固定8x8内点全数匹配预先校准绿/红，不能接受遗留像素。
bool Pixels(Api& api,DepthRangeResult& r,const char* name,bool green){
    api.ClearColor(0,0,1,1);api.Clear(0x4000);const E clear=Error(api);
    api.DrawArrays(4,0,3);const E draw=Error(api);api.Finish();std::array<B,256> pixels{};
    api.ReadPixels(28,28,8,8,kRgba,kByte,pixels.data());const E read=Error(api);
    unsigned matches=0;std::ostringstream raw;raw<<std::hex<<std::setfill('0');
    for(std::size_t i=0;i<pixels.size();i+=4){bool good=true;const int expected[]{green?0:255,green?255:0,0,255};
        for(int ch=0;ch<4;++ch){good=good&&std::abs(int(pixels[i+ch])-expected[ch])<=1;raw<<std::setw(2)<<int(pixels[i+ch]);}if(good)++matches;}
    const bool pass=matches==64&&clear==0&&draw==0&&read==0;
    Check(r,"pixels",name,pass,",\"expectedRgba\":"+std::string(green?"[0,255,0,255]":"[255,0,0,255]")+
        ",\"matchingPixels\":"+std::to_string(matches)+",\"sampledPixels\":64,\"channelTolerance\":1,\"clearError\":"+std::to_string(clear)+
        ",\"drawError\":"+std::to_string(draw)+",\"readError\":"+std::to_string(read)+",\"rgba8x8Hex\":"+Quote(raw.str()));return pass;
}
// 动态uint输入不预转float，每个单分量查询有两侧guard；Float32应gap0绿/gap1红，
// FP64应gap1绿/gap0红。这两组oracle相反，防止静默Float32精度也获得通过。
bool Inputs(Api& api,DepthRangeResult& r,U program,const std::array<I,3>& locations,U gap,const char* name){
    const std::array<U,3> expected{16777217u,16777216u,gap};std::array<U,3> actual{};bool guarded=true;
    for(int i=0;i<3;++i){api.Uniform1ui(locations[i],expected[i]);std::array<U,3> value{73u,0xffffffffu,74u};
        api.GetUniformuiv(program,locations[i],value.data()+1);actual[i]=value[1];guarded=guarded&&value[0]==73u&&value[2]==74u;}
    const E error=Error(api);const bool pass=guarded&&actual==expected&&error==0;
    Check(r,"uniform-query",name,pass,",\"expected\":[16777217,16777216,"+std::to_string(gap)+"],\"actual\":["+
        std::to_string(actual[0])+','+std::to_string(actual[1])+','+std::to_string(actual[2])+
        "],\"guardsIntact\":"+(guarded?"true":"false")+",\"queryComponents\":3,\"error\":"+std::to_string(error));return pass;
}
// 明确固定分母；每case恰一条check，环境失败可保留部分证据但不得completed=true。
const std::pair<const char*,const char*> kCommon[]{
    {"setup","program-rgba8-fbo"},{"shader","program-vertex-compile"},{"shader","program-resource-compile"},{"shader","program-resource-link"},
    {"setup","program-resource-setup"},{"uniform-query","program-gain-query"},{"uniform-query","program-sampler-query"},{"pixels","program-resource-pixel"},
    {"shader","program-invalid-compile"},{"shader","program-failed-link"},{"state-query","program-failed-current"},{"pixels","program-failed-current-pixel"},
    {"api-error","program-old-location-error"},{"api-error","program-named-setter-error"},{"state-query","program-failed-location-error"},{"api-error","program-failed-reuse-error"},
    {"api-error","program-live-ubo-update"},{"pixels","program-live-ubo-pixel"},{"shader","program-repeat-invalid-compile"},{"shader","program-repeat-failed-link"},
    {"pixels","program-repeat-failed-pixel"},{"shader","program-good-recompile"},{"shader","program-good-relink"},{"setup","program-relinked-state"},
    {"pixels","program-relinked-pixel"},{"pixels","program-delete-current-pixel"},{"setup","program-deleted-retired"},{"shader","float32-companion-compile"},
    {"shader","float32-companion-link"},{"setup","float32-companion-locations"},{"uniform-query","float32-inputs-gap0"},{"pixels","float32-pixel-gap0"},
    {"uniform-query","float32-inputs-gap1"},{"pixels","float32-pixel-gap1"},{"shader","float64-compile"},{"shader","float64-link"}};
const std::pair<const char*,const char*> kUnsupported[]{
    {"state-query","float64-rejected-current"},{"pixels","float64-rejected-old-pixel"},{"api-error","float64-rejected-empty-error"}};
const std::pair<const char*,const char*> kSupported[]{
    {"setup","float64-locations"},{"api-error","float64-use"},{"uniform-query","float64-inputs-gap1"},{"pixels","float64-pixel-gap1"},
    {"uniform-query","float64-inputs-gap0"},{"pixels","float64-pixel-gap0"}};
}

DepthRangeResult RunMobileGlProgramContract(ResolveProc resolve,void* user,Float64Expectation expectation){
    DepthRangeResult r;Api api;
    if(!resolve){Check(r,"setup","program-resolver",false);return r;}
    // 地址归属由caller固定resolver验证；缺失直接未完成，没有system补齐。
#define P_LOAD(member) do { api.member=reinterpret_cast<decltype(api.member)>(resolve(user,"gl" #member)); \
    if(!api.member){Check(r,"missing-function","gl" #member,false);return r;} } while(false)
    P_LOAD(GetError);P_LOAD(GetIntegerv);P_LOAD(Enable);P_LOAD(Disable);P_LOAD(ColorMask);
    P_LOAD(ClearColor);P_LOAD(Clear);P_LOAD(Viewport);P_LOAD(GenFramebuffers);P_LOAD(BindFramebuffer);
    P_LOAD(DeleteFramebuffers);P_LOAD(CheckFramebufferStatus);P_LOAD(GenRenderbuffers);P_LOAD(BindRenderbuffer);
    P_LOAD(RenderbufferStorage);P_LOAD(FramebufferRenderbuffer);P_LOAD(DeleteRenderbuffers);
    P_LOAD(CreateShader);P_LOAD(ShaderSource);P_LOAD(CompileShader);P_LOAD(GetShaderiv);P_LOAD(GetShaderInfoLog);
    P_LOAD(DeleteShader);P_LOAD(CreateProgram);P_LOAD(AttachShader);P_LOAD(LinkProgram);P_LOAD(GetProgramiv);
    P_LOAD(GetProgramInfoLog);P_LOAD(UseProgram);P_LOAD(DeleteProgram);P_LOAD(IsProgram);P_LOAD(GetUniformLocation);
    P_LOAD(GetUniformfv);P_LOAD(GetUniformiv);P_LOAD(GetUniformuiv);P_LOAD(Uniform1f);P_LOAD(Uniform1i);
    P_LOAD(Uniform1ui);P_LOAD(ProgramUniform1f);P_LOAD(GetUniformBlockIndex);P_LOAD(UniformBlockBinding);
    P_LOAD(GenBuffers);P_LOAD(BindBuffer);P_LOAD(BufferData);P_LOAD(BufferSubData);P_LOAD(BindBufferBase);
    P_LOAD(DeleteBuffers);P_LOAD(GenTextures);P_LOAD(ActiveTexture);P_LOAD(BindTexture);P_LOAD(TexImage2D);
    P_LOAD(TexParameteri);P_LOAD(DeleteTextures);P_LOAD(GenVertexArrays);P_LOAD(BindVertexArray);
    P_LOAD(DeleteVertexArrays);P_LOAD(DrawArrays);P_LOAD(ReadPixels);P_LOAD(Finish);
#undef P_LOAD
    unsigned old=0;
    while(api.GetError()!=0)if(++old>32){Check(r,"setup","program-old-error-drain",false);return r;}
    r.evidence+="{\"kind\":\"preexisting-errors\",\"count\":"+std::to_string(old)+"}\n";
    const bool native=expectation==Float64Expectation::Supported;
    r.evidence+="{\"kind\":\"program-scene-config\",\"sceneVersion\":1,\"float64Expectation\":"+Quote(native?"Supported":"Unsupported")+
        ",\"pipeline\":\"NOT_RUN\",\"vertexFloat64\":\"NOT_RUN\",\"computeDispatch\":\"NOT_RUN\"}\n";
    Objects objects{api};bool precisionQualified=false;std::string disposition="NOT_RUN";
    // 普通返回先实际cleanup并查错，异常只有RAII兜底而没有成功marker。core字段只
    // 描述这两个精度输入的资格；即使为true也不是整个FP64/GL4/pipeline资格。
    const auto finish=[&](bool complete){
        objects.Retire();const E error=Error(api);
        Check(r,"cleanup","program-owner-retire",error==0,",\"error\":"+std::to_string(error));
        r.evidence+="{\"kind\":\"float64-disposition\",\"expectation\":"+Quote(native?"Supported":"Unsupported")+
            ",\"disposition\":"+Quote(disposition)+",\"coreFP64Qualified\":"+(precisionQualified?"true":"false")+
            ",\"qualificationScope\":\"fixed-dynamic-uint-pair\",\"fullCoreQualified\":false}\n";
        r.completed=complete;
        r.evidence+="{\"kind\":\"mobilegl-program-scene-end\",\"completed\":"+std::string(complete?"true":"false")+
            ",\"checks\":"+std::to_string(r.checks)+",\"queryChecks\":"+std::to_string(r.queryChecks)+
            ",\"pixelChecks\":"+std::to_string(r.pixelChecks)+",\"failures\":"+std::to_string(r.failures)+"}\n";return r;
    };
    api.GenFramebuffers(1,&objects.fbo);api.BindFramebuffer(kFbo,objects.fbo);
    api.GenRenderbuffers(1,&objects.color);api.BindRenderbuffer(kRb,objects.color);
    api.RenderbufferStorage(kRb,kRgba8,kWidth,kWidth);api.FramebufferRenderbuffer(kFbo,kColor,kRb,objects.color);
    const E fbo=api.CheckFramebufferStatus(kFbo),fboError=Error(api);
    Check(r,"setup","program-rgba8-fbo",fbo==kComplete&&fboError==0&&objects.fbo&&objects.color,
          ",\"status\":"+std::to_string(fbo)+",\"error\":"+std::to_string(fboError));
    if(fbo!=kComplete||fboError)return finish(false);
    const auto shader=[&](E stage,const char* body,const char* name){
        const U id=api.CreateShader(stage);objects.shaders.push_back(id);const auto v=Compile(api,id,body);
        Check(r,"shader",name,Accepted(v),Fields(v));return std::pair<U,bool>{id,Accepted(v)};
    };
    const auto program=[&](U vs,U fs){
        const U id=api.CreateProgram();objects.programs.push_back(id);api.AttachShader(id,vs);api.AttachShader(id,fs);return id;
    };
    const auto vertex=shader(kVertex,kVertexSource,"program-vertex-compile");if(!vertex.second)return finish(false);
    const auto fragment=shader(kFragment,kResourceSource,"program-resource-compile");if(!fragment.second)return finish(false);
    const U resource=program(vertex.first,fragment.first);const auto initial=Link(api,resource);
    Check(r,"shader","program-resource-link",Accepted(initial),Fields(initial));if(!Accepted(initial))return finish(false);
    api.UseProgram(resource);
    const I gain=api.GetUniformLocation(resource,"gain"),sampler=api.GetUniformLocation(resource,"image0");
    const U block=api.GetUniformBlockIndex(resource,"Colors");
    api.Uniform1f(gain,1);api.Uniform1i(sampler,3);api.ActiveTexture(0x84c3);
    api.GenTextures(1,&objects.texture);api.BindTexture(kTexture,objects.texture);
    constexpr B white[]{255,255,255,255};api.TexImage2D(kTexture,0,kRgba8,1,1,0,kRgba,kByte,white);
    api.TexParameteri(kTexture,0x2801,0x2600);api.TexParameteri(kTexture,0x2800,0x2600);
    api.UniformBlockBinding(resource,block,2);api.GenBuffers(1,&objects.ubo);api.BindBuffer(kUbo,objects.ubo);
    constexpr float green[]{0,1,0,1};api.BufferData(kUbo,sizeof(green),green,0x88e4);api.BindBufferBase(kUbo,2,objects.ubo);
    api.GenVertexArrays(1,&objects.vao);api.BindVertexArray(objects.vao);api.Viewport(0,0,kWidth,kWidth);
    for(E cap:{0xb71u,0xbe2u,0xb44u,0xc11u,0xbd0u})api.Disable(cap);
    api.ColorMask(1,1,1,1);
    const E setupError=Error(api);
    const bool setup=gain>=0&&sampler>=0&&block!=0xffffffffu&&objects.ubo&&objects.texture&&objects.vao&&setupError==0;
    Check(r,"setup","program-resource-setup",setup,",\"gainLocation\":"+std::to_string(gain)+",\"samplerLocation\":"+
        std::to_string(sampler)+",\"blockIndex\":"+std::to_string(block)+",\"samplerUnit\":3,\"uboBinding\":2,\"error\":"+std::to_string(setupError));
    if(!setup)return finish(false);
    std::array<float,3> gv{73,-999,74};api.GetUniformfv(resource,gain,gv.data()+1);const E ge=Error(api);
    Check(r,"uniform-query","program-gain-query",gv[0]==73&&gv[2]==74&&std::isfinite(gv[1])&&gv[1]==1&&ge==0,
        ",\"expected\":1,\"actual\":"+(std::isfinite(gv[1])?std::to_string(gv[1]):"null")+",\"guards\":["+
        std::to_string(gv[0])+','+std::to_string(gv[2])+"],\"error\":"+std::to_string(ge));
    std::array<I,3> sv{73,-999,74};api.GetUniformiv(resource,sampler,sv.data()+1);const E se=Error(api);
    Check(r,"uniform-query","program-sampler-query",sv[0]==73&&sv[2]==74&&sv[1]==3&&se==0,
        ",\"expected\":3,\"actual\":"+std::to_string(sv[1])+",\"guards\":["+std::to_string(sv[0])+','+std::to_string(sv[2])+"],\"error\":"+std::to_string(se));
    Pixels(api,r,"program-resource-pixel",true);
    const auto invalid=Compile(api,fragment.first,"#version 400 core\ninvalid_body !!!");
    Check(r,"shader","program-invalid-compile",invalid.status==0&&VerdictError(invalid,0)&&invalid.completeLog&&!invalid.log.empty(),Fields(invalid));
    const auto failed=Link(api,resource);
    Check(r,"shader","program-failed-link",failed.status==0&&VerdictError(failed,0)&&failed.completeLog&&!failed.log.empty(),Fields(failed));
    I current=-1;api.GetIntegerv(kCurrent,&current);E error=Error(api);
    Check(r,"state-query","program-failed-current",current==static_cast<I>(resource)&&error==0,
        ",\"expected\":"+std::to_string(resource)+",\"actual\":"+std::to_string(current)+",\"error\":"+std::to_string(error));
    Pixels(api,r,"program-failed-current-pixel",true);
    // 四个公开API单独取1282：旧location写、新named写、失败location读、重新Use；
    // 仍current的旧exe只保护draw，不为最近失败metadata伪造成功。
    api.Uniform1f(gain,2);error=Error(api);Check(r,"api-error","program-old-location-error",ExactError(api,error,1282),",\"operation\":\"glUniform1f\",\"expectedError\":1282,\"error\":"+std::to_string(error)+ErrorFields(api));
    api.ProgramUniform1f(resource,gain,2);error=Error(api);Check(r,"api-error","program-named-setter-error",ExactError(api,error,1282),",\"operation\":\"glProgramUniform1f\",\"expectedError\":1282,\"error\":"+std::to_string(error)+ErrorFields(api));
    const I failedLocation=api.GetUniformLocation(resource,"gain");error=Error(api);
    Check(r,"state-query","program-failed-location-error",failedLocation==-1&&ExactError(api,error,1282),",\"actual\":"+std::to_string(failedLocation)+",\"expected\":-1,\"expectedError\":1282,\"error\":"+std::to_string(error)+ErrorFields(api));
    api.UseProgram(resource);error=Error(api);Check(r,"api-error","program-failed-reuse-error",ExactError(api,error,1282),",\"operation\":\"glUseProgram\",\"expectedError\":1282,\"error\":"+std::to_string(error)+ErrorFields(api));
    api.BindBuffer(kUbo,objects.ubo);constexpr float red[]{1,0,0,1};api.BufferSubData(kUbo,0,sizeof(red),red);error=Error(api);
    Check(r,"api-error","program-live-ubo-update",error==0,",\"expectedError\":0,\"error\":"+std::to_string(error));Pixels(api,r,"program-live-ubo-pixel",false);
    const auto rc=Compile(api,fragment.first,"#version 400 core\nsecond_invalid_body !!!");
    Check(r,"shader","program-repeat-invalid-compile",rc.status==0&&VerdictError(rc,0)&&rc.completeLog&&!rc.log.empty(),Fields(rc));
    const auto repeated=Link(api,resource);
    Check(r,"shader","program-repeat-failed-link",repeated.status==0&&VerdictError(repeated,0)&&repeated.completeLog&&!repeated.log.empty(),Fields(repeated));
    Pixels(api,r,"program-repeat-failed-pixel",false);
    const auto good=Compile(api,fragment.first,kResourceSource);Check(r,"shader","program-good-recompile",Accepted(good),Fields(good));
    const auto relink=Link(api,resource);Check(r,"shader","program-good-relink",Accepted(relink),Fields(relink));if(!Accepted(relink))return finish(false);
    const I gain2=api.GetUniformLocation(resource,"gain"),sampler2=api.GetUniformLocation(resource,"image0");const U block2=api.GetUniformBlockIndex(resource,"Colors");
    api.Uniform1f(gain2,1);api.Uniform1i(sampler2,3);api.UniformBlockBinding(resource,block2,2);error=Error(api);
    Check(r,"setup","program-relinked-state",gain2>=0&&sampler2>=0&&block2!=0xffffffffu&&error==0,",\"error\":"+std::to_string(error));
    Pixels(api,r,"program-relinked-pixel",false);api.DeleteProgram(resource);Pixels(api,r,"program-delete-current-pixel",false);
    api.UseProgram(0);const B remains=api.IsProgram(resource);error=Error(api);
    Check(r,"setup","program-deleted-retired",remains==0&&error==0,",\"isProgram\":"+std::to_string(remains)+",\"error\":"+std::to_string(error));objects.ForgetProgram(resource);
    // Float32伴随程序先证明动态uint/真实像素路径可用，保持gap1红供拒绝分支核旧current。
    const auto companion=shader(kFragment,kFloatSource,"float32-companion-compile");if(!companion.second)return finish(false);
    const U fp=program(vertex.first,companion.first);const auto fl=Link(api,fp);
    Check(r,"shader","float32-companion-link",Accepted(fl),Fields(fl));if(!Accepted(fl))return finish(false);
    api.UseProgram(fp);std::array<I,3> loc{api.GetUniformLocation(fp,"a"),api.GetUniformLocation(fp,"b"),api.GetUniformLocation(fp,"expectedGap")};error=Error(api);
    const bool fr=*std::min_element(loc.begin(),loc.end())>=0&&error==0;
    Check(r,"setup","float32-companion-locations",fr,",\"error\":"+std::to_string(error));if(!fr)return finish(false);
    Inputs(api,r,fp,loc,0,"float32-inputs-gap0");Pixels(api,r,"float32-pixel-gap0",true);
    Inputs(api,r,fp,loc,1,"float32-inputs-gap1");Pixels(api,r,"float32-pixel-gap1",false);
    // 在当前Float32伴随对象本身重链接，不另造非current精度程序。Unsupported下
    // 新guard已建立反射后失败，必须保留刚才gap1的红色旧exe；Supported下成功link
    // 安装真实double版本，随后用同对象的新locations写入两种固定输入。
    const auto precise=Compile(api,companion.first,kDoubleSource);
    Check(r,"shader","float64-compile",Accepted(precise),Fields(precise));if(!Accepted(precise))return finish(false);
    const U dp=fp;
    // 非法cap公开路径建立旧1280，不先查错。link/status/log必须保留该旧错；
    // 精度不足自身是link失败，不是新GL API错误。
    api.Enable(0xdeadu);const auto dl=Link(api,dp);
    const bool rejection=dl.status==0&&dl.completeLog&&dl.log.find("Float64")!=std::string::npos&&dl.log.find("GL_FRAGMENT_SHADER")!=std::string::npos;
    Check(r,"shader","float64-link",VerdictError(dl,1280)&&(native?dl.status==1&&dl.completeLog:rejection),
        Fields(dl)+",\"expectedLink\":"+std::to_string(native?1:0)+",\"expectedError\":1280");
    // 同一种GL错误标志会合并，首轮count1不能排除又产生了同类1280。首轮已实际
    // 观察尾0后，对同一合法shader/program再真实link一次；这次没有旧错可借。
    // 复用原分支case记录完整fresh Verdict，保持40/43分母及旧case身份。
    const auto fresh=Link(api,dp);
    const bool freshRejection=fresh.status==0&&fresh.completeLog&&fresh.log.find("Float64")!=std::string::npos&&
        fresh.log.find("GL_FRAGMENT_SHADER")!=std::string::npos;
    if(!native){
        disposition=rejection&&freshRejection?"limited-rejected":"unexpected-link-result";
        api.GetIntegerv(kCurrent,&current);error=Error(api);
        Check(r,"state-query","float64-rejected-current",current==static_cast<I>(fp)&&error==0,
            ",\"expected\":"+std::to_string(fp)+",\"actual\":"+std::to_string(current)+",\"error\":"+std::to_string(error));
        Pixels(api,r,"float64-rejected-old-pixel",false);
        Check(r,"api-error","float64-rejected-empty-error",freshRejection&&VerdictError(fresh,0),
            Fields(fresh)+",\"freshLink\":true,\"expectedLink\":0,\"expectedError\":0");
    }else{
        if(dl.status!=1){disposition="unexpected-link-rejection";return finish(false);}
        if(fresh.status!=1){
            Check(r,"api-error","float64-use",false,Fields(fresh)+",\"freshLink\":true,\"expectedLink\":1,\"expectedError\":0");
            disposition="unexpected-fresh-link-rejection";return finish(false);
        }
        // 第二次成功link重置uniform且locations属于新安装版本，必须重新取得，不能
        // 沿用首轮或Float32的location和值使新shader绕过真实query/setter校准。
        const std::array<I,3> locations{api.GetUniformLocation(dp,"a"),api.GetUniformLocation(dp,"b"),api.GetUniformLocation(dp,"expectedGap")};error=Error(api);
        const bool ready=*std::min_element(locations.begin(),locations.end())>=0&&error==0;
        Check(r,"setup","float64-locations",ready,",\"error\":"+std::to_string(error));if(!ready)return finish(false);
        api.UseProgram(dp);error=Error(api);
        Check(r,"api-error","float64-use",Accepted(fresh)&&ExactError(api,error,0),
            Fields(fresh)+",\"freshLink\":true,\"expectedLink\":1,\"expectedError\":0,\"useError\":"+std::to_string(error)+
            ",\"useErrorCount\":"+std::to_string(api.errorCount)+",\"useErrorDrainComplete\":"+(api.errorDrainComplete?"true":"false"));
        const bool q1=Inputs(api,r,dp,locations,1,"float64-inputs-gap1"),p1=Pixels(api,r,"float64-pixel-gap1",true);
        const bool q0=Inputs(api,r,dp,locations,0,"float64-inputs-gap0"),p0=Pixels(api,r,"float64-pixel-gap0",false);
        precisionQualified=q1&&p1&&q0&&p0&&error==0&&dl.status==1&&dl.completeLog&&VerdictError(dl,1280)&&Accepted(fresh);
        disposition=precisionQualified?"native-values-verified":"precision-mismatch";
    }
    return finish(true);
}

bool ValidateCompleteMobileGlProgramEvidence(const DepthRangeResult& r){
    if(!r.completed)return false;
    const bool supported=r.checks==43&&r.queryChecks==8&&r.pixelChecks==10;
    const bool unsupported=r.checks==40&&r.queryChecks==7&&r.pixelChecks==9;
    if(!supported&&!unsupported)return false;
    const auto count=[&](const std::string& prefix){unsigned n=0;std::istringstream lines(r.evidence);std::string line;
        while(std::getline(lines,line))if(line.compare(0,prefix.size(),prefix)==0)++n;
        return n;};
    const auto one=[&](const std::pair<const char*,const char*>& item){return count("{\"kind\":"+Quote(item.first)+",\"case\":"+Quote(item.second)+',')==1;};
    for(const auto& item:kCommon)if(!one(item))return false;
    if(supported){for(const auto& item:kSupported)if(!one(item))return false;}else{for(const auto& item:kUnsupported)if(!one(item))return false;}
    if(!one({"cleanup","program-owner-retire"}))return false;
    for(const char* kind:{"preexisting-errors","program-scene-config","float64-disposition","mobilegl-program-scene-end"})
        if(count("{\"kind\":"+Quote(kind)+',')!=1)return false;
    if(count("{\"kind\":\"program-scene-config\",\"sceneVersion\":1,\"float64Expectation\":"+Quote(supported?"Supported":"Unsupported"))!=1)return false;
    const std::string end="{\"kind\":\"mobilegl-program-scene-end\",\"completed\":true,\"checks\":"+std::to_string(r.checks)+
        ",\"queryChecks\":"+std::to_string(r.queryChecks)+",\"pixelChecks\":"+std::to_string(r.pixelChecks)+",\"failures\":"+std::to_string(r.failures)+"}\n";
    unsigned lineCount=0,falseCount=0;std::istringstream all(r.evidence);std::string line;
    while(std::getline(all,line)){++lineCount;if(line.find(",\"pass\":false")!=std::string::npos)++falseCount;}
    unsigned checks=0;for(const char* kind:{"setup","shader","uniform-query","state-query","pixels","api-error","cleanup"})
        checks+=count("{\"kind\":"+Quote(kind)+",\"case\":");
    return checks==r.checks&&falseCount==r.failures&&lineCount==r.checks+4&&r.evidence.size()>=end.size()&&
        r.evidence.compare(r.evidence.size()-end.size(),end.size(),end)==0;
}
}
