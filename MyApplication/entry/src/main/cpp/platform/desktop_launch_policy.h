#pragma once
#include <algorithm>
#include <string>
#include <vector>

namespace amcl::desktop {
// LWJGL Configuration captures library properties on its first class init,
// which may occur inside a javaagent, before Minecraft's main entry point.
inline void FreezeDesktopLibraryArguments(std::vector<std::string>& args) {
    const char* owned[] = {"org.lwjgl.opengl.libname=libGLv4.so",
        "org.lwjgl.opengl.contextAPI=native", "org.lwjgl.glfw.libname=libglfw.so",
        "org.lwjgl.sdl.libname=libSDL3.so", "org.lwjgl.freetype.libname=libfreetype.so"};
    for (const char* item : owned) {
        const std::string argument = std::string("-D") + item;
        const std::string key = argument.substr(0,argument.find('=')+1);
        args.erase(std::remove_if(args.begin(),args.end(),[&key](const std::string& value) {
            return value.compare(0,key.size(),key) == 0;
        }),args.end());
        args.push_back(argument);
    }
}
}
