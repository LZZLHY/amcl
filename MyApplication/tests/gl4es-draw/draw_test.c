/* 完整生产 gl4es 的独立验收入口：只把 EGL/GLES 放在系统边界，列表、数组和 FPE 均用原库。
 * 每个场景独立进程，故意失败的旧实现不会污染下一个场景；像素期望来自几何位置和颜色。
 */
#include <EGL/egl.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sanitizer/lsan_interface.h>
#include "gl/gl4es.h"
#include "gl/glstate.h"
#include "gl/init.h"
#include "glx/hardext.h"

#define glClearColor p_glClearColor
#define glClear p_glClear
#define glViewport p_glViewport
#define glReadPixels p_glReadPixels
#define glEnable p_glEnable
#define glDisable p_glDisable
#define glEnableClientState p_glEnableClientState
#define glDisableClientState p_glDisableClientState
#define glVertexPointer p_glVertexPointer
#define glColorPointer p_glColorPointer
#define glColor4f p_glColor4f
#define glMatrixMode p_glMatrixMode
#define glLoadIdentity p_glLoadIdentity
#define glOrtho p_glOrtho
#define glMultiDrawArrays p_glMultiDrawArrays
#define glMultiDrawElements p_glMultiDrawElements
#define glMultiDrawElementsBaseVertex p_glMultiDrawElementsBaseVertex
#define glDrawArrays p_glDrawArrays
#define glDrawElements p_glDrawElements
#define glGetError p_glGetError
#define glFinish p_glFinish
#define glGenBuffers p_glGenBuffers
#define glBindBuffer p_glBindBuffer
#define glBufferData p_glBufferData
#define glDeleteBuffers p_glDeleteBuffers
#define glGenVertexArrays p_glGenVertexArrays
#define glBindVertexArray p_glBindVertexArray
#define glDeleteVertexArrays p_glDeleteVertexArrays
#define glGetIntegerv p_glGetIntegerv
#define glGetVertexAttribiv p_glGetVertexAttribiv
#define glMapBuffer p_glMapBuffer
#define glUnmapBuffer p_glUnmapBuffer
#define glNewList p_glNewList
#define glEndList p_glEndList
#define glCallList p_glCallList
#define glDeleteLists p_glDeleteLists
#define glPolygonMode p_glPolygonMode
#define glCreateShader p_glCreateShader
#define glGetUniformLocation p_glGetUniformLocation
#define glUniform4f p_glUniform4f
#define glGetFloatv p_glGetFloatv
#define glGetDoublev p_glGetDoublev
#define glActiveTexture p_glActiveTexture
#define glGetBooleanv p_glGetBooleanv
#define glShaderSource p_glShaderSource
#define glCompileShader p_glCompileShader
#define glGetShaderiv p_glGetShaderiv
#define glGetShaderInfoLog p_glGetShaderInfoLog
#define glCreateProgram p_glCreateProgram
#define glAttachShader p_glAttachShader
#define glBindAttribLocation p_glBindAttribLocation
#define glLinkProgram p_glLinkProgram
#define glGetProgramiv p_glGetProgramiv
#define glUseProgram p_glUseProgram
#define glDeleteProgram p_glDeleteProgram
#define glDeleteShader p_glDeleteShader
#define glEnableVertexAttribArray p_glEnableVertexAttribArray
#define glDisableVertexAttribArray p_glDisableVertexAttribArray
#define glVertexAttribPointer p_glVertexAttribPointer
#define glVertexAttrib4f p_glVertexAttrib4f
#define glBegin p_glBegin
#define glEnd p_glEnd
#define glBlendFunc p_glBlendFunc
#define glGenTextures p_glGenTextures
#define glBindTexture p_glBindTexture
#define glTexParameteri p_glTexParameteri
#define glTexImage2D p_glTexImage2D
#define glTexCoordPointer p_glTexCoordPointer
#define glDeleteTextures p_glDeleteTextures
#define W 96
#define H 64
/* 宿主从被测 DSO 精确取函数，避免 OpenGL 同名导出与原始 GLES 库发生链接抢占。 */
#define API(R,N,ARGS) static R (*N) ARGS
API(void,glClearColor,(GLfloat,GLfloat,GLfloat,GLfloat));
API(void,glClear,(GLbitfield)); API(void,glViewport,(GLint,GLint,GLsizei,GLsizei));
API(void,glReadPixels,(GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,void*));
API(void,glEnable,(GLenum)); API(void,glDisable,(GLenum));
API(void,glEnableClientState,(GLenum)); API(void,glDisableClientState,(GLenum));
API(void,glVertexPointer,(GLint,GLenum,GLsizei,const void*));
API(void,glColorPointer,(GLint,GLenum,GLsizei,const void*));
API(void,glColor4f,(GLfloat,GLfloat,GLfloat,GLfloat));
API(void,glMatrixMode,(GLenum)); API(void,glLoadIdentity,(void));
API(void,glOrtho,(GLdouble,GLdouble,GLdouble,GLdouble,GLdouble,GLdouble));
API(void,glMultiDrawArrays,(GLenum,const GLint*,const GLsizei*,GLsizei));
API(void,glMultiDrawElements,(GLenum,GLsizei*,GLenum,const void*const*,GLsizei));
API(void,glMultiDrawElementsBaseVertex,(GLenum,GLsizei*,GLenum,const void*const*,GLsizei,const GLint*));
API(void,glDrawArrays,(GLenum,GLint,GLsizei));
API(void,glDrawElements,(GLenum,GLsizei,GLenum,const void*));
API(GLenum,glGetError,(void)); API(void,glFinish,(void));
API(void,glGenBuffers,(GLsizei,GLuint*)); API(void,glBindBuffer,(GLenum,GLuint));
API(void,glBufferData,(GLenum,GLsizeiptr,const void*,GLenum));
API(void,glDeleteBuffers,(GLsizei,const GLuint*));
API(void,glGenVertexArrays,(GLsizei,GLuint*));
API(void,glBindVertexArray,(GLuint)); API(void,glDeleteVertexArrays,(GLsizei,const GLuint*));
API(void,glGetIntegerv,(GLenum,GLint*)); API(void,glGetVertexAttribiv,(GLuint,GLenum,GLint*));
API(void*,glMapBuffer,(GLenum,GLenum)); API(GLboolean,glUnmapBuffer,(GLenum));
API(void,glNewList,(GLuint,GLenum)); API(void,glEndList,(void));
API(void,glCallList,(GLuint)); API(void,glDeleteLists,(GLuint,GLsizei));
API(void,glPolygonMode,(GLenum,GLenum));
API(void,glBegin,(GLenum)); API(void,glEnd,(void));
API(void,glBlendFunc,(GLenum,GLenum));
API(void,glGenTextures,(GLsizei,GLuint*)); API(void,glBindTexture,(GLenum,GLuint));
API(void,glTexParameteri,(GLenum,GLenum,GLint));
API(void,glTexImage2D,(GLenum,GLint,GLint,GLsizei,GLsizei,GLint,GLenum,GLenum,const void*));
API(void,glTexCoordPointer,(GLint,GLenum,GLsizei,const void*));
API(void,glDeleteTextures,(GLsizei,const GLuint*));
API(GLuint,glCreateShader,(GLenum));
API(GLint,glGetUniformLocation,(GLuint,const GLchar*));
API(void,glUniform4f,(GLint,GLfloat,GLfloat,GLfloat,GLfloat));
API(void,glGetFloatv,(GLenum,GLfloat*));
API(void,glGetDoublev,(GLenum,GLdouble*));
API(void,glActiveTexture,(GLenum));
API(void,glGetBooleanv,(GLenum,GLboolean*));
API(void,glShaderSource,(GLuint,GLsizei,const GLchar*const*,const GLint*));
API(void,glCompileShader,(GLuint)); API(void,glGetShaderiv,(GLuint,GLenum,GLint*));
API(void,glGetShaderInfoLog,(GLuint,GLsizei,GLsizei*,GLchar*));
API(GLuint,glCreateProgram,(void)); API(void,glAttachShader,(GLuint,GLuint));
API(void,glBindAttribLocation,(GLuint,GLuint,const GLchar*));
API(void,glLinkProgram,(GLuint)); API(void,glGetProgramiv,(GLuint,GLenum,GLint*));
API(void,glUseProgram,(GLuint)); API(void,glDeleteProgram,(GLuint));
API(void,glDeleteShader,(GLuint));
API(void,glEnableVertexAttribArray,(GLuint)); API(void,glDisableVertexAttribArray,(GLuint));
API(void,glVertexAttribPointer,(GLuint,GLint,GLenum,GLboolean,GLsizei,const void*));
API(void,glVertexAttrib4f,(GLuint,GLfloat,GLfloat,GLfloat,GLfloat));
static glstate_t **state;
static globals4es_t *options;
static GLfloat positions[12][2], colors[12][4];
static GLushort short_positions[12][2];
static GLint firsts[3]={0,4,8};
static GLsizei counts[3]={4,4,4};
static void fail(const char *message) { fprintf(stderr,"FAIL: %s\n",message); exit(2); }

