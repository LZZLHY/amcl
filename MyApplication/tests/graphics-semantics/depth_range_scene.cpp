#include "depth_range_scene.h"

#include <array>
#include <cmath>
#include <iomanip>
#include <limits>
#include <sstream>
#include <utility>

namespace amcl::graphics_semantics {
namespace {
// 这些数值是 GL 公共 ABI 的枚举值；不引入平台 GL 头可避免 MG 桌面声明与
// OHOS GLES SDK 的同名原型冲突。测试函数仍全部来自调用者的生产 resolver。
using E = unsigned int;
using U = unsigned int;
using I = int;
using B = unsigned char;
using S = std::intptr_t;
constexpr E kDepthRange = 0x0B70, kRenderbufferDepthSize = 0x8D54, kDepthTest = 0x0B71;
constexpr E kLess = 0x0201, kBlend = 0x0BE2, kCull = 0x0B44, kScissor = 0x0C11;
constexpr E kDither = 0x0BD0, kFramebuffer = 0x8D40, kRenderbuffer = 0x8D41;
constexpr E kComplete = 0x8CD5, kColorAttachment = 0x8CE0, kDepthAttachment = 0x8D00;
constexpr E kRgba4 = 0x8056, kDepth16 = 0x81A5, kArrayBuffer = 0x8892;
constexpr E kStaticDraw = 0x88E4, kFloat = 0x1406, kTriangles = 0x0004;
constexpr E kVertexShader = 0x8B31, kFragmentShader = 0x8B30;
constexpr E kCompileStatus = 0x8B81, kLinkStatus = 0x8B82, kRgba = 0x1908;
constexpr E kUnsignedByte = 0x1401, kColorBuffer = 0x4000, kDepthBuffer = 0x0100;
constexpr int kWidth = 64, kRegion = 8;

// 函数表只属于本次场景，既不改 GLES 全局表，也不回退到系统同名函数。
// 指针签名沿用 GL ABI；void* resolver 到函数指针的转换用于本仓支持的 ELF 平台。
struct Api {
    void (*DepthRange)(double, double) = nullptr;
    void (*DepthRangef)(float, float) = nullptr;
    void (*GetFloatv)(E, float*) = nullptr;
    void (*GetDoublev)(E, double*) = nullptr;
    void (*GetIntegerv)(E, I*) = nullptr;
    E (*GetError)() = nullptr;
    void (*Enable)(E) = nullptr;
    void (*Disable)(E) = nullptr;
    void (*DepthFunc)(E) = nullptr;
    void (*DepthMask)(B) = nullptr;
    void (*ColorMask)(B, B, B, B) = nullptr;
    void (*ClearColor)(float, float, float, float) = nullptr;
    void (*ClearDepthf)(float) = nullptr;
    void (*Clear)(E) = nullptr;
    void (*Viewport)(I, I, I, I) = nullptr;
    void (*GenFramebuffers)(I, U*) = nullptr;
    void (*BindFramebuffer)(E, U) = nullptr;
    void (*DeleteFramebuffers)(I, const U*) = nullptr;
    E (*CheckFramebufferStatus)(E) = nullptr;
    void (*GenRenderbuffers)(I, U*) = nullptr;
    void (*BindRenderbuffer)(E, U) = nullptr;
    void (*RenderbufferStorage)(E, E, I, I) = nullptr;
    void (*GetRenderbufferParameteriv)(E, E, I*) = nullptr;
    void (*FramebufferRenderbuffer)(E, E, E, U) = nullptr;
    void (*DeleteRenderbuffers)(I, const U*) = nullptr;
    U (*CreateShader)(E) = nullptr;
    void (*ShaderSource)(U, I, const char* const*, const I*) = nullptr;
    void (*CompileShader)(U) = nullptr;
    void (*GetShaderiv)(U, E, I*) = nullptr;
    void (*GetShaderInfoLog)(U, I, I*, char*) = nullptr;
    void (*DeleteShader)(U) = nullptr;
    U (*CreateProgram)() = nullptr;
    void (*AttachShader)(U, U) = nullptr;
    void (*BindAttribLocation)(U, U, const char*) = nullptr;
    void (*LinkProgram)(U) = nullptr;
    void (*GetProgramiv)(U, E, I*) = nullptr;
    void (*GetProgramInfoLog)(U, I, I*, char*) = nullptr;
    void (*UseProgram)(U) = nullptr;
    void (*DeleteProgram)(U) = nullptr;
    I (*GetUniformLocation)(U, const char*) = nullptr;
    void (*GetUniformfv)(U, I, float*) = nullptr;
    void (*Uniform4f)(I, float, float, float, float) = nullptr;
    void (*Uniform1f)(I, float) = nullptr;
    void (*GenBuffers)(I, U*) = nullptr;
    void (*BindBuffer)(E, U) = nullptr;
    void (*BufferData)(E, S, const void*, E) = nullptr;
    void (*DeleteBuffers)(I, const U*) = nullptr;
    void (*GenVertexArrays)(I, U*) = nullptr;
    void (*BindVertexArray)(U) = nullptr;
    void (*DeleteVertexArrays)(I, const U*) = nullptr;
    void (*VertexAttribPointer)(U, I, E, B, I, const void*) = nullptr;
    void (*EnableVertexAttribArray)(U) = nullptr;
    void (*DrawArrays)(E, I, I) = nullptr;
    void (*ReadPixels)(I, I, I, I, E, E, void*) = nullptr;
    void (*Finish)() = nullptr;
};

// 文本只作为 JSON 值输出，shader 诊断中的换行、引号不会破坏 JSONL 边界。
std::string Quote(const std::string& value) {
    std::ostringstream out;
    out << '"';
    for (unsigned char c : value) {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c == '\n') out << "\\n";
        else if (c == '\r') out << "\\r";
        else if (c == '\t') out << "\\t";
        else if (c < 32) out << "?";
        else out << c;
    }
    return out.str() + '"';
}

// 每个 check 都保留固定用例身份；资源/环境失败与语义不符由 kind 区分。
void Check(DepthRangeResult& result, const char* kind, const char* name,
           bool pass, const std::string& fields = {}) {
    ++result.checks;
    if (!pass) ++result.failures;
    result.evidence += "{\"kind\":" + Quote(kind) + ",\"case\":" + Quote(name) +
        ",\"pass\":" + (pass ? "true" : "false") + fields + "}\n";
}

// 检查紧邻操作的首个错误，随后有限清空全部错误，避免一次旧错污染后续用例。
// 场景开始前另记录旧错；此函数不把旧错借给此次合法 setter 的错误判据。
bool NoError(Api& api, DepthRangeResult& result, const char* phase) {
    const E error = api.GetError();
    Check(result, "gl-error", phase, error == 0, ",\"error\":" + std::to_string(error));
    for (int i = 0; i < 32 && api.GetError() != 0; ++i) {}
    return error == 0;
}

// float 和 double 查询用不同哨兵及两端 guard；可同时检出未写第二分量和越界。
// 2e-6 是预先固定的精度容差，允许 GLES 底层 float 表示，不要求虚假的 double 精度。
void Query(Api& api, DepthRangeResult& result, const char* name, double nearValue,
           double farValue) {
    std::array<float, 4> f{73.0f, -999.0f, -998.0f, 74.0f};
    std::array<double, 4> d{83.0, -997.0, -996.0, 84.0};
    api.GetFloatv(kDepthRange, f.data() + 1);
    api.GetDoublev(kDepthRange, d.data() + 1);
    constexpr double tolerance = 2e-6;
    const auto close = [](double value, double expected) {
        return std::isfinite(value) && std::abs(value - expected) <= tolerance;
    };
    std::ostringstream fields;
    fields << std::setprecision(17) << ",\"expected\":[" << nearValue << ',' << farValue
           << "],\"tolerance\":" << tolerance;
    const auto number = [](double v) { return std::isfinite(v) ? std::to_string(v) : "null"; };
    ++result.queryChecks;
    Check(result, "float-query", name,
          f[0] == 73.0f && f[3] == 74.0f && close(f[1], nearValue) && close(f[2], farValue),
          fields.str() + ",\"actual\":[" + number(f[1]) + ',' + number(f[2]) +
          "],\"guards\":[" + number(f[0]) + ',' + number(f[3]) + ']');
    ++result.queryChecks;
    Check(result, "double-query", name,
          d[0] == 83.0 && d[3] == 84.0 && close(d[1], nearValue) && close(d[2], farValue),
          fields.str() + ",\"actual\":[" + number(d[1]) + ',' + number(d[2]) +
          "],\"guards\":[" + number(d[0]) + ',' + number(d[3]) + ']');
}

// 所有 GL 对象都由这个专用 context 的真实 provider 创建和删除。失败路径也走
// 同一对象删除入口；context 自身由调用者的生产 owner 在返回后销毁。
struct Objects {
    Api& api;
    U fbo = 0, color = 0, depth = 0, vertex = 0, fragment = 0, program = 0, buffer = 0, vao = 0;
    bool retired = false;
    void Retire() {
        if (retired) return;
        retired = true;
        api.UseProgram(0);
        api.BindFramebuffer(kFramebuffer, 0);
        if (vao) { api.BindVertexArray(0); api.DeleteVertexArrays(1, &vao); }
        if (buffer) api.DeleteBuffers(1, &buffer);
        if (program) api.DeleteProgram(program);
        if (vertex) api.DeleteShader(vertex);
        if (fragment) api.DeleteShader(fragment);
        if (depth) api.DeleteRenderbuffers(1, &depth);
        if (color) api.DeleteRenderbuffers(1, &color);
        if (fbo) api.DeleteFramebuffers(1, &fbo);
    }
    ~Objects() { Retire(); }
};

// shader 必须由真实编译器接受；编译失败保留日志并终止，不能误归因为深度 stub。
bool Compile(Api& api, DepthRangeResult& result, U shader, const char* body, const char* name) {
    api.ShaderSource(shader, 1, &body, nullptr);
    api.CompileShader(shader);
    I compiled = 0;
    api.GetShaderiv(shader, kCompileStatus, &compiled);
    std::array<char, 4096> log{};
    I length = 0;
    api.GetShaderInfoLog(shader, static_cast<I>(log.size() - 1), &length, log.data());
    Check(result, "shader", name, compiled != 0, ",\"log\":" + Quote(log.data()));
    return compiled != 0;
}

// 固定内点区域的实际 RGBA 读回就是 oracle 输入；阈值和期望颜色由用例常量
// 给出，不读取被测 GL_DEPTH_RANGE 来“反算正确值”。每次先清黑色/固定深度，
// 仅在 LESS 比较通过时绘制红色，足以区分 query-only 修复和实际绘制正确性。
void Pixels(Api& api, DepthRangeResult& result, const char* name, float clearDepth,
            bool expectedRed) {
    api.ClearDepthf(clearDepth);
    api.Clear(kColorBuffer | kDepthBuffer);
    api.DrawArrays(kTriangles, 0, 3);
    api.Finish();
    std::array<B, kRegion * kRegion * 4> pixels{};
    api.ReadPixels(28, 28, kRegion, kRegion, kRgba, kUnsignedByte, pixels.data());
    unsigned matches = 0;
    std::ostringstream raw;
    raw << std::hex << std::setfill('0');
    for (std::size_t i = 0; i < pixels.size(); i += 4) {
        const int expected = expectedRed ? 255 : 0;
        if (std::abs(static_cast<int>(pixels[i]) - expected) <= 3 &&
            pixels[i + 1] <= 3 && pixels[i + 2] <= 3 && pixels[i + 3] >= 252) ++matches;
        for (int c = 0; c < 4; ++c) raw << std::setw(2) << static_cast<int>(pixels[i + c]);
    }
    ++result.pixelChecks;
    std::ostringstream fields;
    fields << ",\"clearDepth\":" << clearDepth << ",\"expectedRed\":"
           << (expectedRed ? "true" : "false") << ",\"matchingPixels\":" << matches
           << ",\"sampledPixels\":64,\"channelTolerance\":3,\"rgba8x8Hex\":" << Quote(raw.str());
    Check(result, "pixels", name, matches == 64, fields.str());
}
}  // namespace

