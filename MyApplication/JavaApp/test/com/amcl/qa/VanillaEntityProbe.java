package com.amcl.qa;
import java.io.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import org.lwjgl.BufferUtils;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import static org.lwjgl.opengl.GL33C.*;

/** 使用已校验1.21.1 client内的原entity_solid shader和NEW_ENTITY36字节格式，批量绘制后统一读回。 */
public final class VanillaEntityProbe {
    private static final String[] NAMES={"Position","Color","UV0","UV1","UV2","Normal"};
    private static final int[][] RGBA={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255}};
    private static int failures,checks;
    /** 与游戏一样展开moj_import并保留顶层version；只读取原client资源，不在本仓分发其shader。 */
    static String source(String path,boolean top,int depth)throws Exception{
        if(depth>8)throw new IOException("include depth");InputStream in=VanillaEntityProbe.class.getResourceAsStream("/assets/minecraft/shaders/"+path);if(in==null)throw new IOException("missing "+path);
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();try{byte[] block=new byte[4096];int n;while((n=in.read(block))>=0){if(bytes.size()+n>65536)throw new IOException("shader size");bytes.write(block,0,n);}}finally{in.close();}
        StringBuilder sha=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()))sha.append(String.format(Locale.ROOT,"%02x",b&255));System.out.println("AMCL_ENTITY_SOURCE path="+path+" sha256="+sha);
        StringBuilder result=new StringBuilder();for(String line:new String(bytes.toByteArray(),StandardCharsets.UTF_8).split("\\r?\\n")){
            String trimmed=line.trim();if(trimmed.startsWith("#moj_import <")&&trimmed.endsWith(">")){String name=trimmed.substring(13,trimmed.length()-1);if(!name.matches("[a-zA-Z0-9_.-]+"))throw new IOException("include name");result.append(source("include/"+name,false,depth+1));}
            else if(top||!trimmed.startsWith("#version"))result.append(line).append('\n');
        }return result.toString();
    }
    private static int shader(int type,String source){int s=glCreateShader(type);glShaderSource(s,source);glCompileShader(s);if(glGetShaderi(s,GL_COMPILE_STATUS)==0)throw new AssertionError(glGetShaderInfoLog(s));return s;}
    /** 故意用另一组API位置检验真实按name绑定，不能依赖声明顺序或显式layout规避问题。 */
    static int program(String vertex,String fragment,boolean reverse){int vs=shader(GL_VERTEX_SHADER,vertex),fs=shader(GL_FRAGMENT_SHADER,fragment),p=glCreateProgram();glAttachShader(p,vs);glAttachShader(p,fs);for(int i=0;i<6;i++)glBindAttribLocation(p,reverse?5-i:i,NAMES[i]);glLinkProgram(p);if(glGetProgrami(p,GL_LINK_STATUS)==0)throw new AssertionError(glGetProgramInfoLog(p));glDeleteShader(vs);glDeleteShader(fs);
        for(int i=0;i<glGetProgrami(p,GL_ACTIVE_ATTRIBUTES);i++){IntBuffer size=BufferUtils.createIntBuffer(1),type=BufferUtils.createIntBuffer(1);String name=glGetActiveAttrib(p,i,128,size,type);System.out.println("AMCL_ENTITY_ATTRIBUTE program="+p+" name="+name+" location="+glGetAttribLocation(p,name)+" type="+type.get(0));}
        for(int i=0;i<6;i++)if(glGetAttribLocation(p,NAMES[i])!=(reverse?5-i:i))throw new AssertionError("attribute binding "+NAMES[i]);return p;}
    // atlas仍有完整mip链，避免被改写为单级explicit0；2×2内容在8×8 tile及本次倾角下
    // 保持放大采样。旧8×8 atlas在远端真实缩小，应选绿色mip1，不能要求该处仍为白色mip0。
    private static int texture(int[] solid){int t=glGenTextures();glBindTexture(GL_TEXTURE_2D,t);int base=solid==null?2:16;for(int level=0;level<=(solid==null?1:0);level++){int size=base>>level;ByteBuffer b=BufferUtils.createByteBuffer(size*size*4);for(int y=0;y<size;y++)for(int x=0;x<size;x++)for(int c:solid!=null?solid:level>0?RGBA[level]:RGBA[(y>=size/2?2:0)+(x>=size/2?1:0)])b.put((byte)c);b.flip();glTexImage2D(GL_TEXTURE_2D,level,GL_RGBA8,size,size,0,GL_RGBA,GL_UNSIGNED_BYTE,b);}glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,solid==null?GL_NEAREST_MIPMAP_NEAREST:GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,solid==null?1:0);return t;}
    /** 四个真实顶点+ushort EBO；倾斜平面w从2到6，UV1/UV2是实际参与texelFetch的SHORT integer。 */
    static int vao(boolean reverse,boolean tilted,int vbo,int ebo){int vao=glGenVertexArrays();glBindVertexArray(vao);glBindBuffer(GL_ARRAY_BUFFER,vbo);ByteBuffer data=BufferUtils.createByteBuffer(4*36).order(ByteOrder.nativeOrder());float[][] corners={{-1,-1,0,0},{1,-1,1,0},{1,1,1,1},{-1,1,0,1}};
        for(float[] c:corners){float z=tilted&&c[0]>0?6:2;data.putFloat(c[0]*z).putFloat(c[1]*z).putFloat(-z).putInt(-1).putFloat(c[2]).putFloat(c[3]).putShort((short)3).putShort((short)7).putShort((short)240).putShort((short)240).put((byte)0).put((byte)0).put((byte)127).put((byte)0);}data.flip();glBufferData(GL_ARRAY_BUFFER,data,GL_STATIC_DRAW);
        int[] counts={3,4,2,2,2,3},types={GL_FLOAT,GL_UNSIGNED_BYTE,GL_FLOAT,GL_SHORT,GL_SHORT,GL_BYTE},offsets={0,12,16,24,28,32};for(int i=0;i<6;i++){int at=reverse?5-i:i;if(i==3||i==4)glVertexAttribIPointer(at,counts[i],types[i],36,offsets[i]);else glVertexAttribPointer(at,counts[i],types[i],i==1||i==5,36,offsets[i]);glEnableVertexAttribArray(at);}glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,ebo);ShortBuffer indices=BufferUtils.createShortBuffer(6);indices.put(new short[]{0,1,2,0,2,3}).flip();glBufferData(GL_ELEMENT_ARRAY_BUFFER,indices,GL_STATIC_DRAW);return vao;}
    static void uniforms(int p,float tint){glUseProgram(p);float[] model={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1},projection={1,0,0,0,0,1,0,0,0,0,-100.1f/99.9f,-1,0,0,-20f/99.9f,0};glUniformMatrix4fv(glGetUniformLocation(p,"ModelViewMat"),false,model);glUniformMatrix4fv(glGetUniformLocation(p,"ProjMat"),false,projection);glUniform4f(glGetUniformLocation(p,"ColorModulator"),tint,tint,tint,1);glUniform1f(glGetUniformLocation(p,"FogStart"),20);glUniform1f(glGetUniformLocation(p,"FogEnd"),40);glUniform4f(glGetUniformLocation(p,"FogColor"),.2f,.4f,.6f,1);glUniform1i(glGetUniformLocation(p,"FogShape"),0);glUniform3f(glGetUniformLocation(p,"Light0_Direction"),0,0,1);glUniform3f(glGetUniformLocation(p,"Light1_Direction"),0,0,1);for(int i=0;i<3;i++)glUniform1i(glGetUniformLocation(p,"Sampler"+i),i);}
    public static void main(String[] args){long window=0;try{
        if(!GLFW.glfwInit())throw new AssertionError("glfwInit");GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR,3);GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR,3);GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE,GLFW.GLFW_OPENGL_CORE_PROFILE);window=GLFW.glfwCreateWindow(64,64,"AMCL original entity shader",0,0);if(window==0)throw new AssertionError("context");GLFW.glfwMakeContextCurrent(window);GL.createCapabilities();System.out.println("AMCL_ENTITY_IDENTITY "+glGetString(GL_VERSION)+" "+glGetString(GL_RENDERER));
        String vertex=source("core/rendertype_entity_solid.vsh",true,0),fragment=source("core/rendertype_entity_solid.fsh",true,0);int[] programs={program(vertex,fragment,false),program(vertex,fragment,true)};
        int fbo=glGenFramebuffers(),color=glGenTextures();glBindTexture(GL_TEXTURE_2D,color);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,64,64,0,GL_RGBA,GL_UNSIGNED_BYTE,(ByteBuffer)null);glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,color,0);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("FBO");glDisable(GL_DEPTH_TEST);glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glDisable(GL_SCISSOR_TEST);
        int[] textures={texture(null),texture(new int[]{255,255,255,255}),texture(new int[]{255,255,255,255})};for(int i=0;i<3;i++){glActiveTexture(GL_TEXTURE0+i);glBindTexture(GL_TEXTURE_2D,textures[i]);}
        int[] vaos=new int[4],buffers=new int[4],indices=new int[4];for(int i=0;i<4;i++){buffers[i]=glGenBuffers();indices[i]=glGenBuffers();vaos[i]=vao(i%2!=0,i>=2,buffers[i],indices[i]);}
        for(int round=0;round<3;round++){
            glBindFramebuffer(GL_FRAMEBUFFER,fbo);for(int tile=0;tile<32;tile++){int kind=(tile+round)%4;glViewport(tile%8*8,tile/8*8,8,8);glBindVertexArray(vaos[kind]);uniforms(programs[kind%2],tile%2==0?1:.5f);glDrawElements(GL_TRIANGLES,6,GL_UNSIGNED_SHORT,0L);}
            // 先完成整批，不用每draw读回清理backend的descriptor/transient/cache。
            ByteBuffer pixels=BufferUtils.createByteBuffer(64*64*4);glReadPixels(0,0,64,64,GL_RGBA,GL_UNSIGNED_BYTE,pixels);int error=glGetError();
            for(int tile=0;tile<32;tile++)for(int y:new int[]{2,6})for(int x:new int[]{2,6}){int index=((tile/8*8+y)*64+tile%8*8+x)*4;int[] expected=RGBA[(y>=4?2:0)+(x>=4?1:0)],actual=new int[4];boolean ok=error==0;for(int c=0;c<4;c++){actual[c]=pixels.get(index+c)&255;int wanted=c==3?255:Math.round(expected[c]*(tile%2==0?1:.5f));ok&=Math.abs(actual[c]-wanted)<=1;}checks++;if(!ok)failures++;if(!ok)System.out.println("AMCL_ENTITY_PIXEL round="+round+" tile="+tile+" x="+x+" y="+y+" error="+error+" actual="+Arrays.toString(actual));}
        }
        glFinish();System.out.println("AMCL_ENTITY_RESULT checks="+checks+" failures="+failures+" passed="+(failures==0));
        for(int p:programs)glDeleteProgram(p);for(int v:vaos)glDeleteVertexArrays(v);for(int b:buffers)glDeleteBuffers(b);for(int e:indices)glDeleteBuffers(e);for(int t:textures)glDeleteTextures(t);glDeleteTextures(color);glDeleteFramebuffers(fbo);
    }catch(Throwable error){failures++;error.printStackTrace();}finally{if(window!=0)GLFW.glfwDestroyWindow(window);GLFW.glfwTerminate();}System.exit(failures==0?0:1);}
}