/* 三个不相交矩形分别红、绿、蓝；每批坐标和颜色不同，漏画或覆盖不能靠顶点总数蒙混。 */
static void scene(int compact) {
    const GLfloat rgb[3][4]={{1,0,0,1},{0,1,0,1},{0,0,1,1}};
    for(int b=0;b<3;b++) for(int k=0;k<4;k++) {
        positions[b*4+k][0]=10+b*30+((k==1||k==2)?18:0);
        positions[b*4+k][1]=10+((k>=2)?25:0);
        short_positions[b*4+k][0]=positions[b*4+k][0];
        short_positions[b*4+k][1]=positions[b*4+k][1];
        memcpy(colors[b*4+k],rgb[b],sizeof rgb[b]);
    }
    if(compact) {
        /* 真实 glVertexAttribPointer 接口可声明 ushort；无用户 program 时强制覆盖旧 intercept。 */
        glVertexAttribPointer(0,2,GL_UNSIGNED_SHORT,GL_FALSE,0,short_positions);
        glEnableVertexAttribArray(0);
    } else { glVertexPointer(2,GL_FLOAT,0,positions); glEnableClientState(GL_VERTEX_ARRAY); }
    glColorPointer(4,GL_FLOAT,0,colors); glEnableClientState(GL_COLOR_ARRAY);
}

static void clear(void) { glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT); }

/* 内部覆盖点离图元边界至少数个像素；精确颜色仅容许 RGBA8 量化误差 2，不事后放宽。 */
static void pixel(int x,int y,int r,int g,int b) {
    unsigned char value[4]; glReadPixels(x,y,1,1,GL_RGBA,GL_UNSIGNED_BYTE,value);
    if(abs((int)value[0]-r)>2||abs((int)value[1]-g)>2||abs((int)value[2]-b)>2) {
        fprintf(stderr,"pixel(%d,%d): got %u,%u,%u expected %d,%d,%d\n",x,y,value[0],value[1],value[2],r,g,b);
        fail("independent pixel expectation");
    }
}
static void rectangles(void) { pixel(18,20,255,0,0); pixel(48,20,0,255,0); pixel(78,20,0,0,255); pixel(3,3,0,0,0); }
static void flush(void) { glFinish(); }

/* 参数表、零/非正批次、真实列表编译和 pending 生命周期的场景。 */
static void arrays(const char *name) {
    int compiling=!strcmp(name,"display-list");
    scene(1); options->mergelist=strcmp(name,"arrays-no-merge")!=0;
    options->maxbatch=!strcmp(name,"pending")?100:0;
    if(compiling) glNewList(17,GL_COMPILE);
    GLint starts[5]={123456,0,4,987654,8}; GLsizei lengths[5]={0,4,4,-1,4};
    glMultiDrawArrays(GL_QUADS,starts,lengths,5);
    if(compiling) {
        glEndList(); memset(short_positions,0,sizeof short_positions); memset(colors,0,sizeof colors);
        glCallList(17);
    }
    flush(); rectangles();
    GLenum error=glGetError(); if(error!=GL_NO_ERROR) { fprintf(stderr,"array scenario error=%x\n",error); fail("nonpositive MultiDraw entries must be skipped"); }
    if(compiling) glDeleteLists(17,1);
    if((*state)->list.active && !(*state)->list.compiling) fail("pending tail retained after flush");
}

/* byte/short/int 与 EBO 零/非零 offset 均使用不同逐批来源；输入 bytes 在绘制后仍须不变。 */
static void elements(int intercept,int base) {
    scene(intercept); options->maxbatch=0;
    for(int ebo=0;ebo<2;ebo++) for(int t=0;t<3;t++) {
        GLenum type=t==0?GL_UNSIGNED_BYTE:t==1?GL_UNSIGNED_SHORT:GL_UNSIGNED_INT;
        unsigned char packed[3*6*4]={0}, before[sizeof packed];
        int size=1<<t; const void *sources[3]; GLuint buffer=0;
        for(int b=0;b<3;b++) {
            unsigned ids[6]={0,1,2,0,2,3};
            for(int k=0;k<6;k++) { unsigned id=ids[k]+(base?0:b*4); memcpy(packed+(b*6+k)*size,&id,size); }
            sources[b]=ebo?(void*)(uintptr_t)(b*6*size):packed+b*6*size;
        }
        memcpy(before,packed,sizeof packed);
        if(ebo) { glGenBuffers(1,&buffer); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,buffer); glBufferData(GL_ELEMENT_ARRAY_BUFFER,sizeof packed,packed,GL_STATIC_DRAW); }
        GLsizei lengths[3]={6,6,6}; GLint bases[3]={0,4,8}; clear();
        if(base) glMultiDrawElementsBaseVertex(GL_TRIANGLES,lengths,type,sources,3,bases);
        else glMultiDrawElements(GL_TRIANGLES,lengths,type,sources,3);
        flush(); rectangles();
        if(memcmp(before,packed,sizeof packed)) fail("client indices mutated");
        if(ebo && memcmp((*state)->vao->elements->data,packed,sizeof packed)) fail("EBO shadow mutated");
        if(glGetError()!=GL_NO_ERROR) fail("valid indexed draw error");
        if(ebo) { glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,0); glDeleteBuffers(1,&buffer); }
    }
}

