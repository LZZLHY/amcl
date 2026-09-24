// MG runtime contract probe: actual GL/GLSL/EGL operations, in a disposable child.
// Built only with MC_OHOS_BUILD_TESTS. No game context, config, or save is modified.
#include "../utils/amcl_log.h"
#include "tests.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl32.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <mutex>
#include <signal.h>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

namespace
{
constexpr const char *kProbeDir = "/data/storage/el2/base/haps/entry/files/mg-render-probe";
constexpr const char *kReport = "/data/storage/el2/base/haps/entry/files/mg-render-probe/result.txt";
std::string result;
std::mutex probeMutex;
FILE *report = nullptr;
unsigned checks = 0, failures = 0;
bool fsrExpected = false;
void emit(const std::string &text)
{
    if (report)
    {
        std::fprintf(report, "%s\n", text.c_str());
        std::fflush(report);
    }
}
void check(const char *name, bool ok, const std::string &detail = {})
{
    ++checks;
    if (!ok)
        ++failures;
    emit(std::string(ok ? "PASS " : "FAIL ") + name + (detail.empty() ? "" : " : " + detail));
}
struct InitReport
{
    uint32_t size, abi;
    int32_t state, error;
    char stage[64];
};
struct Api
{
    void *lib = nullptr;
#define GL_PROC(name) decltype(&::name) name = nullptr;
    GL_PROC(glGetError)
    GL_PROC(glGetString) GL_PROC(glGetIntegerv) GL_PROC(glGetFloatv) GL_PROC(glCreateShader) GL_PROC(glShaderSource)
        GL_PROC(glCompileShader) GL_PROC(glGetShaderiv) GL_PROC(glGetShaderInfoLog) GL_PROC(glGetShaderSource) GL_PROC(
            glDeleteShader) GL_PROC(glCreateProgram) GL_PROC(glAttachShader) GL_PROC(glLinkProgram)
            GL_PROC(glGetProgramiv) GL_PROC(glGetProgramInfoLog) GL_PROC(glUseProgram) GL_PROC(glDeleteProgram) GL_PROC(
                glGetUniformLocation) GL_PROC(glGetUniformiv) GL_PROC(glGenTextures) GL_PROC(glBindTexture)
                GL_PROC(glTexImage2D) GL_PROC(glTexStorage2D) GL_PROC(glTexParameteri) GL_PROC(glGetTexLevelParameteriv)
                    GL_PROC(glActiveTexture) GL_PROC(glDeleteTextures) GL_PROC(glGenFramebuffers) GL_PROC(
                        glBindFramebuffer) GL_PROC(glFramebufferTexture2D) GL_PROC(glDrawBuffers) GL_PROC(glReadBuffer)
                        GL_PROC(glCheckFramebufferStatus) GL_PROC(glDeleteFramebuffers) GL_PROC(glGenVertexArrays)
                            GL_PROC(glBindVertexArray) GL_PROC(glDeleteVertexArrays) GL_PROC(glGenBuffers)
                                GL_PROC(glBindBuffer) GL_PROC(glBufferData) GL_PROC(glGetBufferParameteriv)
                                    GL_PROC(glDeleteBuffers) GL_PROC(glViewport) GL_PROC(glClearColor) GL_PROC(glClear)
                                        GL_PROC(glDrawArrays) GL_PROC(glReadPixels) GL_PROC(glFinish)
                                            GL_PROC(glPixelStorei) GL_PROC(glEnable) GL_PROC(glDisable)
                                                GL_PROC(glIsEnabled) GL_PROC(glColorMask) GL_PROC(glScissor)
                                                    GL_PROC(glGetBooleanv) GL_PROC(eglGetDisplay) GL_PROC(eglInitialize)
                                                        GL_PROC(eglBindAPI) GL_PROC(eglChooseConfig)
                                                            GL_PROC(eglCreatePbufferSurface) GL_PROC(eglCreateContext)
                                                                GL_PROC(eglMakeCurrent) GL_PROC(eglDestroySurface)
                                                                    GL_PROC(eglDestroyContext) GL_PROC(eglGetError)
                                                                        GL_PROC(eglQueryContext) GL_PROC(eglSwapBuffers)
#undef GL_PROC
                                                                            void (*bindFrag)(GLuint, GLuint,
                                                                                             const GLchar *) = nullptr;
    void (*drawBuffer)(GLenum) = nullptr;
    bool load()
    {
        // MG 探针明确选中其独立 provider，窗口 facade 不再隐式装载 MG。
        lib = dlopen("libamcl_gl_host.so", RTLD_NOW | RTLD_LOCAL);
        if (!lib)
        {
            emit(std::string("FAIL dlopen: ") + dlerror());
            return false;
        }
        using Init = int (*)(InitReport *);
        auto init = reinterpret_cast<Init>(dlsym(lib, "mg_initialize_v1"));
        InitReport r{sizeof(r), 1, 0, 0, {}};
        emit("BEGIN initialize MG");
        if (!init || !init(&r))
        {
            emit("FAIL initialize stage=" + std::string(r.stage));
            return false;
        }
        Dl_info info{};
        dladdr(reinterpret_cast<void *>(init), &info);
        emit(std::string("IMAGE ") + (info.dli_fname ? info.dli_fname : "unknown"));
        if (info.dli_fname)
        {
            std::ifstream input(info.dli_fname, std::ios::binary);
            std::ofstream copy(std::string(kProbeDir) + "/loaded-libglfw.so", std::ios::binary);
            copy << input.rdbuf();
            emit(std::string("IMAGE_COPY ") + (input && copy ? "OK" : "FAILED"));
        }
        bool ok = true;
#define LOAD(name)                                                                                                     \
    name = reinterpret_cast<decltype(name)>(dlsym(lib, #name));                                                        \
    if (!name)                                                                                                         \
    {                                                                                                                  \
        emit("FAIL missing " #name);                                                                                   \
        ok = false;                                                                                                    \
    }
        LOAD(glGetError)
        LOAD(glGetString) LOAD(glGetIntegerv) LOAD(glGetFloatv) LOAD(glCreateShader) LOAD(glShaderSource) LOAD(
            glCompileShader) LOAD(glGetShaderiv) LOAD(glGetShaderInfoLog) LOAD(glGetShaderSource) LOAD(glDeleteShader)
            LOAD(glCreateProgram) LOAD(glAttachShader) LOAD(glLinkProgram) LOAD(glGetProgramiv)
                LOAD(glGetProgramInfoLog) LOAD(glUseProgram) LOAD(glDeleteProgram) LOAD(glGetUniformLocation) LOAD(
                    glGetUniformiv) LOAD(glGenTextures) LOAD(glBindTexture) LOAD(glTexImage2D) LOAD(glTexStorage2D)
                    LOAD(glTexParameteri) LOAD(glGetTexLevelParameteriv) LOAD(glActiveTexture) LOAD(glDeleteTextures)
                        LOAD(glGenFramebuffers) LOAD(glBindFramebuffer) LOAD(glFramebufferTexture2D) LOAD(glDrawBuffers)
                            LOAD(glReadBuffer) LOAD(glCheckFramebufferStatus) LOAD(glDeleteFramebuffers) LOAD(
                                glGenVertexArrays) LOAD(glBindVertexArray) LOAD(glDeleteVertexArrays) LOAD(glGenBuffers)
                                LOAD(glBindBuffer) LOAD(glBufferData) LOAD(glGetBufferParameteriv) LOAD(glDeleteBuffers)
                                    LOAD(glViewport) LOAD(glClearColor) LOAD(glClear) LOAD(glDrawArrays)
                                        LOAD(glReadPixels) LOAD(glFinish) LOAD(glPixelStorei) LOAD(glEnable)
                                            LOAD(glDisable) LOAD(glIsEnabled) LOAD(glColorMask) LOAD(glScissor)
                                                LOAD(glGetBooleanv) LOAD(eglSwapBuffers) LOAD(eglGetDisplay)
                                                    LOAD(eglInitialize) LOAD(eglBindAPI) LOAD(eglChooseConfig)
                                                        LOAD(eglCreatePbufferSurface) LOAD(eglCreateContext)
                                                            LOAD(eglMakeCurrent) LOAD(eglDestroySurface)
                                                                LOAD(eglDestroyContext) LOAD(eglGetError)
                                                                    LOAD(eglQueryContext)
#undef LOAD
                                                                        bindFrag = reinterpret_cast<decltype(bindFrag)>(
                                                                            dlsym(lib, "glBindFragDataLocation"));
        drawBuffer = reinterpret_cast<decltype(drawBuffer)>(dlsym(lib, "glDrawBuffer"));
        return ok && bindFrag && drawBuffer;
    }
    void drain()
    {
        for (int i = 0; i < 16 && glGetError() != GL_NO_ERROR; ++i)
        {
        }
    }
    std::string shaderLog(GLuint shader)
    {
        char text[4096]{};
        glGetShaderInfoLog(shader, sizeof(text), nullptr, text);
        return text;
    }
    std::string programLog(GLuint program)
    {
        char text[4096]{};
        glGetProgramInfoLog(program, sizeof(text), nullptr, text);
        return text;
    }
    GLuint shader(GLenum type, const char *source)
    {
        GLuint s = glCreateShader(type);
        glShaderSource(s, 1, &source, nullptr);
        glCompileShader(s);
        GLint ok = 0;
        glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
        check("shader compile", ok == GL_TRUE, shaderLog(s));
        return s;
    }
    GLuint program(GLuint vs, GLuint fs, GLuint output)
    {
        GLuint p = glCreateProgram();
        bindFrag(p, output, "color");
        glAttachShader(p, vs);
        glAttachShader(p, fs);
        glLinkProgram(p);
        GLint ok = 0;
        glGetProgramiv(p, GL_LINK_STATUS, &ok);
        check("program link", ok == GL_TRUE, programLog(p));
        return p;
    }
    GLuint texture(unsigned char r, unsigned char g, unsigned char b)
    {
        GLuint t = 0;
        glGenTextures(1, &t);
        glBindTexture(GL_TEXTURE_2D, t);
        unsigned char px[4] = {r, g, b, 255};
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        return t;
    }
    bool pixel(GLenum attachment, unsigned r, unsigned g, unsigned b)
    {
        unsigned char px[4]{};
        glReadBuffer(attachment);
        glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
        emit("PIXEL attachment=" + std::to_string(attachment) + " rgba=" + std::to_string(px[0]) + "," +
             std::to_string(px[1]) + "," + std::to_string(px[2]) + "," + std::to_string(px[3]));
        return px[0] == r && px[1] == g && px[2] == b;
    }
};
int probe()
{
    Api a;
    if (!a.load())
        return 2;
    auto display = a.eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (!a.eglInitialize(display, nullptr, nullptr) || !a.eglBindAPI(EGL_OPENGL_ES_API))
    {
        emit("FAIL EGL initialize");
        return 2;
    }
    EGLint configAttrs[] = {EGL_SURFACE_TYPE,
                            EGL_PBUFFER_BIT,
                            EGL_RENDERABLE_TYPE,
                            EGL_OPENGL_ES3_BIT,
                            EGL_RED_SIZE,
                            8,
                            EGL_GREEN_SIZE,
                            8,
                            EGL_BLUE_SIZE,
                            8,
                            EGL_ALPHA_SIZE,
                            8,
                            EGL_NONE};
    EGLConfig config{};
    EGLint count = 0;
    if (!a.eglChooseConfig(display, configAttrs, &config, 1, &count) || count < 1)
    {
        emit("FAIL EGL config");
        return 2;
    }
    EGLint pbAttrs[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE},
           ctxAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLSurface surface = a.eglCreatePbufferSurface(display, config, pbAttrs);
    EGLContext context = a.eglCreateContext(display, config, EGL_NO_CONTEXT, ctxAttrs);
    if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT || !a.eglMakeCurrent(display, surface, surface, context))
    {
        emit("FAIL EGL current error=" + std::to_string(a.eglGetError()));
        return 2;
    }
    for (GLenum field : {GL_VENDOR, GL_RENDERER, GL_VERSION, GL_SHADING_LANGUAGE_VERSION})
    {
        const auto *text = a.glGetString(field);
        emit("GL " + std::to_string(field) + "=" + (text ? reinterpret_cast<const char *>(text) : "NULL"));
    }
    a.drain();
    a.glBindBuffer(0xffffffffu, 0);
    check("invalid enum remains visible", a.glGetError() != GL_NO_ERROR);
    a.drain();
    GLuint multi = a.glCreateShader(GL_VERTEX_SHADER);
    const char *parts[] = {"#version 330\n", "void main(){gl_Position=vec4(0.0);}\n"};
    GLint lengths[] = {-1, static_cast<GLint>(strlen(parts[1]))};
    a.glShaderSource(multi, 2, parts, lengths);
    a.glCompileShader(multi);
    GLint ok = 0;
    a.glGetShaderiv(multi, GL_COMPILE_STATUS, &ok);
    check("multi-source count/length", ok == GL_TRUE, a.shaderLog(multi));
    const char *invalid = "#version 460\nthis is deliberately invalid";
    a.glShaderSource(multi, 1, &invalid, nullptr);
    a.glCompileShader(multi);
    a.glGetShaderiv(multi, GL_COMPILE_STATUS, &ok);
    check("translation failure status", !ok && !a.shaderLog(multi).empty());
    const char *empty = "";
    a.glShaderSource(multi, 1, &empty, nullptr);
    char text[32] = {1};
    a.glGetShaderSource(multi, sizeof(text), nullptr, text);
    check("empty source replaces old text", text[0] == 0);
    a.glDeleteShader(multi);
    a.drain();
    const char *vertex =
        "#version 330\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.0-1.0,0.0,1.0);}";
    const char *fragment = "#version 330\nout vec4 color;void main(){color=vec4(1.0,0.0,0.0,1.0);}";
    GLuint vs = a.shader(GL_VERTEX_SHADER, vertex), fs = a.shader(GL_FRAGMENT_SHADER, fragment);
    GLuint unrelated =
        a.shader(GL_FRAGMENT_SHADER, "#version 330\nout vec4 color;void main(){color=vec4(0.0,1.0,0.0,1.0);}");
    GLuint p = a.program(vs, fs, 0), vao = 0;
    a.glGenVertexArrays(1, &vao);
    a.glBindVertexArray(vao);
    GLuint targets[] = {a.texture(0, 0, 0), a.texture(0, 0, 0), a.texture(0, 0, 0)}, fb = 0;
    a.glGenFramebuffers(1, &fb);
    a.glBindFramebuffer(GL_FRAMEBUFFER, fb);
    a.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, targets[0], 0);
    a.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, targets[1], 0);
    check("framebuffer complete", a.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
    a.glViewport(0, 0, 1, 1);
    a.glUseProgram(p);
    a.drawBuffer(GL_COLOR_ATTACHMENT1);
    a.glDrawArrays(GL_TRIANGLES, 0, 3);
    a.glFinish();
    check("single-output ATTACHMENT1 renders red", a.pixel(GL_COLOR_ATTACHMENT1, 255, 0, 0));
    check("interleaved shader does not alter target program", a.pixel(GL_COLOR_ATTACHMENT0, 0, 0, 0));
    GLenum slots[] = {GL_COLOR_ATTACHMENT1};
    a.glDrawBuffers(1, slots);
    a.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, targets[2], 0);
    a.glDrawArrays(GL_TRIANGLES, 0, 3);
    a.glFinish();
    check("replacement attachment retains output route", a.pixel(GL_COLOR_ATTACHMENT1, 255, 0, 0));
    check("unselected logical attachment preserved", a.pixel(GL_COLOR_ATTACHMENT0, 0, 0, 0));
    const char *explicitFS =
        "#version 430\n#define SLOT 0\nlayout(location=SLOT) out vec4 color;void main(){color=vec4(0.0,0.0,1.0,1.0);}";
    GLuint explicitShader = a.shader(GL_FRAGMENT_SHADER, explicitFS),
           explicitProgram = a.program(vs, explicitShader, 1);
    GLenum identity[] = {GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1};
    a.glDrawBuffers(2, identity);
    a.glUseProgram(explicitProgram);
    a.glDrawArrays(GL_TRIANGLES, 0, 3);
    a.glFinish();
    check("explicit output location beats API binding", a.pixel(GL_COLOR_ATTACHMENT0, 0, 0, 255));
    GLuint sampled = a.shader(GL_FRAGMENT_SHADER, "#version 430\nlayout(binding=4) uniform sampler2D tex;out vec4 "
                                                  "color;void main(){color=texture(tex,vec2(0.5));}"),
           sampleProgram = a.program(vs, sampled, 0);
    GLint unit = -1;
    a.glGetUniformiv(sampleProgram, a.glGetUniformLocation(sampleProgram, "tex"), &unit);
    check("sampler default binding restored", unit == 4, "unit=" + std::to_string(unit));
    a.glActiveTexture(GL_TEXTURE4);
    GLuint green = a.texture(0, 255, 0);
    a.glUseProgram(sampleProgram);
    a.drawBuffer(GL_COLOR_ATTACHMENT0);
    a.glDrawArrays(GL_TRIANGLES, 0, 3);
    a.glFinish();
    check("sampler binding produces green pixel", a.pixel(GL_COLOR_ATTACHMENT0, 0, 255, 0));
    a.glActiveTexture(GL_TEXTURE0);
    GLuint unlinked = a.glCreateProgram();
    a.drain();
    a.glUseProgram(unlinked);
    GLint current = 0;
    a.glGetIntegerv(GL_CURRENT_PROGRAM, &current);
    check("failed UseProgram retains current",
          a.glGetError() != GL_NO_ERROR && current == static_cast<GLint>(sampleProgram));
    a.glAttachShader(unlinked, vs);
    a.glAttachShader(unlinked, fs);
    a.glLinkProgram(unlinked);
    a.glUseProgram(unlinked);
    a.glGetIntegerv(GL_CURRENT_PROGRAM, &current);
    check("UseProgram retry after link reaches driver", current == static_cast<GLint>(unlinked));
    GLuint buffer = 0;
    a.glGenBuffers(1, &buffer);
    a.glBindBuffer(GL_ARRAY_BUFFER, buffer);
    a.glBufferData(GL_ARRAY_BUFFER, 16, nullptr, GL_STATIC_DRAW);
    a.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, buffer);
    a.glDeleteBuffers(1, &buffer);
    GLint bound = -1;
    a.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &bound);
    check("delete buffer clears binding", bound == 0);
    a.glDeleteVertexArrays(1, &vao);
    a.glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &bound);
    check("delete VAO clears binding", bound == 0);
    a.glBindTexture(GL_TEXTURE_2D, targets[0]);
    a.drain();
    a.glTexStorage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 8, 8);
    const GLenum storageError = a.glGetError();
    GLint width = 0;
    a.glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &width);
    check("rejected texture allocation preserves old extent", storageError != GL_NO_ERROR && width == 1,
          "width=" + std::to_string(width));
    a.drain();
    // Context migration exercises the wrapper pixel-store mirror through real EGL.
    a.glPixelStorei(GL_UNPACK_ALIGNMENT, 8);
    a.eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    bool migrated = false;
    std::thread worker([&] {
        migrated = a.eglMakeCurrent(display, surface, surface, context) == EGL_TRUE;
        if (migrated)
        {
            a.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
            a.eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
    });
    worker.join();
    a.eglMakeCurrent(display, surface, surface, context);
    a.glGetIntegerv(GL_UNPACK_ALIGNMENT, &bound);
    check("real EGL context migration", migrated && bound == 1);
    EGLContext shared = a.eglCreateContext(display, config, context, ctxAttrs),
               isolated = a.eglCreateContext(display, config, EGL_NO_CONTEXT, ctxAttrs);
    if (shared != EGL_NO_CONTEXT && isolated != EGL_NO_CONTEXT)
    {
        a.eglMakeCurrent(display, surface, surface, shared);
        a.glGetShaderiv(fs, GL_COMPILE_STATUS, &ok);
        check("shared context sees shader", ok == GL_TRUE);
        a.eglMakeCurrent(display, surface, surface, isolated);
        GLuint own = a.shader(GL_FRAGMENT_SHADER, fragment);
        a.glDeleteShader(own);
        a.eglMakeCurrent(display, surface, surface, context);
        a.glGetShaderiv(fs, GL_COMPILE_STATUS, &ok);
        check("isolated context does not corrupt shader metadata", ok == GL_TRUE);
    }
    else
        check("secondary contexts", false);
    // More than one persistence batch, then allow the existing time-based flush.
    // Warm reruns use the exact same corpus and verify the same driver results.
    bool corpusOK = true;
    for (unsigned i = 0; i < 20; ++i)
    {
        std::string code = std::string(vertex) + "\n//MG-probe-cache-" + std::to_string(i);
        const char *src = code.c_str();
        GLuint s = a.glCreateShader(GL_VERTEX_SHADER);
        a.glShaderSource(s, 1, &src, nullptr);
        a.glCompileShader(s);
        a.glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
        corpusOK &= ok == GL_TRUE;
        a.glDeleteShader(s);
    }
    check("persistent cache corpus compiles", corpusOK);
    usleep(5100000);
    GLuint flushShader = a.glCreateShader(GL_VERTEX_SHADER);
    a.glShaderSource(flushShader, 1, &vertex, nullptr);
    a.glDeleteShader(flushShader);
    struct stat cacheStat
    {
    };
    check("persistent cache file written",
          stat((std::string(kProbeDir) + "/glsl_cache.tmp").c_str(), &cacheStat) == 0 && cacheStat.st_size > 8);
    if (fsrExpected)
    {
        emit("BEGIN FSR active/present/resize contract");
        void *driver = dlopen("libGLESv3.so", RTLD_NOW | RTLD_LOCAL);
        auto rawGet = driver ? reinterpret_cast<decltype(a.glGetIntegerv)>(dlsym(driver, "glGetIntegerv")) : nullptr;
        a.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        GLint initialFBO = 0;
        if (rawGet)
            rawGet(GL_DRAW_FRAMEBUFFER_BINDING, &initialFBO);
        check("FSR initialized a real complete target",
              rawGet && initialFBO != 0 && a.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
              "driverFBO=" + std::to_string(initialFBO));
        a.glViewport(0, 0, 16, 16);
        a.glClearColor(0, 1, 0, 1);
        a.glClear(GL_COLOR_BUFFER_BIT);
        a.glEnable(GL_SCISSOR_TEST);
        a.glScissor(0, 0, 0, 0);
        a.glEnable(GL_BLEND);
        a.glEnable(GL_RASTERIZER_DISCARD);
        a.glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
        a.glClearColor(.25f, .5f, .75f, 1);
        a.drain();
        const EGLBoolean swapped = a.eglSwapBuffers(display, surface);
        const GLenum swapError = a.glGetError();
        GLfloat color[4]{};
        GLboolean mask[4]{};
        a.glGetFloatv(GL_COLOR_CLEAR_VALUE, color);
        a.glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        check("FSR present executes without GL error", swapped == EGL_TRUE && swapError == GL_NO_ERROR,
              "error=" + std::to_string(swapError));
        check("FSR restores non-default raster state", color[0] == .25f && !mask[0] && a.glIsEnabled(GL_SCISSOR_TEST) &&
                                                           a.glIsEnabled(GL_BLEND) &&
                                                           a.glIsEnabled(GL_RASTERIZER_DISCARD));
        a.glDisable(GL_SCISSOR_TEST);
        a.glDisable(GL_BLEND);
        a.glDisable(GL_RASTERIZER_DISCARD);
        a.glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        EGLint larger[] = {EGL_WIDTH, 32, EGL_HEIGHT, 24, EGL_NONE};
        EGLSurface resized = a.eglCreatePbufferSurface(display, config, larger);
        bool resizeOK = resized != EGL_NO_SURFACE && a.eglMakeCurrent(display, resized, resized, context) == EGL_TRUE;
        if (resizeOK)
        {
            a.drain();
            resizeOK = a.eglSwapBuffers(display, resized) == EGL_TRUE && a.glGetError() == GL_NO_ERROR;
            auto rawAttachment = reinterpret_cast<decltype(&::glGetFramebufferAttachmentParameteriv)>(
                dlsym(driver, "glGetFramebufferAttachmentParameteriv"));
            auto rawBindTexture = reinterpret_cast<decltype(&::glBindTexture)>(dlsym(driver, "glBindTexture"));
            auto rawLevel =
                reinterpret_cast<decltype(&::glGetTexLevelParameteriv)>(dlsym(driver, "glGetTexLevelParameteriv"));
            GLint replaced = 0, texture = 0, previousTexture = 0, width = 0, height = 0;
            if (rawGet && rawAttachment && rawBindTexture && rawLevel)
            {
                rawGet(GL_DRAW_FRAMEBUFFER_BINDING, &replaced);
                rawGet(GL_TEXTURE_BINDING_2D, &previousTexture);
                rawAttachment(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME,
                              &texture);
                rawBindTexture(GL_TEXTURE_2D, texture);
                rawLevel(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &width);
                rawLevel(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &height);
                rawBindTexture(GL_TEXTURE_2D, previousTexture);
            }
            resizeOK &= replaced != 0 && width == 32 && height == 24 &&
                        a.glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
            emit("FSR_RESIZE initial_name=" + std::to_string(initialFBO) + " current_name=" + std::to_string(replaced) +
                 " actual_extent=" + std::to_string(width) + "x" + std::to_string(height));
            a.eglMakeCurrent(display, surface, surface, context);
            a.eglDestroySurface(display, resized);
        }
        check("FSR rebuilds target after real surface size change", resizeOK);
    }
    a.glDeleteProgram(p);
    a.glDeleteProgram(explicitProgram);
    a.glDeleteProgram(sampleProgram);
    a.glUseProgram(0);
    a.glDeleteProgram(unlinked);
    for (GLuint shader : {vs, fs, unrelated, explicitShader, sampled})
        a.glDeleteShader(shader);
    a.glDeleteTextures(3, targets);
    a.glDeleteTextures(1, &green);
    a.glDeleteFramebuffers(1, &fb);
    a.eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (shared)
        a.eglDestroyContext(display, shared);
    if (isolated)
        a.eglDestroyContext(display, isolated);
    a.eglDestroyContext(display, context);
    a.eglDestroySurface(display, surface);
    emit("MG_RENDER_RESULT checks=" + std::to_string(checks) + " failures=" + std::to_string(failures));
    return failures ? 1 : 0;
}
} // namespace
const char *runMobileGluesTest()
{
    std::lock_guard<std::mutex> lock(probeMutex);
    mkdir(kProbeDir, 0700);
    pid_t child = fork();
    if (child == 0)
    {
        report = std::fopen(kReport, "w");
        if (!report)
            _exit(3);
        fsrExpected = access((std::string(kProbeDir) + "/fsr.enabled").c_str(), F_OK) == 0;
        {
            std::ofstream config(std::string(kProbeDir) + "/config.json");
            config << "{\"customGLVersion\":46,\"maxGlslCacheSize\":32,\"fsr1Setting\":" << (fsrExpected ? 2 : 0)
                   << ",\"hideMGEnvLevel\":0}";
        }
        setenv("MG_DIR_PATH", kProbeDir, 1);
        const int fd = fileno(report);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        setvbuf(stdout, nullptr, _IONBF, 0);
        setvbuf(stderr, nullptr, _IONBF, 0);
        int status = 2;
        try
        {
            status = probe();
        }
        catch (const std::exception &e)
        {
            emit(std::string("FAIL exception: ") + e.what());
        }
        catch (...)
        {
            emit("FAIL unknown exception");
        }
        std::fflush(report);
        _exit(status);
    }
    int status = 0;
    bool completed = false;
    if (child > 0)
    {
        for (int i = 0; i < 600; ++i)
        {
            if (waitpid(child, &status, WNOHANG) == child)
            {
                completed = true;
                break;
            }
            usleep(50000);
        }
        if (!completed)
        {
            kill(child, SIGKILL);
            waitpid(child, &status, 0);
        }
    }
    std::ifstream file(kReport);
    std::ostringstream buffer;
    buffer << file.rdbuf();
    result = buffer.str();
    result += "\nPROBE_CHILD status=" + std::to_string(status) + " completed=" + std::to_string(completed) + "\n";
    std::istringstream lines(result);
    std::string line;
    while (std::getline(lines, line))
        AMCL_LOG_I("MG_RENDER_PROBE", "%{public}s", line.c_str());
    return result.c_str();
}
