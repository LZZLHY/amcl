#pragma once
#include <GLES3/gl3.h>
#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <sstream>
#include <vector>

// Explicit, bounded offscreen diagnostic. Called only in a private probe
// context on user request; never installed in the game's render loop.
namespace amcl::desktop::renderprobe {
using Resolver = void* (*)(const char*);

#define AMCL_RENDER_PROBE_GL(X) \
    X(glGetError) X(glGetIntegerv) X(glGetString) X(glCreateShader) \
    X(glShaderSource) X(glCompileShader) X(glGetShaderiv) X(glGetShaderInfoLog) \
    X(glDeleteShader) X(glCreateProgram) X(glAttachShader) X(glLinkProgram) \
    X(glGetProgramiv) X(glGetProgramInfoLog) X(glDeleteProgram) X(glUseProgram) \
    X(glGenVertexArrays) X(glBindVertexArray) X(glDeleteVertexArrays) \
    X(glGenBuffers) X(glBindBuffer) X(glBufferData) X(glBufferSubData) \
    X(glMapBufferRange) X(glFlushMappedBufferRange) X(glUnmapBuffer) \
    X(glBindBufferRange) X(glDeleteBuffers) X(glEnableVertexAttribArray) \
    X(glVertexAttribPointer) X(glGenTextures) X(glBindTexture) X(glTexImage2D) \
    X(glTexParameteri) X(glDeleteTextures) X(glActiveTexture) \
    X(glGenFramebuffers) X(glBindFramebuffer) X(glFramebufferTexture2D) \
    X(glCheckFramebufferStatus) X(glDeleteFramebuffers) X(glViewport) \
    X(glDisable) X(glClearColor) X(glClear) X(glDrawElements) X(glReadPixels)

struct Api {
#define DECLARE_GL(name) decltype(&::name) name = nullptr;
    AMCL_RENDER_PROBE_GL(DECLARE_GL)
#undef DECLARE_GL
    bool load(Resolver resolver, std::ostream& report) {
        bool ready = true;
#define LOAD_GL(name) name = reinterpret_cast<decltype(name)>(resolver(#name)); \
        if (!name) { report << "missing=" #name "\n"; ready = false; }
        AMCL_RENDER_PROBE_GL(LOAD_GL)
#undef LOAD_GL
        return ready;
    }
};
#undef AMCL_RENDER_PROBE_GL

struct Objects {
    Api& gl;
    GLuint shaders[2]{}, program = 0, vao = 0, buffers[3]{}, textures[2]{}, fbo = 0;
    ~Objects() {
        gl.glUseProgram(0);
        gl.glBindVertexArray(0);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glDeleteFramebuffers(1, &fbo);
        gl.glDeleteTextures(2, textures);
        gl.glDeleteBuffers(3, buffers);
        gl.glDeleteVertexArrays(1, &vao);
        if (program) gl.glDeleteProgram(program);
        for (GLuint shader : shaders) if (shader) gl.glDeleteShader(shader);
    }
};

inline std::string Run(Resolver resolver, const char* route) {
    std::ostringstream report;
    report << "route=" << route << '\n';
    Api gl;
    if (!gl.load(resolver, report)) return report.str() + "draw=INCOMPLETE\n";
    // Each route must agree on the current GL identity, not just return pointers.
    for (GLenum query : {GL_VERSION, GL_VENDOR, GL_RENDERER}) {
        const auto value = gl.glGetString(query);
        report << "identity[" << query << "]=" << (value ? reinterpret_cast<const char*>(value) : "NULL") << '\n';
    }
    const GLenum initialError = gl.glGetError();
    if (initialError != GL_NO_ERROR) {
        report << "initial-error=" << initialError << " draw=INCOMPLETE\n";
        return report.str();
    }
    Objects objects{gl};
    const char* sources[] = {
        "#version 420 core\n"
        "layout(location=0) in vec2 position;\n"
        "layout(location=1) in vec4 color;\n"
        "layout(location=2) in vec3 normal;\n"
        "out vec4 tint; out vec3 direction;\n"
        "void main(){gl_Position=vec4(position,0,1);tint=color;direction=normal;}\n",
        "#version 420 core\n"
        "layout(std140,binding=0) uniform Params {vec4 params;};\n"
        "layout(binding=0) uniform sampler2D atlas;\n"
        "in vec4 tint; in vec3 direction; layout(location=0) out vec4 result;\n"
        "void main(){float light=0.25+0.75*max(dot(normalize(direction),normalize(vec3(1,2,3))),0.0);"
        "result=vec4(textureLod(atlas,vec2(0.5),params.w).rgb*tint.rgb*light*params.xyz,1);}\n"
    };
    for (int i = 0; i < 2; ++i) {
        objects.shaders[i] = gl.glCreateShader(i == 0 ? GL_VERTEX_SHADER : GL_FRAGMENT_SHADER);
        gl.glShaderSource(objects.shaders[i], 1, &sources[i], nullptr);
        gl.glCompileShader(objects.shaders[i]);
        GLint ok = 0;
        gl.glGetShaderiv(objects.shaders[i], GL_COMPILE_STATUS, &ok);
        if (!ok) {
            char log[2048]{};
            gl.glGetShaderInfoLog(objects.shaders[i], sizeof(log), nullptr, log);
            report << "shader[" << i << "]=FAIL " << log << '\n';
            return report.str();
        }
    }
    objects.program = gl.glCreateProgram();
    for (GLuint shader : objects.shaders) gl.glAttachShader(objects.program, shader);
    gl.glLinkProgram(objects.program);
    GLint linked = 0;
    gl.glGetProgramiv(objects.program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[2048]{};
        gl.glGetProgramInfoLog(objects.program, sizeof(log), nullptr, log);
        return report.str() + "link=FAIL " + log + "\n";
    }
    gl.glUseProgram(objects.program);
    gl.glGenVertexArrays(1, &objects.vao);
    gl.glBindVertexArray(objects.vao);
    gl.glGenBuffers(3, objects.buffers);
    struct Vertex { float xy[2]; uint8_t color[4]; int8_t normal[4]; };
    Vertex vertices[] = {{{-1,-1},{255,255,255,255},{0,0,127,0}},
        {{1,-1},{255,255,255,255},{0,0,127,0}},
        {{1,1},{255,255,255,255},{0,0,127,0}},
        {{-1,1},{255,255,255,255},{0,0,127,0}}};
    gl.glBindBuffer(GL_ARRAY_BUFFER, objects.buffers[0]);
    gl.glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_DYNAMIC_DRAW);
    gl.glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex), nullptr);
    gl.glVertexAttribPointer(1, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof(Vertex), reinterpret_cast<void*>(offsetof(Vertex,color)));
    gl.glVertexAttribPointer(2, 3, GL_BYTE, GL_TRUE, sizeof(Vertex), reinterpret_cast<void*>(offsetof(Vertex,normal)));
    for (GLuint i = 0; i < 3; ++i) gl.glEnableVertexAttribArray(i);
    const GLushort indices[] = {0,1,2,0,2,3};
    gl.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, objects.buffers[1]);
    gl.glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);
    GLint alignment = 0;
    gl.glGetIntegerv(GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT, &alignment);
    if (alignment <= 0 || alignment > 65536) return report.str() + "ubo-alignment=INVALID\n";
    report << "ubo-alignment=" << alignment << '\n';
    gl.glBindBuffer(GL_UNIFORM_BUFFER, objects.buffers[2]);
    gl.glBufferData(GL_UNIFORM_BUFFER, alignment + 16, nullptr, GL_DYNAMIC_DRAW);
    gl.glBindBufferRange(GL_UNIFORM_BUFFER, 0, objects.buffers[2], alignment, 16);
    gl.glGenTextures(2, objects.textures);
    gl.glActiveTexture(GL_TEXTURE0);
    gl.glBindTexture(GL_TEXTURE_2D, objects.textures[1]);
    gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 16,16,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
    gl.glGenFramebuffers(1, &objects.fbo);
    gl.glBindFramebuffer(GL_FRAMEBUFFER, objects.fbo);
    gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, objects.textures[1], 0);
    if (gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return report.str() + "fbo=FAIL\n";
    gl.glBindTexture(GL_TEXTURE_2D, objects.textures[0]);
    const uint8_t base[] = {64,128,192,255, 64,128,192,255, 64,128,192,255, 64,128,192,255};
    const uint8_t mip[] = {192,64,128,255};
    gl.glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,2,2,0,GL_RGBA,GL_UNSIGNED_BYTE,base);
    gl.glTexImage2D(GL_TEXTURE_2D,1,GL_RGBA8,1,1,0,GL_RGBA,GL_UNSIGNED_BYTE,mip);
    gl.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST_MIPMAP_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,1);
    gl.glViewport(0,0,16,16);
    for (GLenum feature : {GL_BLEND,GL_DEPTH_TEST,GL_CULL_FACE,GL_SCISSOR_TEST,GL_DITHER}) gl.glDisable(feature);
    int passed = 0, attempted = 0;
    for (int upload = 0; upload < 2; ++upload) for (int face = 0; face < 6; ++face) for (int lod = 0; lod < 2; ++lod) {
        for (auto& vertex : vertices) {
            std::memset(vertex.normal,0,sizeof(vertex.normal));
            vertex.normal[face/2] = face%2 == 0 ? 127 : -127;
        }
        gl.glBindBuffer(GL_ARRAY_BUFFER, objects.buffers[0]);
        gl.glBufferSubData(GL_ARRAY_BUFFER,0,sizeof(vertices),vertices);
        const float factor = lod == 0 ? 1.0f : 0.5f;
        const float params[] = {factor,factor,factor,static_cast<float>(lod)};
        gl.glBindBuffer(GL_UNIFORM_BUFFER, objects.buffers[2]);
        if (upload == 0) gl.glBufferSubData(GL_UNIFORM_BUFFER,alignment,sizeof(params),params);
        else {
            void* mapped = gl.glMapBufferRange(GL_UNIFORM_BUFFER,alignment,sizeof(params),
                GL_MAP_WRITE_BIT|GL_MAP_INVALIDATE_RANGE_BIT|GL_MAP_FLUSH_EXPLICIT_BIT);
            if (!mapped) return report.str() + "ubo-map=FAIL\n";
            std::memcpy(mapped,params,sizeof(params));
            gl.glFlushMappedBufferRange(GL_UNIFORM_BUFFER,0,sizeof(params));
            if (!gl.glUnmapBuffer(GL_UNIFORM_BUFFER)) return report.str() + "ubo-unmap=FAIL\n";
        }
        gl.glClearColor(1,0,1,1);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glDrawElements(GL_TRIANGLES,6,GL_UNSIGNED_SHORT,nullptr);
        uint8_t pixels[16*16*4]{};
        gl.glReadPixels(0,0,16,16,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
        const GLenum error = gl.glGetError();
        const float light = .25f + .75f*(face%2 == 0 ? (face/2+1)/std::sqrt(14.0f) : 0.0f);
        const uint8_t* texel = lod == 0 ? base : mip;
        int expected[3];
        for (int c=0;c<3;++c) expected[c] = static_cast<int>(std::lround(texel[c]*light*factor));
        int mismatches = 0;
        for (int p=0;p<256;++p) {
            bool match = pixels[p*4+3] >= 253;
            for (int c=0;c<3;++c) match = match && std::abs(int(pixels[p*4+c])-expected[c])<=2;
            if (!match) ++mismatches;
        }
        ++attempted;
        if (!mismatches && error == GL_NO_ERROR) ++passed;
        report << "sample=" << attempted << " upload=" << (upload ? "map-flush" : "subdata")
            << " face=" << face << " lod=" << lod << " error=" << error << " badPixels=" << mismatches
            << " expected=" << expected[0] << ',' << expected[1] << ',' << expected[2]
            << " center=" << int(pixels[544]) << ',' << int(pixels[545]) << ',' << int(pixels[546]) << '\n';
    }
    report << "draw=" << (passed == attempted ? "PASS" : "FAIL") << " passed=" << passed << "/" << attempted << '\n';
    return report.str();
}
}