/* 公共校验必须先于参数访问，并且一次成功/空调用不能消耗已存在的错误。 */
static void errors(int zero) {
    glEnable(0xFFFF); if(!zero && glGetError()!=GL_INVALID_ENUM) fail("error setup");
    glMultiDrawElementsBaseVertex(GL_TRIANGLES,NULL,GL_UNSIGNED_SHORT,NULL,0,NULL);
    if(zero) { if(glGetError()!=GL_INVALID_ENUM) fail("zero draw cleared unread error"); return; }
    glMultiDrawArrays(GL_TRIANGLES,NULL,NULL,-1);
    glMultiDrawArrays(GL_TRIANGLES,NULL,NULL,0);
    if(glGetError()!=GL_INVALID_VALUE) fail("negative drawcount error lost");
    glMultiDrawElements(GL_TRIANGLES,NULL,0xFFFF,NULL,0);
    if(glGetError()!=GL_INVALID_ENUM) fail("zero count omitted type validation");
    glMultiDrawArrays(0xFFFF,NULL,NULL,0);
    if(glGetError()!=GL_INVALID_ENUM) fail("zero count omitted mode validation");
    GLsizei empty[3]={0,-1,0}; glMultiDrawArrays(GL_TRIANGLES,NULL,empty,3);
    glMultiDrawElementsBaseVertex(GL_TRIANGLES,empty,GL_UNSIGNED_INT,NULL,3,NULL);
    if(glGetError()!=GL_NO_ERROR) fail("empty entries accessed first/indices/base tables");
    glBegin(GL_TRIANGLES); glMultiDrawArrays(GL_TRIANGLES,NULL,NULL,0); glEnd();
    if(glGetError()!=GL_INVALID_OPERATION) fail("Begin/End validation omitted");
    scene(0); GLint bad=-1; GLsizei positive=4;
    glMultiDrawArrays(GL_QUADS,&bad,&positive,1);
    glMultiDrawArrays(GL_QUADS,firsts,counts,3);
    flush(); if(glGetError()!=GL_INVALID_VALUE) fail("success overwrote failed batch error");
    clear(); GLint mixed_firsts[4]={-1,0,4,8}; GLsizei mixed_counts[4]={4,4,4,4};
    glMultiDrawArrays(GL_QUADS,mixed_firsts,mixed_counts,4); flush(); rectangles();
    if(glGetError()!=GL_INVALID_VALUE) fail("same-call failed batch error lost");
}

static void bounds(void) {
    scene(0); GLuint vbo; glGenBuffers(1,&vbo); glBindBuffer(GL_ARRAY_BUFFER,vbo);
    glBufferData(GL_ARRAY_BUFFER,sizeof positions,positions,GL_STATIC_DRAW);
    glVertexPointer(2,GL_FLOAT,0,NULL); glDrawArrays(GL_QUADS,10,4);
    if(glGetError()!=GL_INVALID_OPERATION) fail("VBO overrun not rejected");
    glDrawArrays(GL_TRIANGLES,0,3); if(glGetError()!=GL_NO_ERROR) fail("VBO zero offset rejected");
    glMapBuffer(GL_ARRAY_BUFFER,GL_READ_ONLY); glMultiDrawArrays(GL_QUADS,firsts,counts,3);
    if(glGetError()!=GL_INVALID_OPERATION) fail("mapped array accepted");
    glUnmapBuffer(GL_ARRAY_BUFFER); glBindBuffer(GL_ARRAY_BUFFER,0); glDeleteBuffers(1,&vbo);
}

/* 非零 first 的大 QUADS 和 32 位大绝对索引必须到达原位置，不能截断或漏掉后续片段。 */
static void wide(void) {
    size_t n=140000; GLfloat (*data)[2]=calloc(n,sizeof *data);
    if(!data) fail("test allocation"); glDisableClientState(GL_COLOR_ARRAY); glColor4f(1,0,0,1);
    for(size_t k=65540;k+3<n;k+=4) for(int j=0;j<4;j++) {
        data[k+j][0]=(j==1||j==2)?28:10; data[k+j][1]=(j>=2)?35:10;
    }
    glVertexPointer(2,GL_FLOAT,0,data); glEnableClientState(GL_VERTEX_ARRAY);
    glDrawArrays(GL_QUADS,65540,64004); flush(); pixel(18,20,255,0,0);
    clear(); GLuint ids[6]={65540,65541,65542,65540,65542,65543};
    GLsizei count=6; const void *p=ids; glMultiDrawElements(GL_TRIANGLES,&count,GL_UNSIGNED_INT,&p,1);
    flush(); pixel(18,20,255,0,0);
    if(glGetError()!=GL_NO_ERROR) fail("wide legal input rejected");
    /* 跨越整个 16 位窗口的稀疏 uint 输入强制真实 FPE 转译，三角形顶点仍来自三个原始编号。 */
    GLushort (*short_data)[2]=calloc(n,sizeof *short_data);
    GLuint sparse[3]={1,70001,139001}; const GLushort triangle[3][2]={{10,10},{28,10},{10,35}};
    for(int j=0;j<3;j++) memcpy(short_data[sparse[j]],triangle[j],sizeof triangle[j]);
    glVertexAttribPointer(0,2,GL_UNSIGNED_SHORT,GL_FALSE,0,short_data);
    GLsizei three=3; const void *source=sparse; clear();
    glMultiDrawElements(GL_TRIANGLES,&three,GL_UNSIGNED_INT,&source,1); flush(); pixel(18,20,255,0,0);
    /* ushort 加非零 base 必须先扩宽；合法负 base 同样保持原输入不变。 */
    GLushort near[3]={65533,65534,65535}; GLint base=8;
    for(int j=0;j<3;j++) memcpy(short_data[(GLuint)near[j]+base],triangle[j],sizeof triangle[j]);
    source=near; clear(); glMultiDrawElementsBaseVertex(GL_TRIANGLES,&three,GL_UNSIGNED_SHORT,&source,1,&base); flush(); pixel(18,20,255,0,0);
    GLuint negative[3]={70001,70002,70003}; base=-4;
    for(int j=0;j<3;j++) memcpy(short_data[negative[j]+base],triangle[j],sizeof triangle[j]);
    source=negative; clear(); glMultiDrawElementsBaseVertex(GL_TRIANGLES,&three,GL_UNSIGNED_INT,&source,1,&base); flush(); pixel(18,20,255,0,0);
    if(glGetError()!=GL_NO_ERROR) fail("wide/base conversion error"); free(short_data); free(data);
}

