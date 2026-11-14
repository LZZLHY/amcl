package com.amcl.audioagent;

import java.io.IOException;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.Enumeration;

/** 只用于独立负例 JVM：模拟系统域服务枚举的 IO/权限错误，不参与任何生产 JAR。 */
public final class ThrowingSystemLoader extends URLClassLoader {
    public ThrowingSystemLoader(ClassLoader parent) { super(new URL[0], parent); }
    public Enumeration<URL> getResources(String name) throws IOException {
        if (name.equals("META-INF/services/javax.sound.sampled.spi.MixerProvider")) {
            if ("io".equals(System.getProperty("amcl.audio.test.parentFault"))) throw new IOException("explicit parent IO failure");
            if ("security".equals(System.getProperty("amcl.audio.test.parentFault"))) throw new SecurityException("explicit parent security failure");
        }
        return super.getResources(name);
    }
}
