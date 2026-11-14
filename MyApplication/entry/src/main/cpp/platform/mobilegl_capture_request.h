#pragma once
#include <string>
#include <vector>

namespace amcl::graphics {
struct MobileglCaptureRequest {
    bool enabled = false;
    std::string path;
    std::string match;
};

/**
 * 将启动参数中的显式开发请求转换为有界CPU诊断配置。
 * developerEnabled来自编译产品能力，不能由JVM参数打开。tag只作私有tmp目录
 * 内的新文件名，绝不接收任意输出路径；PID避免不同游戏活动互相覆盖。
 * 两个marker必须各出现一次且满足ASCII/长度边界；任一无效时整个请求关闭，
 * 不接受部分配置。此函数只解析，不创建目录或文件，不修改JVM参数。
 */
inline MobileglCaptureRequest ParseMobileglCaptureRequest(const std::vector<std::string>& arguments,
                                                         const std::string& filesDir, int pid,
                                                         bool developerEnabled) {
    MobileglCaptureRequest request;
    if (!developerEnabled || pid <= 0 || filesDir.empty() || filesDir[0] != '/') return request;
    constexpr char tagPrefix[] = "-Damcl.mobilegl.capture=";
    constexpr char matchPrefix[] = "-Damcl.mobilegl.captureMatch=";
    std::string tag, match;
    bool sawTag = false, sawMatch = false;
    for (const auto& argument : arguments) {
        if (argument.compare(0, sizeof(tagPrefix)-1, tagPrefix) == 0) {
            if (sawTag) return request;
            sawTag = true; tag = argument.substr(sizeof(tagPrefix)-1);
        }
        if (argument.compare(0, sizeof(matchPrefix)-1, matchPrefix) == 0) {
            if (sawMatch) return request;
            sawMatch = true; match = argument.substr(sizeof(matchPrefix)-1);
        }
    }
    if (tag.empty() || tag.size()>32 || match.empty() || match.size()>512) return request;
    for (unsigned char c : tag) if (!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_')) return request;
    // 名称过滤器最多8项，不接收空项、空白或路径分隔符；允许数组/结构uniform。
    unsigned names = 1; bool hasCharacter = false;
    for (unsigned char c : match) {
        if (c==',') { if (!hasCharacter || ++names>8) return request; hasCharacter=false; continue; }
        if (!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='.'||c=='['||c==']')) return request;
        hasCharacter=true;
    }
    if (!hasCharacter) return request;
    request.enabled=true;
    request.path=filesDir+"/tmp/mgl-capture-"+tag+"-"+std::to_string(pid)+".jsonl";
    request.match=match;
    return request;
}
}