/* 用户 shader 的颜色属性刻意放在 1 号，区别于传统 FPE 槽；ushort/ubyte normalized 均核验。 */
static void compact(void) {
    const char *vs="#version 120\nattribute vec2 p; attribute vec4 c; varying vec4 col; void main(){gl_Position=vec4(p*2.0-1.0,0.0,1.0);col=c;}";
    const char *fs="#version 120\nvarying vec4 col; void main(){gl_FragColor=col;}";
    GLuint v=glCreateShader(GL_VERTEX_SHADER), f=glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(v,1,&vs,NULL); glShaderSource(f,1,&fs,NULL); glCompileShader(v); glCompileShader(f);
    GLint ok; glGetShaderiv(v,GL_COMPILE_STATUS,&ok); if(!ok) { char log[4096];glGetShaderInfoLog(v,sizeof log,NULL,log);fprintf(stderr,"%s\n",log);fail("vertex compile"); }
    glGetShaderiv(f,GL_COMPILE_STATUS,&ok); if(!ok) fail("fragment compile");
    GLuint program=glCreateProgram(); glAttachShader(program,v); glAttachShader(program,f);
    glBindAttribLocation(program,0,"p"); glBindAttribLocation(program,1,"c"); glLinkProgram(program);
    glGetProgramiv(program,GL_LINK_STATUS,&ok); if(!ok) fail("program link"); glUseProgram(program);
    struct vertex { GLushort x,y; GLubyte color[4]; } data[12]; scene(0);
    for(int i=0;i<12;i++) { data[i].x=positions[i][0]*65535/W; data[i].y=positions[i][1]*65535/H; for(int j=0;j<4;j++) data[i].color[j]=colors[i][j]*(j==3?255:128); }
    glVertexAttribPointer(0,2,GL_UNSIGNED_SHORT,GL_TRUE,sizeof data[0],data);
    glVertexAttribPointer(1,4,GL_UNSIGNED_BYTE,GL_TRUE,sizeof data[0],data[0].color);
    glEnableVertexAttribArray(0); glEnableVertexAttribArray(1);
    glMultiDrawArrays(GL_QUADS,firsts,counts,3); flush(); pixel(18,20,128,0,0); pixel(48,20,0,128,0); pixel(78,20,0,0,128);
    clear(); glNewList(19,GL_COMPILE); glMultiDrawArrays(GL_QUADS,firsts,counts,3); glEndList();
    memset(data,0,sizeof data); glCallList(19); flush(); pixel(18,20,128,0,0); pixel(48,20,0,128,0); pixel(78,20,0,0,128); glDeleteLists(19,1);
    glUseProgram(0); glDeleteProgram(program); glDeleteShader(v); glDeleteShader(f);
}

/* 复现 Angelica 的“先绑定 VBO，再切换/创建 VAO，然后声明 offset”调用顺序。
 * ARRAY/PACK/UNPACK 是 context 状态；只有 EBO 和属性捕获的 buffer 属于 VAO。
 * CPU shadow 与真实 GPU VBO 分别验证；两套 VAO 的颜色不同，绑定查询不能替代像素结果。
 * 删除当前 VAO 必须回到 0 且保留全局绑定，移除的 VAO 资源由 LSan 核对生命周期。
 */
static void vao_bindings(void) {
    const char *vs="#version 110\nattribute vec3 p; attribute vec4 c; varying vec4 col; void main(){gl_Position=vec4(p.xy*(2.0/65535.0)-1.0,0.0,1.0);col=c;}";
    const char *fs="#version 110\nvarying vec4 col; void main(){gl_FragColor=col;}";
    GLuint v=glCreateShader(GL_VERTEX_SHADER), f=glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(v,1,&vs,NULL); glShaderSource(f,1,&fs,NULL); glCompileShader(v); glCompileShader(f);
    GLint ok; glGetShaderiv(v,GL_COMPILE_STATUS,&ok); if(!ok) fail("VAO vertex shader compile");
    glGetShaderiv(f,GL_COMPILE_STATUS,&ok); if(!ok) fail("VAO fragment shader compile");
    GLuint program=glCreateProgram(); glAttachShader(program,v); glAttachShader(program,f);
    glBindAttribLocation(program,0,"p"); glBindAttribLocation(program,1,"c"); glLinkProgram(program);
    glGetProgramiv(program,GL_LINK_STATUS,&ok); if(!ok) fail("VAO program link"); glUseProgram(program);
    /* 与 Mercury 实取相同的 20 字节紧凑布局：位置 0、颜色 8、纹理 12、光照 16。 */
    struct packed_vertex { GLushort position[4]; GLubyte color[4]; GLushort texture[2],light[2]; } data[2][12];
    scene(0); memset(data,0,sizeof data);
    for(int set=0;set<2;++set) for(int j=0;j<12;++j) {
        data[set][j].position[0]=positions[j][0]*65535/W;
        data[set][j].position[1]=positions[j][1]*65535/H;
        for(int k=0;k<4;++k) data[set][j].color[k]=set?(k==1||k==2||k==3?255:0):colors[j][k]*255;
        data[set][j].light[0]=data[set][j].light[1]=65535;
    }
    for(int gpu=0;gpu<2;++gpu) {
        options->usevbo=gpu; glBindVertexArray(0);
        GLuint buffers[6],vaos[2]; glGenBuffers(6,buffers); glGenVertexArrays(2,vaos);
        for(int i=0;i<2;++i) {
            glBindBuffer(GL_ARRAY_BUFFER,buffers[i]); glBufferData(GL_ARRAY_BUFFER,sizeof data[i],data[i],GL_STATIC_DRAW);
        }
        glBindBuffer(GL_PIXEL_PACK_BUFFER,buffers[4]); glBufferData(GL_PIXEL_PACK_BUFFER,16,NULL,GL_STATIC_DRAW);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER,buffers[5]); glBufferData(GL_PIXEL_UNPACK_BUFFER,16,NULL,GL_STATIC_DRAW);
        for(int i=0;i<2;++i) {
            /* StateTracker 会省略相同 ARRAY_BUFFER 的重绑；VAO 切换本身不能取消前一步。 */
            glBindBuffer(GL_ARRAY_BUFFER,buffers[i]); glBindVertexArray(vaos[i]);
            GLint binding=0; glGetIntegerv(GL_ARRAY_BUFFER_BINDING,&binding);
            if(binding!=(GLint)buffers[i]) fail("VAO switch changed global ARRAY_BUFFER binding");
            glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING,&binding); if(binding!=(GLint)buffers[4]) fail("VAO switch changed PACK binding");
            glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING,&binding); if(binding!=(GLint)buffers[5]) fail("VAO switch changed UNPACK binding");
            glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING,&binding); if(binding!=0) fail("new VAO inherited EBO");
            glVertexAttribPointer(0,3,GL_UNSIGNED_SHORT,GL_FALSE,20,NULL);
            glVertexAttribPointer(1,4,GL_UNSIGNED_BYTE,GL_TRUE,20,(void*)8);
            glVertexAttribPointer(2,2,GL_UNSIGNED_SHORT,GL_FALSE,20,(void*)12);
            glVertexAttribPointer(3,2,GL_UNSIGNED_SHORT,GL_TRUE,20,(void*)16);
            for(int a=0;a<4;++a) {
                glEnableVertexAttribArray(a); glGetVertexAttribiv(a,GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING,&binding);
                if(binding!=(GLint)buffers[i]) fail("packed offset lost captured VBO");
            }
            const GLushort indices[3]={0,1,2};
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,buffers[2+i]); glBufferData(GL_ELEMENT_ARRAY_BUFFER,sizeof indices,indices,GL_STATIC_DRAW);
        }
        /* PBO 只用于全局状态查询，像素回读必须正常回到客户端目标。 */
        glBindBuffer(GL_PIXEL_PACK_BUFFER,0); glBindBuffer(GL_PIXEL_UNPACK_BUFFER,0);
        for(int i=0;i<2;++i) {
            glBindVertexArray(vaos[i]); GLint binding=0;
            glGetIntegerv(GL_ARRAY_BUFFER_BINDING,&binding); if(binding!=(GLint)buffers[1]) fail("VAO restored obsolete ARRAY_BUFFER");
            glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING,&binding); if(binding!=(GLint)buffers[2+i]) fail("VAO lost its EBO");
            glGetVertexAttribiv(0,GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING,&binding); if(binding!=(GLint)buffers[i]) fail("VAO attribute VBO changed with global binding");
            clear(); glMultiDrawArrays(GL_QUADS,firsts,counts,3); flush();
            if(i==0) rectangles(); else { pixel(18,20,0,255,255); pixel(48,20,0,255,255); pixel(78,20,0,255,255); }
            if(glGetError()!=GL_NO_ERROR) fail("valid packed VAO MultiDraw rejected");
        }
        glDeleteVertexArrays(1,&vaos[1]); GLint binding=-1;
        /* 上游头使用 OES 名称；0x85B5 与桌面 ARB/core 的 VERTEX_ARRAY_BINDING 完全相同。 */
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING_OES,&binding); if(binding!=0) fail("deleting bound VAO did not select zero");
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING,&binding); if(binding!=(GLint)buffers[1]) fail("deleting VAO changed global ARRAY_BUFFER");
        glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING,&binding); if(binding!=0) fail("default VAO acquired deleted VAO EBO");
        glDeleteVertexArrays(1,&vaos[0]); glBindBuffer(GL_ARRAY_BUFFER,0); glDeleteBuffers(6,buffers);
    }
    glUseProgram(0); glDeleteProgram(program); glDeleteShader(v); glDeleteShader(f);
}

