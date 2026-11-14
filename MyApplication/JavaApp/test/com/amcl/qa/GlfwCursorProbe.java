package com.amcl.qa;

import org.lwjgl.glfw.GLFWImage;
import org.lwjgl.PointerBuffer;
import org.lwjgl.system.MemoryUtil;
import java.nio.ByteBuffer;
import static org.lwjgl.glfw.GLFW.*;

/** 使用随包LWJGL原有Checks验证真实cursor句柄；验证逻辑生命周期，不承诺指针外观。 */
public final class GlfwCursorProbe {
    public static void main(String[] args) {
        if(!glfwInit())throw new AssertionError("GLFW init");
        long window=0;int checks=0;
        try {
            window=glfwCreateWindow(64,64,"AMCL cursor lifecycle",0,0);
            if(window==0)throw new AssertionError("GLFW window");
            for(int round=0;round<100;round++)for(int shape=0x36001;shape<=0x3600A;shape++) {
                long cursor=glfwCreateStandardCursor(shape);
                if(cursor==0)throw new AssertionError("Empty cursor: "+shape);
                glfwSetCursor(window,cursor);glfwDestroyCursor(cursor);checks++;
                if(glfwGetError((PointerBuffer)null)!=0)throw new AssertionError("Cursor API error");
            }
            ByteBuffer pixels=MemoryUtil.memAlloc(16);
            long custom;
            try(GLFWImage image=GLFWImage.malloc()) {
                for(int i=0;i<16;i++)pixels.put(i,(byte)255);
                image.width(2).height(2).pixels(pixels);custom=glfwCreateCursor(image,1,1);
            } finally { MemoryUtil.memFree(pixels); }
            if(custom==0)throw new AssertionError("Empty custom cursor");
            glfwSetCursor(window,custom);glfwSetCursor(window,0);glfwDestroyCursor(custom);checks++;
            // 留一个真实对象给terminate回收；这条路径的泄漏由宿主ASan/生命周期测试另核。
            long leftover=glfwCreateStandardCursor(GLFW_POINTING_HAND_CURSOR);
            if(leftover==0)throw new AssertionError("Empty remaining cursor");
            glfwSetCursor(window,leftover);
            System.out.println("AMCL_GLFW_CURSOR PASS checks="+checks+" platform="+glfwGetPlatform()+" appearanceQualified=false");
        } finally {
            if(window!=0)glfwDestroyWindow(window);
            glfwTerminate();
        }
    }
}
