#!/usr/bin/env python3
# patch_zink_ubo_log.py — 给 zink 的 UBO 描述符状态更新加诊断日志（定位 1.21.2+ 方块全黑）。
#
# 现象：MC 1.21.2+ 新管线（重度 UBO）世界几何体全黑，驱动报 "UniformDescriptor addr is 0"。
# 1.20.1（旧管线）正常。怀疑 UBO 描述符绑成空 buffer / bda=0。
#
# 本补丁在 update_descriptor_state_ubo_db / _lazy 里落盘日志（$AMCL_FILES_DIR/zink_ubo.log）：
#   - 启动时记录 zink_descriptor_mode（db / lazy）；
#   - db 路径：res 非空但 bda==0 的次数（addr=0 根因）；res==NULL 的次数；
#   - lazy 路径：res==NULL（绑了 dummy/null buffer）的次数。
# 据此判定：是 db 模式 bda 为 0，还是 zink 把 MC 绑的 UBO 当成未绑（res=NULL）。
#
# 用法：python3 patch_zink_ubo_log.py /build/mesa-ohos-src

import sys, os
ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
CTX = os.path.join(ROOT, "src/gallium/drivers/zink/zink_context.c")
MARK = "AMCL_UBO_LOG"

with open(CTX, "r", encoding="utf-8") as f:
    c = f.read()
if MARK in c:
    print("already patched ubo log"); sys.exit(0)

# 日志助手：插在 update_descriptor_state_ubo_db 之前。
anchor_fn = ("ALWAYS_INLINE static struct zink_resource *\n"
             "update_descriptor_state_ubo_db(struct zink_context *ctx, gl_shader_stage shader, unsigned slot, struct zink_resource *res)\n"
             "{\n")
if anchor_fn not in c:
    raise SystemExit("FAIL: ubo_db anchor not found")

helper = (
    "/* " + MARK + " */\n"
    "#include <stdio.h>\n"
    "extern unsigned zink_descriptor_mode;\n"
    "static void amcl_ubo_log(const char *tag, long a, long b, long cc) {\n"
    "   static FILE *fp = NULL; static int tries = 0;\n"
    "   if (!fp) { if (tries++ > 1) return; const char *d = getenv(\"AMCL_FILES_DIR\");\n"
    "      if (!d) return; char p[512]; snprintf(p, sizeof(p), \"%s/zink_ubo.log\", d); fp = fopen(p, \"a\"); if (!fp) return; }\n"
    "   fprintf(fp, \"%s %ld %ld %ld\\n\", tag, a, b, cc); fflush(fp);\n"
    "}\n"
    "static void amcl_ubo_mode_once(void) {\n"
    "   static int done = 0; if (done) return; done = 1;\n"
    "   amcl_ubo_log(\"descriptor_mode(0=auto,1=lazy,2=db)\", (long)zink_descriptor_mode, 0, 0);\n"
    "}\n"
    "ALWAYS_INLINE static struct zink_resource *\n"
    "update_descriptor_state_ubo_db(struct zink_context *ctx, gl_shader_stage shader, unsigned slot, struct zink_resource *res)\n"
    "{\n"
    "   amcl_ubo_mode_once();\n"
)
c = c.replace(anchor_fn, helper, 1)

# db: 记录 bda==0 / res==NULL
anchor_db = ("      ctx->di.db.ubos[shader][slot].address = res->obj->bda + ctx->ubos[shader][slot].buffer_offset;\n"
             "      ctx->di.db.ubos[shader][slot].range = ctx->ubos[shader][slot].buffer_size;\n")
new_db = (anchor_db +
    "      { static long n0=0,nb=0; if (res->obj->bda==0) { if (n0++ < 60) amcl_ubo_log(\"DB bda==0 stage/slot/off\", (long)shader, (long)slot, (long)ctx->ubos[shader][slot].buffer_offset); }\n"
    "        else if (nb++ < 5) amcl_ubo_log(\"DB ok bda/stage/slot\", (long)res->obj->bda, (long)shader, (long)slot); }\n")
if anchor_db not in c:
    raise SystemExit("FAIL: db address anchor not found")
c = c.replace(anchor_db, new_db, 1)

# db else (res NULL)
anchor_dbnull = ("   } else {\n"
                 "      ctx->di.db.ubos[shader][slot].address = 0;\n"
                 "      ctx->di.db.ubos[shader][slot].range = VK_WHOLE_SIZE;\n"
                 "   }\n")
new_dbnull = ("   } else {\n"
              "      ctx->di.db.ubos[shader][slot].address = 0;\n"
              "      ctx->di.db.ubos[shader][slot].range = VK_WHOLE_SIZE;\n"
              "      { static long n=0; if (n++ < 60) amcl_ubo_log(\"DB res==NULL stage/slot\", (long)shader, (long)slot, -1); }\n"
              "   }\n")
if anchor_dbnull in c:
    c = c.replace(anchor_dbnull, new_dbnull, 1)

# lazy: res==NULL 分支
anchor_lazynull = ("      bool have_null_descriptors = screen->info.rb2_feats.nullDescriptor;\n")
new_lazynull = ("      { static long n=0; if (n++ < 60) amcl_ubo_log(\"LAZY res==NULL stage/slot\", (long)shader, (long)slot, -1); }\n"
                "      bool have_null_descriptors = screen->info.rb2_feats.nullDescriptor;\n")
if anchor_lazynull in c:
    c = c.replace(anchor_lazynull, new_lazynull, 1)

with open(CTX, "w", encoding="utf-8") as f:
    f.write(c)
print("patched zink_context.c UBO descriptor logging")
print("ALL DONE")