static void topology(void) {
    scene(1); options->maxbatch=0;
    GLenum modes[]={GL_POINTS,GL_LINES,GL_LINE_STRIP,GL_LINE_LOOP,GL_TRIANGLES,GL_TRIANGLE_STRIP,GL_TRIANGLE_FAN,GL_QUADS,GL_QUAD_STRIP,GL_POLYGON};
    unsigned char multi[W*H*4], single[sizeof multi];
    for(size_t m=0;m<sizeof modes/sizeof modes[0];m++) {
        clear(); glMultiDrawArrays(modes[m],firsts,counts,3); flush(); glReadPixels(0,0,W,H,GL_RGBA,GL_UNSIGNED_BYTE,multi);
        clear(); for(int i=0;i<3;i++) glDrawArrays(modes[m],firsts[i],counts[i]); flush(); glReadPixels(0,0,W,H,GL_RGBA,GL_UNSIGNED_BYTE,single);
        if(memcmp(multi,single,sizeof multi)) { fprintf(stderr,"topology mode=%u\n",modes[m]); fail("MultiDraw topology differs from independent calls"); }
    }
}

/* 线框与独立边界序列比较，Polygon/QUADS 不能出现三角化的内部对角线。 */
static void wire(void) {
    scene(1); options->maxbatch=0; unsigned char multi[W*H*4],reference[sizeof multi];
    GLenum modes[]={GL_QUADS,GL_POLYGON};
    for(int m=0;m<2;m++) {
        clear(); glPolygonMode(GL_FRONT_AND_BACK,GL_LINE); glMultiDrawArrays(modes[m],firsts,counts,3);
        flush(); pixel(18,20,0,0,0); glReadPixels(0,0,W,H,GL_RGBA,GL_UNSIGNED_BYTE,multi);
        clear(); glPolygonMode(GL_FRONT_AND_BACK,GL_FILL);
        for(int b=0;b<3;b++) glDrawArrays(GL_LINE_LOOP,firsts[b],counts[b]);
        flush(); glReadPixels(0,0,W,H,GL_RGBA,GL_UNSIGNED_BYTE,reference);
        if(memcmp(multi,reference,sizeof multi)) fail("wire boundary changed");
    }
}

/* 重叠的三批透明面按 red→green→blue 提交，预先算出的 RGBA8 混合色检查真实顺序。 */
static void alpha(void) {
    scene(1); for(int b=0;b<3;b++) for(int k=0;k<4;k++) {
        memcpy(short_positions[b*4+k],short_positions[k],sizeof short_positions[k]); colors[b*4+k][3]=0.5f;
    }
    glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA);
    glMultiDrawArrays(GL_QUADS,firsts,counts,3); flush(); pixel(18,20,32,64,128); glDisable(GL_BLEND);
}

/* 2×2 纹理的三个不同 texcoord 来自真实客户端数组，遗漏/错槽会让多个矩形同色。 */
static void texture(void) {
    scene(1); glDisableClientState(GL_COLOR_ARRAY); glColor4f(1,1,1,1);
    GLfloat uv[12][2]; const GLfloat centres[3][2]={{0.25f,0.25f},{0.75f,0.25f},{0.25f,0.75f}};
    for(int b=0;b<3;b++) for(int k=0;k<4;k++) memcpy(uv[b*4+k],centres[b],sizeof centres[b]);
    const GLubyte pixels[16]={255,0,0,255,0,255,0,255,0,0,255,255,255,255,255,255};
    GLuint name; glGenTextures(1,&name); glBindTexture(GL_TEXTURE_2D,name);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,2,2,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
    glTexCoordPointer(2,GL_FLOAT,0,uv); glEnableClientState(GL_TEXTURE_COORD_ARRAY); glEnable(GL_TEXTURE_2D);
    glMultiDrawArrays(GL_QUADS,firsts,counts,3); flush(); rectangles();
    glDisable(GL_TEXTURE_2D); glDisableClientState(GL_TEXTURE_COORD_ARRAY); glDeleteTextures(1,&name);
}

static void allocation(void *library) {
    void (*inject)(int)=dlsym(library,"amcl_draw_test_fail_after");
    if(!inject) fail("production draw fault injector missing"); scene(1); options->maxbatch=0;
    for(int at=0;at<24;at++) {
        clear(); inject(at); glMultiDrawArrays(GL_QUADS,firsts,counts,3); inject(-1); flush();
        GLenum error=glGetError(); if(error!=GL_NO_ERROR && error!=GL_OUT_OF_MEMORY) fail("allocation diagnostic");
        clear(); glMultiDrawArrays(GL_QUADS,firsts,counts,3); flush(); rectangles();
    }
    options->maxbatch=100;
    for(int at=0;at<12;at++) {
        clear(); inject(at); glMultiDrawArrays(GL_QUADS,firsts,counts,3); inject(-1);
        if((*state)->list.active && !(*state)->list.active->len) fail("failed preparation published empty pending");
        flush(); glGetError(); clear(); glMultiDrawArrays(GL_QUADS,firsts,counts,3); flush(); rectangles();
    }
}

/* 同一context内的冷热缓存资格：每一步都使用上方独立固定像素oracle，不读取缓存
 * 反算golden。纹理名42和显示列表17有意删除后重用，区别于每case的新进程冷初始化。
 * 选项来自真实初始化；任何函数暗中覆盖profile都明确失败，不能标签写GPU却实际CPU。
 */
