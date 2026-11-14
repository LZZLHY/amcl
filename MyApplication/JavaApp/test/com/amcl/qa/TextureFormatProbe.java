package com.amcl.qa;

import java.io.*;
import java.nio.*;
import org.lwjgl.BufferUtils;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import static org.lwjgl.opengl.GL45C.*;

/**
 * 真实provider上的纹理存储回归。所有期望像素先由明确上传或GPU clear定义，绝不检查undefined内容。
 * 同一个JAR分别运行旧/新MobileGL；测试不进入启动器JAR，不修改整合包，不以getter代替像素证据。
 */
public final class TextureFormatProbe {
    private static int checks, failures, fbo;
    private static final int SIZE=8;
    private static final int[] RED={255,0,0,255}, GREEN={0,255,0,255}, BLUE={0,0,255,255};
    private TextureFormatProbe() { }

    /** 确定性RGBA输入，position/limit覆盖完整上传字节。 */
    private static ByteBuffer pixels(int count,int[] rgba){
        ByteBuffer result=BufferUtils.createByteBuffer(count*4);
        for(int n=0;n<count;n++)for(int v:rgba)result.put((byte)v);
        return (ByteBuffer)result.flip();
    }
    private static void error(String label){int code=glGetError();checks++;if(code!=GL_NO_ERROR){failures++;System.out.println("AMCL_STORAGE_ERROR label="+label+" error="+code);}}
    private static void attach2D(int target,int texture,int level){
        glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,target,texture,level);
        if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("incomplete FBO");
    }
    /** GPU写入与后续CPU写入属于不同权威来源；局部更新不能用过期CPU副本覆盖外围。 */
    private static void clearRed(){glDisable(GL_SCISSOR_TEST);glClearColor(1,0,0,1);glClear(GL_COLOR_BUFFER_BIT);glFinish();}
    private static void checkPixels(String label,int size,boolean patched){
        checkPixels(label,size,patched?1:0);
    }
    /** L形反例专门检查dirty区域合并是否把未修改的GPU像素错误扩大成包围盒。 */
    private static void checkPixels(String label,int size,int pattern){
        ByteBuffer result=BufferUtils.createByteBuffer(size*size*4);glReadPixels(0,0,size,size,GL_RGBA,GL_UNSIGNED_BYTE,result);
        int bad=0;String first="";
        for(int y=0;y<size;y++)for(int x=0;x<size;x++){
            boolean green=pattern==1&&x>=2&&x<4&&y>=2&&y<4;
            if(pattern==2)green=(x>=1&&x<3&&y>=1&&y<3)||(x>=2&&x<4&&y>=2&&y<4);
            int[] expected=green?GREEN:RED;
            boolean ok=true;for(int c=0;c<4;c++)ok&=(result.get((y*size+x)*4+c)&255)==expected[c];
            checks++;if(!ok){failures++;bad++;if(first.isEmpty())first=x+","+y+":"+(result.get((y*size+x)*4)&255)+","+(result.get((y*size+x)*4+1)&255)+","+(result.get((y*size+x)*4+2)&255);}
        }
        System.out.println("AMCL_STORAGE_PIXELS label="+label+" failedPixels="+bad+" first="+first);error(label);
    }
    /** 行长度和跳过像素同时生效，实际2x2绿块被蓝色padding包围；测试恢复全部改动的unpack状态。 */
    private static ByteBuffer patchData(){
        ByteBuffer data=pixels(20,BLUE);
        for(int y=1;y<3;y++)for(int x=1;x<3;x++)for(int c=0;c<4;c++)data.put((y*5+x)*4+c,(byte)GREEN[c]);
        glPixelStorei(GL_UNPACK_ALIGNMENT,1);glPixelStorei(GL_UNPACK_ROW_LENGTH,5);glPixelStorei(GL_UNPACK_SKIP_ROWS,1);glPixelStorei(GL_UNPACK_SKIP_PIXELS,1);
        return data;
    }
    private static void resetUnpack(){glPixelStorei(GL_UNPACK_ALIGNMENT,4);glPixelStorei(GL_UNPACK_ROW_LENGTH,0);glPixelStorei(GL_UNPACK_SKIP_ROWS,0);glPixelStorei(GL_UNPACK_SKIP_PIXELS,0);}

    /** PBO绑定时0L是实际字节偏移，不是NULL像素；该例必须保留全部初始红色数据。 */
    private static void twoDimensional(int mode){
        int texture=glGenTextures(),pbo=0;glBindTexture(GL_TEXTURE_2D,texture);
        if(mode==1)glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,SIZE,SIZE);
        else if(mode==2){pbo=glGenBuffers();glBindBuffer(GL_PIXEL_UNPACK_BUFFER,pbo);glBufferData(GL_PIXEL_UNPACK_BUFFER,pixels(SIZE*SIZE,RED),GL_STATIC_DRAW);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,SIZE,SIZE,0,GL_RGBA,GL_UNSIGNED_BYTE,0L);glBindBuffer(GL_PIXEL_UNPACK_BUFFER,0);}
        else glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,SIZE,SIZE,0,GL_RGBA,GL_UNSIGNED_BYTE,mode==3?pixels(SIZE*SIZE,RED):(ByteBuffer)null);
        // 不在clear与patch之间插入readPixels：它会意外兑现lazy clear，掩盖已复现的顺序缺陷。
        attach2D(GL_TEXTURE_2D,texture,0);if(mode<2)clearRed();
        glTexSubImage2D(GL_TEXTURE_2D,0,2,2,2,2,GL_RGBA,GL_UNSIGNED_BYTE,patchData());resetUnpack();
        checkPixels("2d-gpu-cpu-partial-"+mode,SIZE,true);
        glDeleteTextures(texture);if(pbo!=0)glDeleteBuffers(pbo);
    }
    /** 三层array分别先由GPU定义，CPU只修改中间层的2x2；其余层和外围保持原色。 */
    private static void arrayTexture(){
        int texture=glGenTextures();glBindTexture(GL_TEXTURE_2D_ARRAY,texture);glTexStorage3D(GL_TEXTURE_2D_ARRAY,1,GL_RGBA8,SIZE,SIZE,3);
        for(int layer=0;layer<3;layer++){glFramebufferTextureLayer(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,texture,0,layer);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("array FBO");clearRed();}
        glTexSubImage3D(GL_TEXTURE_2D_ARRAY,0,2,2,1,2,2,1,GL_RGBA,GL_UNSIGNED_BYTE,patchData());resetUnpack();
        for(int layer=0;layer<3;layer++){glFramebufferTextureLayer(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,texture,0,layer);checkPixels("array-layer-"+layer,SIZE,layer==1);}
        glDeleteTextures(texture);
    }
    /** cube各面独立；不可变存储的延迟CPU初始化不能改变face映射。 */
    private static void cubeTexture(){
        int texture=glGenTextures();glBindTexture(GL_TEXTURE_CUBE_MAP,texture);glTexStorage2D(GL_TEXTURE_CUBE_MAP,1,GL_RGBA8,SIZE,SIZE);
        for(int face=0;face<6;face++){attach2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X+face,texture,0);clearRed();}
        glTexSubImage2D(GL_TEXTURE_CUBE_MAP_NEGATIVE_Z,0,2,2,2,2,GL_RGBA,GL_UNSIGNED_BYTE,patchData());resetUnpack();
        for(int face=0;face<6;face++){attach2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X+face,texture,0);checkPixels("cube-face-"+face,SIZE,face==5);}
        glDeleteTextures(texture);
    }
    /** GPU定义的base level生成mips，逐级检查实际FBO；均匀色避免滤波舍入和LOD选择争议。 */
    private static void mipmaps(){
        int texture=glGenTextures();glBindTexture(GL_TEXTURE_2D,texture);glTexStorage2D(GL_TEXTURE_2D,4,GL_RGBA8,SIZE,SIZE);
        attach2D(GL_TEXTURE_2D,texture,0);clearRed();glGenerateMipmap(GL_TEXTURE_2D);
        for(int level=0;level<4;level++){attach2D(GL_TEXTURE_2D,texture,level);checkPixels("gpu-mip-"+level,SIZE>>level,false);}
        glDeleteTextures(texture);
    }
    /** 这里有意预读只为隔离另一缺陷：两个部分重叠rect合并后仍必须保留L形外侧GPU红色。 */
    private static void scatteredUpdates(){
        int texture=glGenTextures();glBindTexture(GL_TEXTURE_2D,texture);glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,SIZE,SIZE);
        attach2D(GL_TEXTURE_2D,texture,0);clearRed();checkPixels("scatter-pre-read",SIZE,false);
        glTexSubImage2D(GL_TEXTURE_2D,0,1,1,2,2,GL_RGBA,GL_UNSIGNED_BYTE,pixels(4,GREEN));
        glTexSubImage2D(GL_TEXTURE_2D,0,2,2,2,2,GL_RGBA,GL_UNSIGNED_BYTE,pixels(4,GREEN));
        checkPixels("scatter-L-shape",SIZE,2);glDeleteTextures(texture);
    }
    /** 只调用实际公开的扩展；缺cap明确输出未覆盖，不伪造高版本context或手填函数地址。 */
    private static void namedAndClearUpdates(){
        boolean named=GL.getCapabilities().GL_ARB_direct_state_access,clear=GL.getCapabilities().GL_ARB_clear_texture;
        System.out.println("AMCL_STORAGE_OPTIONAL directStateAccess="+named+" clearTexture="+clear);
        for(int mode=0;mode<2;mode++){
            if((mode==0&&!named)||(mode==1&&!clear))continue;
            int texture=glGenTextures();glBindTexture(GL_TEXTURE_2D,texture);glTexStorage2D(GL_TEXTURE_2D,1,GL_RGBA8,SIZE,SIZE);
            attach2D(GL_TEXTURE_2D,texture,0);clearRed();glBindTexture(GL_TEXTURE_2D,0);
            if(mode==0)glTextureSubImage2D(texture,0,2,2,2,2,GL_RGBA,GL_UNSIGNED_BYTE,pixels(4,GREEN));
            else glClearTexSubImage(texture,0,2,2,0,2,2,1,GL_RGBA,GL_UNSIGNED_BYTE,pixels(1,GREEN));
            checks++;if(glGetInteger(GL_TEXTURE_BINDING_2D)!=0)failures++;
            checkPixels(mode==0?"named-subimage":"clear-subimage",SIZE,true);glDeleteTextures(texture);
        }
    }
    /** 本进程RSS只作观测，不设跨allocator的脆弱通过阈值；未使用纹理不应被当成GPU分配测量。 */
    private static long rss(){
        try(BufferedReader r=new BufferedReader(new FileReader("/proc/self/status"))){String s;while((s=r.readLine())!=null)if(s.startsWith("VmRSS:"))return Long.parseLong(s.substring(6).trim().split("\\s+")[0]);}
        catch(Exception ignored){return -1;}return -1;
    }
    private static void allocationObservation(){
        glBindFramebuffer(GL_FRAMEBUFFER,0);long before=rss();int[] textures=new int[8];
        for(int i=0;i<textures.length;i++){textures[i]=glGenTextures();glBindTexture(GL_TEXTURE_2D,textures[i]);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,2048,2048,0,GL_RGBA,GL_UNSIGNED_BYTE,(ByteBuffer)null);}
        long after=rss();System.out.println("AMCL_STORAGE_MEMORY logicalBytes=134217728 beforeRssKB="+before+" afterRssKB="+after+" deltaKB="+(after-before)+" scope=undefined-unconsumed-textures");
        for(int texture:textures)glDeleteTextures(texture);error("allocation-observation");
    }

    /** RGB8在目标GPU上可能扩展为RGBA，转换必须只覆盖真实2x2区域。 */
    private static void rgbPartial(){
        int texture=glGenTextures();glBindTexture(GL_TEXTURE_2D,texture);glTexStorage2D(GL_TEXTURE_2D,1,GL_RGB8,SIZE,SIZE);
        attach2D(GL_TEXTURE_2D,texture,0);clearRed();checkPixels("rgb-pre-read",SIZE,false);
        ByteBuffer patch=BufferUtils.createByteBuffer(12);for(int i=0;i<4;i++)patch.put((byte)0).put((byte)255).put((byte)0);patch.flip();
        glPixelStorei(GL_UNPACK_ALIGNMENT,1);glTexSubImage2D(GL_TEXTURE_2D,0,2,2,2,2,GL_RGB,GL_UNSIGNED_BYTE,patch);resetUnpack();
        checkPixels("rgb-partial",SIZE,true);glDeleteTextures(texture);
    }
    /** depth与stencil分别读回外围和patch，不能只检查颜色附件或只检查写入区。 */
    private static void depthPartial(boolean combined,int patchSize){
        int texture=glGenTextures();glBindTexture(GL_TEXTURE_2D,texture);glTexStorage2D(GL_TEXTURE_2D,1,combined?GL_DEPTH24_STENCIL8:GL_DEPTH_COMPONENT32F,SIZE,SIZE);
        glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,0,0);
        int attachment=combined?GL_DEPTH_STENCIL_ATTACHMENT:GL_DEPTH_ATTACHMENT;
        glFramebufferTexture2D(GL_FRAMEBUFFER,attachment,GL_TEXTURE_2D,texture,0);glDrawBuffer(GL_NONE);glReadBuffer(GL_NONE);
        if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("depth FBO");
        glDepthMask(true);glStencilMask(255);glClearDepth(.75);glClearStencil(3);glClear(GL_DEPTH_BUFFER_BIT|(combined?GL_STENCIL_BUFFER_BIT:0));
        FloatBuffer prior=BufferUtils.createFloatBuffer(64);glReadPixels(0,0,SIZE,SIZE,GL_DEPTH_COMPONENT,GL_FLOAT,prior);
        for(int i=0;i<64;i++){checks++;if(Math.abs(prior.get(i)-.75f)>.0001f)failures++;}error("depth-pre-read-"+combined);
        if(combined){IntBuffer patch=BufferUtils.createIntBuffer(patchSize*patchSize);for(int i=0;i<patchSize*patchSize;i++)patch.put(0x40000007);patch.flip();glTexSubImage2D(GL_TEXTURE_2D,0,2,2,patchSize,patchSize,GL_DEPTH_STENCIL,GL_UNSIGNED_INT_24_8,patch);}
        else{FloatBuffer patch=BufferUtils.createFloatBuffer(patchSize*patchSize);for(int i=0;i<patchSize*patchSize;i++)patch.put(.25f);patch.flip();glTexSubImage2D(GL_TEXTURE_2D,0,2,2,patchSize,patchSize,GL_DEPTH_COMPONENT,GL_FLOAT,patch);}
        FloatBuffer depth=BufferUtils.createFloatBuffer(64);ByteBuffer stencil=BufferUtils.createByteBuffer(64);
        glReadPixels(0,0,SIZE,SIZE,GL_DEPTH_COMPONENT,GL_FLOAT,depth);if(combined)glReadPixels(0,0,SIZE,SIZE,GL_STENCIL_INDEX,GL_UNSIGNED_BYTE,stencil);
        int badDepth=0,badStencil=0;
        for(int y=0;y<SIZE;y++)for(int x=0;x<SIZE;x++){boolean patch=x>=2&&x<2+patchSize&&y>=2&&y<2+patchSize;int i=y*SIZE+x;checks++;if(Math.abs(depth.get(i)-(patch?.25f:.75f))>.0001f){failures++;badDepth++;}if(combined){checks++;if((stencil.get(i)&255)!=(patch?7:3)){failures++;badStencil++;}}}
        System.out.println("AMCL_STORAGE_FORMAT combined="+combined+" patchSize="+patchSize+" badDepth="+badDepth+" badStencil="+badStencil);error("depth-partial-"+combined);
        glFramebufferTexture2D(GL_FRAMEBUFFER,attachment,GL_TEXTURE_2D,0,0);glDrawBuffer(GL_COLOR_ATTACHMENT0);glReadBuffer(GL_COLOR_ATTACHMENT0);glDeleteTextures(texture);
    }

    public static void main(String[] arguments){
        long window=0;
        try{
            if(!GLFW.glfwInit())throw new AssertionError("glfw init");GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR,3);GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR,3);GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE,GLFW.GLFW_OPENGL_CORE_PROFILE);
            window=GLFW.glfwCreateWindow(64,64,"AMCL texture storage QA",0,0);if(window==0)throw new AssertionError("GLFW window");GLFW.glfwMakeContextCurrent(window);GL.createCapabilities();
            System.out.println("AMCL_STORAGE_IDENTITY version="+glGetString(GL_VERSION)+" renderer="+glGetString(GL_RENDERER));
            fbo=glGenFramebuffers();glBindFramebuffer(GL_FRAMEBUFFER,fbo);glDisable(GL_BLEND);glDisable(GL_DEPTH_TEST);glDisable(GL_STENCIL_TEST);glColorMask(true,true,true,true);glViewport(0,0,SIZE,SIZE);
            for(int mode=0;mode<4;mode++)twoDimensional(mode);arrayTexture();cubeTexture();mipmaps();scatteredUpdates();namedAndClearUpdates();rgbPartial();depthPartial(false,1);depthPartial(true,1);depthPartial(false,2);depthPartial(true,2);allocationObservation();glDeleteFramebuffers(fbo);
        }catch(Throwable failure){failures++;failure.printStackTrace();}
        finally{if(window!=0)GLFW.glfwDestroyWindow(window);GLFW.glfwTerminate();}
        System.out.println("AMCL_STORAGE_RESULT checks="+checks+" failures="+failures+" passed="+(failures==0));System.exit(failures==0?0:1);
    }
}
