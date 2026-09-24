#!/usr/bin/env python3
# Applies OHOS gl4es source edits, used to generate 0002 patch (see build_gl4es_ohos.sh).
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "/build/gl4es-ohos-src"

# ---- init.h: declare gl4es_ensure_init ----
p = SRC + "/src/gl/init.h"
s = open(p).read()
anchor = "extern globals4es_t globals4es;\n"
assert anchor in s, "init.h anchor missing"
s = s.replace(anchor, anchor + "\n// OHOS: lazy-init entry (see init.c)\nvoid gl4es_ensure_init(void);\n", 1)
open(p, "w").write(s)

# ---- init.c: add gl4es_ensure_init def + change notest gate ----
p = SRC + "/src/gl/init.c"
s = open(p).read()
anc = ("void set_getprocaddress(void *(*new_proc_address)(const char *)) {\n"
       "    gles_getProcAddress = new_proc_address;\n}\n")
assert anc in s, "init.c set_getprocaddress anchor missing"
add = anc + (
    "\n"
    "void initialize_gl4es();  // forward decl (defined below with constructor/visibility attrs)\n"
    "// OHOS lazy initialization. gl4es is built with NO_INIT_CONSTRUCTOR (a constructor would\n"
    "// dlopen the GLES lib nested inside the host loader's dlopen -> musl loader-lock deadlock).\n"
    "// On OHOS the GL library can be loaded by the JVM (LWJGL via org.lwjgl.opengl.libname) in a\n"
    "// SEPARATE linker namespace, where our explicit initialize_gl4es() call never reached -> that\n"
    "// instance stayed uninitialized (gles==NULL) -> LOAD_GLES skipped -> NULL GLES pointer -> crash.\n"
    "// Calling this at the top of the first GL entry points initializes whatever instance is being\n"
    "// used, from a normal call context (render thread, context current) -> no nested dlopen.\n"
    "void gl4es_ensure_init(void) {\n"
    "    if(!inited) initialize_gl4es();\n"
    "}\n"
)
s = s.replace(anc, add, 1)
old = "    int gl4es_notest = !gles_getProcAddress;\n"
assert old in s, "init.c notest anchor missing"
new = (
    "    // OHOS: gate the hardware test on having a real GLES library handle (set via LIBGL_GLES),\n"
    "    // not on a custom proc-address resolver. With NOEGL we probe on the current context using\n"
    "    // gles_* resolved by dlsym(gles), so a real libGLESv3 handle is enough and lets us detect the\n"
    "    // real GLSL/NPOT/texture caps required for correct shader conversion.\n"
    "    int gl4es_notest = !gles;\n"
)
s = s.replace(old, new, 1)
open(p, "w").write(s)

# ---- getter.c: lazy-init at first GL entry points ----
p = SRC + "/src/gl/getter.c"
s = open(p).read()
fns = [
    "GLenum gl4es_glGetError() {\n",
    "const GLubyte *gl4es_glGetString(GLenum name) {\n",
    "void gl4es_glGetIntegerv(GLenum pname, GLint *params) {\n",
    "void gl4es_glGetFloatv(GLenum pname, GLfloat *params) {\n",
    "const GLubyte *gl4es_glGetStringi(GLenum name, GLuint index) {\n",
]
for f in fns:
    assert f in s, "getter.c missing: " + f
    s = s.replace(f, f + "    gl4es_ensure_init();\n", 1)
open(p, "w").write(s)

print("edits applied OK")