static int qa_batch,qa_vbo,qa_merge;
static unsigned qa_hot_steps;
static void hot_phase(const char *phase, unsigned iteration) {
    if(options->maxbatch!=qa_batch||options->usevbo!=qa_vbo||options->mergelist!=qa_merge)
        fail("hot profile changed during scene");
    ++qa_hot_steps;
    printf("HOT_PASS iteration=%u phase=%s maxbatch=%d usevbo=%d merge=%d\n",
        iteration,phase,options->maxbatch,options->usevbo,options->mergelist); fflush(stdout);
    if(glGetError()!=GL_NO_ERROR) fail("hot legal API sequence rejected");
}
/* 每个固定内点都远离矩形边缘，黑色外点还验证清屏及没有多余覆盖。 */
static void hot_solid(int r,int g,int b) {
    pixel(18,20,r,g,b);pixel(48,20,r,g,b);pixel(78,20,r,g,b);pixel(3,3,0,0,0);
}
/* 真实GLSL编译/链接。空uniform程序用于验证零大小cache；有uniform程序在同次绑定
 * 内改变颜色，热路径若未上传新值必须在像素oracle失败。shader名也随program退休。
 */
static GLuint hot_program(int with_uniform) {
    const char *vs="#version 120\nattribute vec2 aPosition; void main(){gl_Position=vec4(aPosition.x/48.0-1.0,aPosition.y/32.0-1.0,0.0,1.0);}";
    const char *fs=with_uniform?"#version 120\nuniform vec4 uColor; void main(){gl_FragColor=uColor;}":
        "#version 120\nvoid main(){gl_FragColor=vec4(0.0,1.0,0.0,1.0);}";
    GLuint v=glCreateShader(GL_VERTEX_SHADER),f=glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(v,1,&vs,NULL);glCompileShader(v);glShaderSource(f,1,&fs,NULL);glCompileShader(f);
    GLint ok=0;glGetShaderiv(v,GL_COMPILE_STATUS,&ok);if(!ok) fail("hot vertex shader compile");
    glGetShaderiv(f,GL_COMPILE_STATUS,&ok);if(!ok) fail("hot fragment shader compile");
    GLuint p=glCreateProgram();glAttachShader(p,v);glAttachShader(p,f);glBindAttribLocation(p,0,"aPosition");glLinkProgram(p);
    glGetProgramiv(p,GL_LINK_STATUS,&ok);if(!ok) fail("hot program link");
    glDeleteShader(v);glDeleteShader(f);return p;
}
/* 纹理零对象与显式名字使用同一组确定UV；两个颜色阶段分别已知红/绿，不依赖被测
 * 纹理查询。caller-fault负控只遗漏删除/新上传，检验oracle会拒绝真实旧像素。
 */
static void hot_texture(GLuint name,const GLubyte *data) {
    static const GLfloat uv[12][2]={{.5,.5},{.5,.5},{.5,.5},{.5,.5},{.5,.5},{.5,.5},{.5,.5},{.5,.5},{.5,.5},{.5,.5},{.5,.5},{.5,.5}};
    scene(0);glDisableClientState(GL_COLOR_ARRAY);glColor4f(1,1,1,1);
    glBindTexture(GL_TEXTURE_2D,name);GLint bound=-1;glGetIntegerv(GL_TEXTURE_BINDING_2D,&bound);
    GLfloat float_bound=-1;glGetFloatv(GL_TEXTURE_BINDING_2D,&float_bound);
    printf("HOT_TEXTURE_BINDING requested=%u integer=%d float=%.0f\n",name,bound,float_bound);fflush(stdout);
    if(bound!=(GLint)name) fail("hot texture binding differs from requested reused name");
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    if(data) glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,1,1,0,GL_RGBA,GL_UNSIGNED_BYTE,data);
    glTexCoordPointer(2,GL_FLOAT,0,uv);glEnableClientState(GL_TEXTURE_COORD_ARRAY);glEnable(GL_TEXTURE_2D);
    glMultiDrawArrays(GL_QUADS,firsts,counts,3);flush();
}
static void hot_cache(void) {
    const char *control=getenv("AMCL_QA_HOT_CONTROL");
    const char *count=getenv("AMCL_QA_HOT_ITERATIONS");unsigned iterations=count?(unsigned)strtoul(count,NULL,10):8;
    if(!iterations||iterations>32) fail("hot iteration budget out of range");
    const GLubyte red[4]={255,0,0,255},green[4]={0,255,0,255};
    for(unsigned n=0;n<iterations;n++) {
        glUseProgram(0);glDisable(GL_TEXTURE_2D);glDisableClientState(GL_TEXTURE_COORD_ARRAY);
        scene(0);clear();glMultiDrawArrays(GL_QUADS,firsts,counts,3);flush();rectangles();hot_phase("fixed-no-texture",n);
        clear();hot_texture(0,green);hot_solid(0,255,0);hot_phase("texture-zero",n);
        GLuint name=42;clear();hot_texture(name,red);hot_solid(255,0,0);hot_phase("texture-named",n);
        const int stale_texture=control&&!strcmp(control,"stale-texture");
        if(!stale_texture) {glDeleteTextures(1,&name);GLint bound=-1;glGetIntegerv(GL_TEXTURE_BINDING_2D,&bound);if(bound!=0) fail("deleted texture still bound");}
        clear();hot_texture(name,stale_texture?NULL:green);
        printf("HOT_BEGIN iteration=%u phase=texture-recreated\n",n);fflush(stdout);
        hot_solid(0,255,0);hot_phase("texture-recreated",n);glDeleteTextures(1,&name);
        glDisable(GL_TEXTURE_2D);glDisableClientState(GL_TEXTURE_COORD_ARRAY);scene(0);
        GLuint program=hot_program(1);glUseProgram(program);glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,0,positions);glEnableVertexAttribArray(0);
        GLint location=glGetUniformLocation(program,"uColor");if(location<0) fail("hot required uniform missing");
        clear();glUniform4f(location,1,0,0,1);glMultiDrawArrays(GL_QUADS,firsts,counts,3);flush();hot_solid(255,0,0);hot_phase("uniform-red",n);
        clear();if(!(control&&!strcmp(control,"stale-uniform"))) glUniform4f(location,0,1,0,1);
        glMultiDrawArrays(GL_QUADS,firsts,counts,3);flush();printf("HOT_BEGIN iteration=%u phase=uniform-green\n",n);fflush(stdout);
        hot_solid(0,255,0);hot_phase("uniform-green",n);glUseProgram(0);glDeleteProgram(program);
        program=hot_program(0);glUseProgram(program);if(glGetUniformLocation(program,"uColor")!=-1) fail("empty program retained stale uniform");
        clear();glMultiDrawArrays(GL_QUADS,firsts,counts,3);flush();hot_solid(0,255,0);hot_phase("empty-uniform-program",n);
        glUseProgram(0);glDeleteProgram(program);glDisableVertexAttribArray(0);scene(0);clear();
        glNewList(17,GL_COMPILE);glMultiDrawArrays(GL_QUADS,firsts,counts,3);glEndList();
        memset(positions,0,sizeof positions);memset(colors,0,sizeof colors);glCallList(17);flush();rectangles();hot_phase("display-list-recreated",n);glDeleteLists(17,1);
    }
    printf("HOT_RESULT completed=1 iterations=%u steps=%u expectedSteps=%u maxbatch=%d usevbo=%d merge=%d\n",
        iterations,qa_hot_steps,iterations*8,qa_batch,qa_vbo,qa_merge);
    if(qa_hot_steps!=iterations*8) fail("hot scene incomplete");
}
/* 五种纹理绑定token、两纹理单元、删除重建以及高于float精确整数范围的逻辑名。
 * 对float只要求规范类型转换；int与double必须保存原始名字，不用float结果生成oracle。
 * integer64不属于本fork宣告的GL2.1且没有实现导出，只记录明确不适用，不伪造函数。
 */
