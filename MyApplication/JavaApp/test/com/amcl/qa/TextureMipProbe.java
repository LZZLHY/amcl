package com.amcl.qa;

import java.nio.*;
import org.lwjgl.BufferUtils;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import static org.lwjgl.opengl.GL42C.*;

/** 同一次同步处理两个mip，以及同一upload batch中两个1x1转换块；读取所有外围像素。 */
public final class TextureMipProbe {
    private static int checks,failures,fbo;
    private TextureMipProbe() { }
    private static void upload(int kind,int level,int size,boolean patch){
        int count=size*size;int offset=patch?1:0;
        if(kind==2){FloatBuffer p=BufferUtils.createFloatBuffer(count);for(int i=0;i<count;i++)p.put(patch?.25f:.75f);p.flip();glTexSubImage2D(GL_TEXTURE_2D,level,offset,offset,size,size,GL_DEPTH_COMPONENT,GL_FLOAT,p);}
        else if(kind==3){IntBuffer p=BufferUtils.createIntBuffer(count);for(int i=0;i<count;i++)p.put(patch?0x40000007:0xBFFFFF03);p.flip();glTexSubImage2D(GL_TEXTURE_2D,level,offset,offset,size,size,GL_DEPTH_STENCIL,GL_UNSIGNED_INT_24_8,p);}
        else{int bytes=kind==1?3:4;ByteBuffer p=BufferUtils.createByteBuffer(count*bytes);for(int i=0;i<count;i++){p.put((byte)(patch?0:255)).put((byte)(patch?255:0)).put((byte)0);if(bytes==4)p.put((byte)255);}p.flip();glTexSubImage2D(GL_TEXTURE_2D,level,offset,offset,size,size,kind==1?GL_RGB:GL_RGBA,GL_UNSIGNED_BYTE,p);}
    }
    private static void attach(int kind,int texture,int level){
        glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,0,0);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_DEPTH_STENCIL_ATTACHMENT,GL_TEXTURE_2D,0,0);
        glFramebufferTexture2D(GL_FRAMEBUFFER,kind<2?GL_COLOR_ATTACHMENT0:kind==2?GL_DEPTH_ATTACHMENT:GL_DEPTH_STENCIL_ATTACHMENT,GL_TEXTURE_2D,texture,level);
        glDrawBuffer(kind<2?GL_COLOR_ATTACHMENT0:GL_NONE);glReadBuffer(kind<2?GL_COLOR_ATTACHMENT0:GL_NONE);
        if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("mip FBO incomplete");
    }
    /** 每mip的最终像素都从真实GPU读取，DS两aspect分别核；不是getter或CPU影像自比。 */
    private static void verify(int kind,int level,boolean patched){
        int size=4>>level,count=size*size,bad=0;
        ByteBuffer colors=BufferUtils.createByteBuffer(count*4),stencil=BufferUtils.createByteBuffer(count);FloatBuffer depth=BufferUtils.createFloatBuffer(count);
        if(kind<2)glReadPixels(0,0,size,size,GL_RGBA,GL_UNSIGNED_BYTE,colors);else glReadPixels(0,0,size,size,GL_DEPTH_COMPONENT,GL_FLOAT,depth);
        if(kind==3)glReadPixels(0,0,size,size,GL_STENCIL_INDEX,GL_UNSIGNED_BYTE,stencil);
        for(int y=0;y<size;y++)for(int x=0;x<size;x++){
            int i=y*size+x;boolean green=patched&&x==1&&y==1,ok;
            if(kind<2)ok=(colors.get(i*4)&255)==(green?0:255)&&(colors.get(i*4+1)&255)==(green?255:0)&&(colors.get(i*4+2)&255)==0&&(colors.get(i*4+3)&255)==255;
            else ok=Math.abs(depth.get(i)-(green?.25f:.75f))<.0001f;
            checks++;if(!ok){bad++;failures++;}
            if(kind==3){checks++;if((stencil.get(i)&255)!=(green?7:3)){bad++;failures++;}}
        }
        int error=glGetError();checks++;if(error!=GL_NO_ERROR)failures++;
        System.out.println("AMCL_MIP_PIXELS kind="+kind+" level="+level+" patched="+patched+" failures="+bad+" glError="+error);
    }
    public static void main(String[] args){
        long window=0;
        try{
            if(!GLFW.glfwInit())throw new AssertionError("glfwInit");GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR,3);GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR,3);GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE,GLFW.GLFW_OPENGL_CORE_PROFILE);
            window=GLFW.glfwCreateWindow(64,64,"AMCL mip upload QA",0,0);if(window==0)throw new AssertionError("GLFW context");GLFW.glfwMakeContextCurrent(window);GL.createCapabilities();
            System.out.println("AMCL_MIP_IDENTITY "+glGetString(GL_VERSION));fbo=glGenFramebuffers();glPixelStorei(GL_UNPACK_ALIGNMENT,1);glPixelStorei(GL_PACK_ALIGNMENT,1);glDisable(GL_SCISSOR_TEST);glColorMask(true,true,true,true);glDepthMask(true);glStencilMask(255);
            for(int kind=0;kind<4;kind++){
                int texture=glGenTextures();glBindTexture(GL_TEXTURE_2D,texture);glTexStorage2D(GL_TEXTURE_2D,2,new int[]{GL_RGBA8,GL_RGB8,GL_DEPTH_COMPONENT32F,GL_DEPTH24_STENCIL8}[kind],4,4);
                // 无GPU backing时先写两个mip，再首次GPU读回，覆盖UploadItem扩容和格式plane打包。
                upload(kind,0,4,false);upload(kind,1,2,false);
                for(int level=0;level<2;level++){attach(kind,texture,level);verify(kind,level,false);}
                for(int level=0;level<2;level++){attach(kind,texture,level);glClearColor(1,0,0,1);glClearDepth(.75);glClearStencil(3);glClear(kind<2?GL_COLOR_BUFFER_BIT:GL_DEPTH_BUFFER_BIT|(kind==3?GL_STENCIL_BUFFER_BIT:0));}
                // 两个1x1 patch之间不插入read/finish；DS每块仅5字节，下一块必须正确对齐。
                upload(kind,0,1,true);upload(kind,1,1,true);
                for(int level=0;level<2;level++){attach(kind,texture,level);verify(kind,level,true);}
                glDeleteTextures(texture);
            }
            glDeleteFramebuffers(fbo);
        }catch(Throwable error){failures++;error.printStackTrace();}
        finally{if(window!=0)GLFW.glfwDestroyWindow(window);GLFW.glfwTerminate();}
        System.out.println("AMCL_MIP_RESULT checks="+checks+" failures="+failures+" passed="+(failures==0));System.exit(failures==0?0:1);
    }
}