DepthRangeResult RunDepthRange(ResolveProc resolve, void* user, ShaderDialect dialect) {
    DepthRangeResult result;
    Api api;
    if (!resolve) { Check(result, "setup", "resolver", false); return result; }
    // 必需函数缺失时立即失败，不创建部分对象；所有地址来源的身份由调用者核验。
#define LOAD(member) do { \
    api.member = reinterpret_cast<decltype(api.member)>(resolve(user, "gl" #member)); \
    if (!api.member) { Check(result, "missing-function", "gl" #member, false); return result; } \
} while (false)
    LOAD(DepthRange); LOAD(DepthRangef); LOAD(GetFloatv); LOAD(GetDoublev); LOAD(GetIntegerv);
    LOAD(GetError); LOAD(Enable); LOAD(Disable); LOAD(DepthFunc); LOAD(DepthMask); LOAD(ColorMask);
    LOAD(ClearColor); LOAD(ClearDepthf); LOAD(Clear); LOAD(Viewport); LOAD(GenFramebuffers);
    LOAD(BindFramebuffer); LOAD(DeleteFramebuffers); LOAD(CheckFramebufferStatus);
    LOAD(GenRenderbuffers); LOAD(BindRenderbuffer); LOAD(RenderbufferStorage);
    LOAD(GetRenderbufferParameteriv);
    LOAD(FramebufferRenderbuffer); LOAD(DeleteRenderbuffers); LOAD(CreateShader); LOAD(ShaderSource);
    LOAD(CompileShader); LOAD(GetShaderiv); LOAD(GetShaderInfoLog); LOAD(DeleteShader);
    LOAD(CreateProgram); LOAD(AttachShader); LOAD(BindAttribLocation); LOAD(LinkProgram);
    LOAD(GetProgramiv); LOAD(GetProgramInfoLog); LOAD(UseProgram); LOAD(DeleteProgram);
    LOAD(GetUniformLocation); LOAD(Uniform1f); LOAD(GenBuffers); LOAD(BindBuffer); LOAD(BufferData);
    LOAD(DeleteBuffers); LOAD(VertexAttribPointer); LOAD(EnableVertexAttribArray);
    LOAD(DrawArrays); LOAD(ReadPixels); LOAD(Finish);
    if (dialect == ShaderDialect::Desktop330) {
        LOAD(GenVertexArrays); LOAD(BindVertexArray); LOAD(DeleteVertexArrays);
    }
#undef LOAD
    // 旧错误只记录，不作为本轮 setter 的新错；超过32项说明通道无法稳定清空。
    unsigned oldErrors = 0;
    while (api.GetError() != 0) {
        if (++oldErrors > 32) { Check(result, "setup", "old-error-drain", false); return result; }
    }
    result.evidence += "{\"kind\":\"preexisting-errors\",\"count\":" +
        std::to_string(oldErrors) + "}\n";
    Query(api, result, "initial-context", 0, 1);
    Objects objects{api};
    api.GenFramebuffers(1, &objects.fbo);
    api.BindFramebuffer(kFramebuffer, objects.fbo);
    api.GenRenderbuffers(1, &objects.color);
    api.BindRenderbuffer(kRenderbuffer, objects.color);
    api.RenderbufferStorage(kRenderbuffer, kRgba4, kWidth, kWidth);
    api.FramebufferRenderbuffer(kFramebuffer, kColorAttachment, kRenderbuffer, objects.color);
    api.GenRenderbuffers(1, &objects.depth);
    api.BindRenderbuffer(kRenderbuffer, objects.depth);
    api.RenderbufferStorage(kRenderbuffer, kDepth16, kWidth, kWidth);
    api.FramebufferRenderbuffer(kFramebuffer, kDepthAttachment, kRenderbuffer, objects.depth);
    const E fboStatus = api.CheckFramebufferStatus(kFramebuffer);
    Check(result, "setup", "fixed-depth-fbo", fboStatus == kComplete,
          ",\"status\":" + std::to_string(fboStatus));
    I bits = 0;
    // core桌面GL已不接受旧GL_DEPTH_BITS查询；绑定的depth renderbuffer查询同时
    // 适用于GLES和桌面core，并直接证明本次独立FBO实际取得的深度精度。
    api.GetRenderbufferParameteriv(kRenderbuffer, kRenderbufferDepthSize, &bits);
    Check(result, "setup", "fixed-depth-precision", bits >= 16,
          ",\"bits\":" + std::to_string(bits));
    if (fboStatus != kComplete || bits < 16 || !NoError(api, result, "fbo-setup")) return result;
    const char* vertex = dialect == ShaderDialect::Desktop330 ?
        "#version 330 core\nin vec2 position; uniform float clipZ; void main(){gl_Position=vec4(position,clipZ,1.0);}" :
        dialect == ShaderDialect::Desktop120 ?
        "#version 120\nattribute vec2 position; uniform float clipZ; void main(){gl_Position=vec4(position,clipZ,1.0);}" :
        "#version 100\nattribute vec2 position; uniform highp float clipZ; void main(){gl_Position=vec4(position,clipZ,1.0);}";
    const char* fragment = dialect == ShaderDialect::Desktop330 ?
        "#version 330 core\nout vec4 color; void main(){color=vec4(1.0,0.0,0.0,1.0);}" :
        dialect == ShaderDialect::Desktop120 ?
        "#version 120\nvoid main(){gl_FragColor=vec4(1.0,0.0,0.0,1.0);}" :
        "#version 100\nprecision mediump float; void main(){gl_FragColor=vec4(1.0,0.0,0.0,1.0);}";
    objects.vertex = api.CreateShader(kVertexShader);
    objects.fragment = api.CreateShader(kFragmentShader);
    if (!Compile(api, result, objects.vertex, vertex, "vertex") ||
        !Compile(api, result, objects.fragment, fragment, "fragment")) return result;
    objects.program = api.CreateProgram();
    api.AttachShader(objects.program, objects.vertex);
    api.AttachShader(objects.program, objects.fragment);
    api.BindAttribLocation(objects.program, 0, "position");
    api.LinkProgram(objects.program);
    I linked = 0;
    api.GetProgramiv(objects.program, kLinkStatus, &linked);
    std::array<char, 4096> linkLog{};
    I length = 0;
    api.GetProgramInfoLog(objects.program, static_cast<I>(linkLog.size() - 1), &length, linkLog.data());
    Check(result, "shader", "program", linked != 0, ",\"log\":" + Quote(linkLog.data()));
    if (!linked) return result;
    api.UseProgram(objects.program);
    const I zLocation = api.GetUniformLocation(objects.program, "clipZ");
    Check(result, "setup", "clip-z-uniform", zLocation >= 0);
    if (zLocation < 0) return result;
    if (dialect == ShaderDialect::Desktop330) {
        api.GenVertexArrays(1, &objects.vao);
        api.BindVertexArray(objects.vao);
    }
    // 大三角形完整覆盖内点区域，无顶点/索引位置的边界争议；Z由真实uniform输入。
    constexpr float positions[]{-1, -1, 3, -1, -1, 3};
    api.GenBuffers(1, &objects.buffer);
    api.BindBuffer(kArrayBuffer, objects.buffer);
    api.BufferData(kArrayBuffer, sizeof(positions), positions, kStaticDraw);
    api.VertexAttribPointer(0, 2, kFloat, 0, 0, nullptr);
    api.EnableVertexAttribArray(0);
    api.Viewport(0, 0, kWidth, kWidth);
    api.Disable(kBlend); api.Disable(kCull); api.Disable(kScissor); api.Disable(kDither);
    api.Enable(kDepthTest); api.DepthFunc(kLess); api.DepthMask(1); api.ColorMask(1, 1, 1, 1);
    api.ClearColor(0, 0, 0, 1);
    if (!NoError(api, result, "draw-setup")) return result;
    struct Case {
        const char* name;
        bool singlePrecision;
        double nearInput, farInput, nearExpected, farExpected;
        float clipZ, lowerThreshold, upperThreshold;
    };
    const double maxDouble = std::numeric_limits<double>::max();
    // 预期深度由规范固定：非默认mid=.25；反向Z=-.5 => .725；clamp正向Z=.5
    // => .30；反向clampZ=-.5 => .75。比较阈值远离16-bit量化和float误差。
    const Case cases[]{
        {"double-nondefault", false, .1, .4, .1, .4, 0, .20f, .30f},
        {"float-nondefault", true, .2, .6, .2, .6, .5f, .45f, .55f},
        {"double-reversed", false, .9, .2, .9, .2, -.5f, .65f, .80f},
        {"float-after-double", true, .1, .4, .1, .4, 0, .20f, .30f},
        {"double-clamp-low", false, -2, .4, 0, .4, .5f, .25f, .35f},
        {"float-clamp-high", true, .6, 2, .6, 1, -.5f, .65f, .75f},
        {"double-clamp-reversed", false, 2, -2, 1, 0, -.5f, .70f, .80f},
        {"float-reversed", true, .9, .2, .9, .2, -.5f, .65f, .80f},
        {"double-huge-finite", false, maxDouble, -maxDouble, 1, 0, -.5f, .70f, .80f},
        {"double-equal-endpoints", false, .3, .3, .3, .3, .5f, .25f, .35f},
        {"float-restores-default", true, 0, 1, 0, 1, 0, .45f, .55f},
        {"double-after-float", false, .1, .4, .1, .4, 0, .20f, .30f},
    };
    for (const auto& test : cases) {
        if (test.singlePrecision)
            api.DepthRangef(static_cast<float>(test.nearInput), static_cast<float>(test.farInput));
        else api.DepthRange(test.nearInput, test.farInput);
        Query(api, result, test.name, test.nearExpected, test.farExpected);
        if (!NoError(api, result, test.name)) return result;
        api.Uniform1f(zLocation, test.clipZ);
        Pixels(api, result, test.name, test.lowerThreshold, false);
        Pixels(api, result, test.name, test.upperThreshold, true);
        if (!NoError(api, result, "pixel-readback")) return result;
    }
    // 完成标记必须晚于实际对象删除和其GL错误检查。析构只作失败路径兜底，
    // 不能让“最后才发生的删除错误”排除在通过证据之外。
    objects.Retire();
    if (!NoError(api, result, "object-owner-retire")) return result;
    // 完整执行和语义正确是两项不同事实；negative calibration也必须完成再判断。
    result.completed = true;
    result.evidence += "{\"kind\":\"scene-end\",\"completed\":true,\"checks\":" +
        std::to_string(result.checks) + ",\"queryChecks\":" + std::to_string(result.queryChecks) +
        ",\"pixelChecks\":" + std::to_string(result.pixelChecks) + ",\"failures\":" +
        std::to_string(result.failures) + "}\n";
    return result;
}

bool ValidateCompleteDepthRangeEvidence(const DepthRangeResult& result) {
    if (!result.completed || result.queryChecks != RequiredDepthRangeCases.size() * 2 ||
        result.pixelChecks != (RequiredDepthRangeCases.size() - 1) * 2) return false;
    const auto count = [&](const std::string& prefix) {
        unsigned found = 0;
        std::istringstream lines(result.evidence);
        std::string line;
        while (std::getline(lines, line)) if (line.compare(0, prefix.size(), prefix) == 0) ++found;
        return found;
    };
    for (std::size_t i = 0; i < RequiredDepthRangeCases.size(); ++i) {
        const std::string name = RequiredDepthRangeCases[i];
        if (count("{\"kind\":\"float-query\",\"case\":" + Quote(name) + ',') != 1 ||
            count("{\"kind\":\"double-query\",\"case\":" + Quote(name) + ',') != 1 ||
            count("{\"kind\":\"pixels\",\"case\":" + Quote(name) + ',') != (i == 0 ? 0 : 2)) return false;
    }
    if (count("{\"kind\":\"gl-error\",\"case\":\"object-owner-retire\",") != 1) return false;
    const std::string terminal = "{\"kind\":\"scene-end\",\"completed\":true,\"checks\":" +
        std::to_string(result.checks) + ",\"queryChecks\":" + std::to_string(result.queryChecks) +
        ",\"pixelChecks\":" + std::to_string(result.pixelChecks) + ",\"failures\":" +
        std::to_string(result.failures) + "}\n";
    if (count("{\"kind\":\"scene-end\",") != 1 || result.evidence.size() < terminal.size() ||
        result.evidence.compare(result.evidence.size() - terminal.size(), terminal.size(), terminal) != 0) return false;
    unsigned checks = 0, failures = 0;
    std::istringstream lines(result.evidence);
    std::string line;
    while (std::getline(lines, line)) {
        if (line.find(",\"pass\":") != std::string::npos) {
            ++checks;
            if (line.find(",\"pass\":false") != std::string::npos) ++failures;
        }
    }
    return checks == result.checks && failures == result.failures;
}

DepthRangeResult RunUniformInitializer(ResolveProc resolve, void* user) {
    DepthRangeResult result;
    Api api;
    if (!resolve) { Check(result, "setup", "initializer-resolver", false); return result; }
    // 这组加载宏专供initializer机器契约提取。depth的LOAD清单与计数保持原样；
    // 新查询/setter必须仍属于调用者已冻结的同一生产映像，禁止借系统GL补符号。
#define U_LOAD(member) do { \
    api.member = reinterpret_cast<decltype(api.member)>(resolve(user, "gl" #member)); \
    if (!api.member) { Check(result, "missing-function", "gl" #member, false); return result; } \
} while (false)
    U_LOAD(GetError); U_LOAD(Disable); U_LOAD(ColorMask); U_LOAD(ClearColor); U_LOAD(Clear);
    U_LOAD(Viewport); U_LOAD(GenFramebuffers); U_LOAD(BindFramebuffer); U_LOAD(DeleteFramebuffers);
    U_LOAD(CheckFramebufferStatus); U_LOAD(GenRenderbuffers); U_LOAD(BindRenderbuffer);
    U_LOAD(RenderbufferStorage); U_LOAD(FramebufferRenderbuffer); U_LOAD(DeleteRenderbuffers);
    U_LOAD(CreateShader); U_LOAD(ShaderSource); U_LOAD(CompileShader); U_LOAD(GetShaderiv);
    U_LOAD(GetShaderInfoLog); U_LOAD(DeleteShader); U_LOAD(CreateProgram); U_LOAD(AttachShader);
    U_LOAD(BindAttribLocation); U_LOAD(LinkProgram); U_LOAD(GetProgramiv); U_LOAD(GetProgramInfoLog);
    U_LOAD(UseProgram); U_LOAD(DeleteProgram); U_LOAD(GetUniformLocation); U_LOAD(GetUniformfv);
    U_LOAD(Uniform4f); U_LOAD(GenBuffers); U_LOAD(BindBuffer); U_LOAD(BufferData); U_LOAD(DeleteBuffers);
    U_LOAD(GenVertexArrays); U_LOAD(BindVertexArray); U_LOAD(DeleteVertexArrays);
    U_LOAD(VertexAttribPointer); U_LOAD(EnableVertexAttribArray); U_LOAD(DrawArrays);
    U_LOAD(ReadPixels); U_LOAD(Finish);
#undef U_LOAD
    unsigned oldErrors = 0;
    while (api.GetError() != 0) {
        if (++oldErrors > 32) { Check(result, "setup", "initializer-old-error-drain", false); return result; }
    }
    result.evidence += "{\"kind\":\"preexisting-errors\",\"count\":" + std::to_string(oldErrors) + "}\n";
    Objects objects{api};
    api.GenFramebuffers(1, &objects.fbo);
    api.BindFramebuffer(kFramebuffer, objects.fbo);
    api.GenRenderbuffers(1, &objects.color);
    api.BindRenderbuffer(kRenderbuffer, objects.color);
    constexpr E kRgba8 = 0x8058;
    // RGBA8线性附件使.25/.5/.75量化为64/128/191；不用深度场景RGBA4的粗量化。
    api.RenderbufferStorage(kRenderbuffer, kRgba8, kWidth, kWidth);
    api.FramebufferRenderbuffer(kFramebuffer, kColorAttachment, kRenderbuffer, objects.color);
    const E status = api.CheckFramebufferStatus(kFramebuffer);
    Check(result, "setup", "initializer-rgba8-fbo", status == kComplete, ",\"status\":" + std::to_string(status));
    if (status != kComplete || !NoError(api, result, "initializer-fbo-setup")) return result;
    constexpr const char* vertex = "#version 330 core\nin vec2 position; void main(){gl_Position=vec4(position,0.0,1.0);}";
    constexpr const char* fragment = "#version 330 core\nuniform vec4 tint=vec4(0.25,0.5,0.75,1.0); out vec4 selected; void main(){selected=tint;}";
    objects.vertex = api.CreateShader(kVertexShader);
    objects.fragment = api.CreateShader(kFragmentShader);
    if (!Compile(api, result, objects.vertex, vertex, "initializer-vertex") ||
        !Compile(api, result, objects.fragment, fragment, "initializer-fragment")) return result;
    objects.program = api.CreateProgram();
    api.AttachShader(objects.program, objects.vertex); api.AttachShader(objects.program, objects.fragment);
    api.BindAttribLocation(objects.program, 0, "position");
    api.LinkProgram(objects.program);
    I linked = 0, length = 0;
    std::array<char, 4096> log{};
    api.GetProgramiv(objects.program, kLinkStatus, &linked);
    api.GetProgramInfoLog(objects.program, static_cast<I>(log.size() - 1), &length, log.data());
    Check(result, "shader", "initializer-program", linked != 0, ",\"log\":" + Quote(log.data()));
    if (!linked) return result;
    const I location = api.GetUniformLocation(objects.program, "tint");
    Check(result, "setup", "initializer-tint-location", location >= 0, ",\"location\":" + std::to_string(location));
    if (location < 0) return result;
    const auto query = [&](const char* name, const std::array<float, 4>& expected) {
        std::array<float, 6> values{73, -999, -998, -997, -996, 74};
        api.GetUniformfv(objects.program, location, values.data() + 1);
        bool pass = values.front() == 73 && values.back() == 74;
        std::ostringstream fields;
        fields << std::setprecision(9) << ",\"expected\":[";
        for (int i = 0; i < 4; ++i) fields << (i ? "," : "") << expected[i];
        fields << "],\"actual\":[";
        for (int i = 0; i < 4; ++i) {
            pass = pass && std::isfinite(values[i + 1]) && std::abs(values[i + 1] - expected[i]) <= 2e-6f;
            fields << (i ? "," : "") << (std::isfinite(values[i + 1]) ? std::to_string(values[i + 1]) : "null");
        }
        fields << "],\"guards\":[" << values.front() << ',' << values.back() << "],\"tolerance\":0.000002";
        ++result.queryChecks;
        Check(result, "uniform-query", name, pass, fields.str());
    };
    // 查询发生在任何UseProgram/setter之前，避免合法setter掩盖link初始化丢失。
    query("initializer-link-default", {.25f, .5f, .75f, 1});
    if (!NoError(api, result, "initializer-link-query")) return result;
    api.UseProgram(objects.program);
    api.GenVertexArrays(1, &objects.vao); api.BindVertexArray(objects.vao);
    constexpr float positions[]{-1, -1, 3, -1, -1, 3};
    api.GenBuffers(1, &objects.buffer); api.BindBuffer(kArrayBuffer, objects.buffer);
    api.BufferData(kArrayBuffer, sizeof(positions), positions, kStaticDraw);
    api.VertexAttribPointer(0, 2, kFloat, 0, 0, nullptr); api.EnableVertexAttribArray(0);
    api.Viewport(0, 0, kWidth, kWidth);
    api.Disable(kDepthTest); api.Disable(kBlend); api.Disable(kCull); api.Disable(kScissor); api.Disable(kDither);
    api.ColorMask(1, 1, 1, 1); api.ClearColor(0, 0, 0, 1);
    if (!NoError(api, result, "initializer-draw-setup")) return result;
    const auto pixels = [&](const char* name, const std::array<int, 4>& expected) {
        api.Clear(kColorBuffer); api.DrawArrays(kTriangles, 0, 3); api.Finish();
        std::array<B, kRegion * kRegion * 4> rgba{};
        api.ReadPixels(28, 28, kRegion, kRegion, kRgba, kUnsignedByte, rgba.data());
        unsigned matches = 0;
        std::ostringstream raw, fields;
        raw << std::hex << std::setfill('0');
        for (std::size_t i = 0; i < rgba.size(); i += 4) {
            bool match = true;
            for (int c = 0; c < 4; ++c) {
                match = match && std::abs(static_cast<int>(rgba[i + c]) - expected[c]) <= 1;
                raw << std::setw(2) << static_cast<int>(rgba[i + c]);
            }
            if (match) ++matches;
        }
        fields << ",\"expectedRgba\":[" << expected[0] << ',' << expected[1] << ',' << expected[2] << ',' << expected[3]
            << "],\"matchingPixels\":" << matches << ",\"sampledPixels\":64,\"channelTolerance\":1,\"rgba8x8Hex\":" << Quote(raw.str());
        ++result.pixelChecks;
        Check(result, "pixels", name, matches == 64, fields.str());
    };
    pixels("initializer-link-default", {64, 128, 191, 255});
    if (!NoError(api, result, "initializer-default-readback")) return result;
    api.Uniform4f(location, 0, 1, 0, 1);
    query("initializer-manual-setter", {0, 1, 0, 1});
    if (!NoError(api, result, "initializer-manual-query")) return result;
    pixels("initializer-manual-setter", {0, 255, 0, 255});
    if (!NoError(api, result, "initializer-manual-readback")) return result;
    objects.Retire();
    if (!NoError(api, result, "initializer-owner-retire")) return result;
    result.completed = true;
    result.evidence += "{\"kind\":\"initializer-scene-end\",\"completed\":true,\"checks\":" + std::to_string(result.checks) +
        ",\"queryChecks\":" + std::to_string(result.queryChecks) + ",\"pixelChecks\":" + std::to_string(result.pixelChecks) +
        ",\"failures\":" + std::to_string(result.failures) + "}\n";
    return result;
}

bool ValidateCompleteUniformInitializerEvidence(const DepthRangeResult& result) {
    if (!result.completed || result.checks != 16 || result.queryChecks != 2 || result.pixelChecks != 2) return false;
    // 固定场景只有两次query与两次pixel；额外资源/错误检查逐一存在且总数精确。
    const auto count = [&](const std::string& prefix) {
        unsigned value = 0;
        std::istringstream lines(result.evidence); std::string line;
        while (std::getline(lines, line)) if (line.compare(0, prefix.size(), prefix) == 0) ++value;
        return value;
    };
    for (const char* name : {"initializer-link-default", "initializer-manual-setter"})
        for (const char* kind : {"uniform-query", "pixels"})
            if (count("{\"kind\":" + Quote(kind) + ",\"case\":" + Quote(name) + ',') != 1) return false;
    const std::pair<const char*, const char*> required[]{
        {"setup", "initializer-rgba8-fbo"}, {"gl-error", "initializer-fbo-setup"},
        {"shader", "initializer-vertex"}, {"shader", "initializer-fragment"}, {"shader", "initializer-program"},
        {"setup", "initializer-tint-location"}, {"gl-error", "initializer-link-query"},
        {"gl-error", "initializer-draw-setup"}, {"gl-error", "initializer-default-readback"},
        {"gl-error", "initializer-manual-query"}, {"gl-error", "initializer-manual-readback"},
        {"gl-error", "initializer-owner-retire"}};
    for (const auto& item : required)
        if (count("{\"kind\":" + Quote(item.first) + ",\"case\":" + Quote(item.second) + ',') != 1) return false;
    if (count("{\"kind\":\"preexisting-errors\",") != 1) return false;
    const std::string end = "{\"kind\":\"initializer-scene-end\",\"completed\":true,\"checks\":" +
        std::to_string(result.checks) + ",\"queryChecks\":" + std::to_string(result.queryChecks) +
        ",\"pixelChecks\":" + std::to_string(result.pixelChecks) + ",\"failures\":" + std::to_string(result.failures) + "}\n";
    if (count("{\"kind\":\"initializer-scene-end\",") != 1 || result.evidence.size() < end.size() ||
        result.evidence.compare(result.evidence.size() - end.size(), end.size(), end) != 0) return false;
    unsigned checks = 0, failures = 0;
    std::istringstream lines(result.evidence); std::string line;
    while (std::getline(lines, line)) {
        if (line.find(",\"pass\":") != std::string::npos) ++checks;
        if (line.find(",\"pass\":false") != std::string::npos) ++failures;
    }
    return checks == result.checks && failures == result.failures;
}
}  // namespace amcl::graphics_semantics