static void binding_expect(GLenum query, GLuint expected) {
    GLint i[3]={713,-1,714};GLfloat f[3]={723,-1,724};GLdouble d[3]={733,-1,734};GLboolean b[3]={83,2,84};
    glGetIntegerv(query,i+1);glGetFloatv(query,f+1);glGetDoublev(query,d+1);glGetBooleanv(query,b+1);
    printf("BINDING_QUERY token=%u expected=%u integer=%d float=%.0f double=%.0f boolean=%u\n",query,expected,i[1],f[1],d[1],b[1]);fflush(stdout);
    if(i[0]!=713||i[2]!=714||f[0]!=723||f[2]!=724||d[0]!=733||d[2]!=734||b[0]!=83||b[2]!=84||i[1]!=(GLint)expected||f[1]!=(GLfloat)expected||d[1]!=(GLdouble)expected||b[1]!=(expected?GL_TRUE:GL_FALSE))
        fail("desktop texture binding query name/width invariant");
    if(glGetError()!=GL_NO_ERROR) fail("legal texture binding query rejected");
}
static void texture_bindings(void *library) {
    GLenum targets[]={GL_TEXTURE_1D,GL_TEXTURE_2D,GL_TEXTURE_3D,GL_TEXTURE_RECTANGLE_ARB,GL_TEXTURE_CUBE_MAP};
    GLenum queries[]={GL_TEXTURE_BINDING_1D,GL_TEXTURE_BINDING_2D,GL_TEXTURE_BINDING_3D,GL_TEXTURE_BINDING_RECTANGLE_ARB,GL_TEXTURE_BINDING_CUBE_MAP};
    for(int target=0;target<5;target++) {
        GLuint name=42+target,large=16777217u+target*2u;
        glActiveTexture(GL_TEXTURE0);glBindTexture(targets[target],name);binding_expect(queries[target],name);
        glActiveTexture(GL_TEXTURE1);binding_expect(queries[target],0);glBindTexture(targets[target],large);binding_expect(queries[target],large);
        glActiveTexture(GL_TEXTURE0);binding_expect(queries[target],name);glDeleteTextures(1,&name);binding_expect(queries[target],0);
        glBindTexture(targets[target],name);binding_expect(queries[target],name);glDeleteTextures(1,&name);binding_expect(queries[target],0);
        glActiveTexture(GL_TEXTURE1);binding_expect(queries[target],large);glDeleteTextures(1,&large);binding_expect(queries[target],0);
    }
    glActiveTexture(GL_TEXTURE0);
    if(dlsym(library,"glGetInteger64v")) fail("unexpected integer64 export needs a real matching qualification case");
    printf("BINDING_RESULT completed=1 queries=45 targets=5 units=2 integer64=NOT_APPLICABLE_GL21_NO_EXPORT\n");
}
/* 两个独立进程case分别使用真实shim与真实GLES错误产生路径。先用生产GetError确认
 * 注入本身可靠，再重复同一错误→合法boolean绑定查询→GetError，禁止直接写错误字段
 * 当替身。shim路径用非法texture unit，现有texture_params入口会errorShim1但
 * 不改原active unit；0002保护的Draw3错误不能校准通用noerrorShim吞错。
 * driver路径用公开glEnable非法cap，现有proxy将选择errorGL并调用真实GLES。
 */
static void boolean_pending_error(int driver) {
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,42);
    for(int n=0;n<8&&glGetError()!=GL_NO_ERROR;n++) {}
    const GLenum expected=GL_INVALID_ENUM;
    for(int control=0;control<2;control++) {
        if(driver) glEnable(0xFFFF); else glActiveTexture(0xFFFF);
        if((driver&&(*state)->shim_error!=0)||(!driver&&((*state)->shim_error!=1||(*state)->last_error!=expected)))
            fail("pending error production injection path not established");
        if(control) {
            const int old_shim=(*state)->shim_error;const GLenum old_error=(*state)->last_error;
            GLboolean value[3]={83,2,84};glGetBooleanv(GL_TEXTURE_BINDING_2D,value+1);
            if(value[0]!=83||value[2]!=84||value[1]!=GL_TRUE) fail("pending error boolean binding value/width");
            /* 只读诊断pair用于证明查询没有转换driver/shim通道；主要oracle仍是紧随
             * 其后的公开GetError。负控须在GetError断言失败，不能借内部字段绕过。 */
            printf("BOOLEAN_PAIR kind=%s oldShim=%d actualShim=%d oldError=%u actualError=%u\n",
                driver?"driver":"shim",old_shim,(*state)->shim_error,old_error,(*state)->last_error);
        }
        GLenum actual=glGetError();
        printf("BOOLEAN_PENDING kind=%s queried=%d expected=%u actual=%u\n",driver?"driver":"shim",control,expected,actual);fflush(stdout);
        if(actual!=expected) fail(driver?"boolean binding preserves pending driver error":"boolean binding preserves pending shim error");
        if(glGetError()!=GL_NO_ERROR) fail("pending error did not clear after GetError");
    }
}

int main(int argc,char **argv) {
    if(argc!=3) return 3;
    EGLDisplay display=eglGetDisplay(EGL_DEFAULT_DISPLAY); EGLint major,minor;
    if(!eglInitialize(display,&major,&minor)) fail("EGL software display");
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint config_attributes[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config; EGLint number; eglChooseConfig(display,config_attributes,&config,1,&number);
    if(!number) fail("EGL config");
    EGLint surface_attributes[]={EGL_WIDTH,W,EGL_HEIGHT,H,EGL_NONE};
    EGLSurface surface=eglCreatePbufferSurface(display,config,surface_attributes);
    EGLint context_attributes[]={EGL_CONTEXT_CLIENT_VERSION,2,EGL_NONE};
    EGLContext context=eglCreateContext(display,config,EGL_NO_CONTEXT,context_attributes);
    if(!eglMakeCurrent(display,surface,surface,context)) fail("EGL current");
    __lsan_disable();
    void *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); if(!library) { __lsan_enable(); fprintf(stderr,"%s\n",dlerror()); return 3; }
    void (*initialize)(void)=dlsym(library,"initialize_gl4es");
    /* 上游初始化具有进程常驻对象和不完整析构；单独排除初始化分配，不排除任何 Draw/FPE 绘制分配。 */
    /* 每个 lazy-* 用独立进程验证一处实际首入口，不显式调用 initialize。
     * EGL 已 current，符合 OHOS 由 LWJGL 在独立 namespace 首次调用 getter 的契约。
     * 排除的仍只有既有初始化常驻对象，随后继续同一套真实像素/状态验收。
     */
    const char *name=argv[2];
    if(!strncmp(name,"lazy-",5)) {
        if(!strcmp(name,"lazy-error")) {
            GLenum (*first)(void)=dlsym(library,"glGetError"); if(!first) fail("first GetError absent"); first();
        } else if(!strcmp(name,"lazy-string")) {
            const GLubyte* (*first)(GLenum)=dlsym(library,"glGetString"); if(!first||!first(GL_VERSION)) fail("first GetString absent/empty");
        } else if(!strcmp(name,"lazy-integer")) {
            void (*first)(GLenum,GLint*)=dlsym(library,"glGetIntegerv"); GLint size=0;
            if(!first) fail("first GetIntegerv absent"); first(GL_MAX_TEXTURE_SIZE,&size); if(size<=0) fail("first texture cap empty");
        } else if(!strcmp(name,"lazy-float")) {
            void (*first)(GLenum,GLfloat*)=dlsym(library,"glGetFloatv"); GLfloat width=0;
            if(!first) fail("first GetFloatv absent"); first(GL_LINE_WIDTH,&width); if(width<=0) fail("first line width empty");
        } else if(!strcmp(name,"lazy-stringi")) {
            const GLubyte* (*first)(GLenum,GLuint)=dlsym(library,"glGetStringi"); if(!first||!first(GL_EXTENSIONS,0)) fail("first GetStringi absent/empty");
        } else fail("unknown first getter");
    } else initialize();
    __lsan_enable();
    state=dlsym(library,"glstate"); options=dlsym(library,"globals4es");
    if(!state||!*state||!options) fail("production state missing");
    qa_batch=options->maxbatch;qa_vbo=options->usevbo;qa_merge=options->mergelist;
    printf("QA_INITIAL case=%s maxbatch=%d usevbo=%d merge=%d\n",name,qa_batch,qa_vbo,qa_merge);fflush(stdout);
    if(strcmp(name,"hot-cache")) {options->maxbatch=0;options->usevbo=0;}
    /* API 清单显式列出，保证缺失真实导出时失败；不能退回替身继续宣称生产路径通过。 */
#define LOAD(N) N=dlsym(library,#N); if(!N) fail("missing " #N)
    LOAD(glClearColor);LOAD(glClear);LOAD(glViewport);LOAD(glReadPixels);LOAD(glEnable);LOAD(glDisable);
    LOAD(glEnableClientState);LOAD(glDisableClientState);LOAD(glVertexPointer);LOAD(glColorPointer);LOAD(glColor4f);
    LOAD(glMatrixMode);LOAD(glLoadIdentity);LOAD(glOrtho);LOAD(glMultiDrawArrays);LOAD(glMultiDrawElements);
    LOAD(glMultiDrawElementsBaseVertex);LOAD(glDrawArrays);LOAD(glDrawElements);LOAD(glGetError);LOAD(glFinish);
    LOAD(glGenBuffers);LOAD(glBindBuffer);LOAD(glBufferData);LOAD(glDeleteBuffers);LOAD(glMapBuffer);LOAD(glUnmapBuffer);
    LOAD(glGenVertexArrays);LOAD(glBindVertexArray);LOAD(glDeleteVertexArrays);LOAD(glGetIntegerv);LOAD(glGetVertexAttribiv);
    LOAD(glNewList);LOAD(glEndList);LOAD(glCallList);LOAD(glDeleteLists);LOAD(glPolygonMode);LOAD(glBegin);LOAD(glEnd);
    LOAD(glBlendFunc);LOAD(glGenTextures);LOAD(glBindTexture);LOAD(glTexParameteri);LOAD(glTexImage2D);LOAD(glTexCoordPointer);LOAD(glDeleteTextures);
    LOAD(glCreateShader);LOAD(glShaderSource);LOAD(glCompileShader);LOAD(glGetShaderiv);LOAD(glGetShaderInfoLog);
    LOAD(glCreateProgram);LOAD(glAttachShader);LOAD(glBindAttribLocation);LOAD(glLinkProgram);LOAD(glGetProgramiv);
    LOAD(glGetUniformLocation);LOAD(glUniform4f);
    LOAD(glGetFloatv);
    LOAD(glGetDoublev);LOAD(glActiveTexture);
    LOAD(glGetBooleanv);
    LOAD(glUseProgram);LOAD(glDeleteProgram);LOAD(glDeleteShader);LOAD(glEnableVertexAttribArray);
    LOAD(glDisableVertexAttribArray);LOAD(glVertexAttribPointer);LOAD(glVertexAttrib4f);
    glViewport(0,0,W,H); glMatrixMode(GL_PROJECTION); glLoadIdentity(); glOrtho(0,W,0,H,-1,1);
    glMatrixMode(GL_MODELVIEW); glLoadIdentity(); clear();
    for(int drain=0;drain<8 && glGetError()!=GL_NO_ERROR;++drain) {}
    if(!strcmp(name,"boolean-shim-error")) boolean_pending_error(0);
    else if(!strcmp(name,"boolean-driver-error")) boolean_pending_error(1);
    else if(!strcmp(name,"texture-bindings")) texture_bindings(library);
    else if(!strcmp(name,"hot-cache")) hot_cache();
    else if(!strncmp(name,"lazy-",5)) arrays("arrays-merge");
    else if(!strcmp(name,"arrays-merge")||!strcmp(name,"arrays-no-merge")||!strcmp(name,"display-list")||!strcmp(name,"pending")) arrays(name);
    else if(!strcmp(name,"elements-direct")) elements(0,0);
    else if(!strcmp(name,"elements-list")) elements(1,0);
    else if(!strcmp(name,"basevertex")) elements(0,1);
    else if(!strcmp(name,"zero")) errors(1);
    else if(!strcmp(name,"errors")) errors(0);
    else if(!strcmp(name,"bounds")) bounds();
    else if(!strcmp(name,"wide")) wide();
    else if(!strcmp(name,"compact")) compact();
    else if(!strcmp(name,"vao-bindings")) vao_bindings();
    else if(!strcmp(name,"topology")) topology();
    else if(!strcmp(name,"wire")) wire();
    else if(!strcmp(name,"alpha")) alpha();
    else if(!strcmp(name,"texture")) texture();
    else if(!strcmp(name,"allocation")) allocation(library);
    else fail("unknown case");
    /* 旧case有自己的限定开关，不能把外层profile标签借给其实际CPU或禁批次路径。 */
    printf("QA_FINAL case=%s maxbatch=%d usevbo=%d merge=%d\n",name,options->maxbatch,options->usevbo,options->mergelist);fflush(stdout);
    /* Draw 作用域结束时检查不可达资源；进程级 FPE/program 缓存仍有合法持有者。
     * 上游进程析构的不完整清理另属生命周期审计，不能误报为每次 Draw 泄漏。
     */
    int leaks=__lsan_do_recoverable_leak_check();
    dlclose(library); eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
    eglDestroyContext(display,context); eglDestroySurface(display,surface); eglTerminate(display);
    fprintf(stdout,"PASS %s: production library + actual GLES pixels/state\n",name);
    fflush(stdout); fflush(stderr);
    _Exit(leaks?1:0);
}
