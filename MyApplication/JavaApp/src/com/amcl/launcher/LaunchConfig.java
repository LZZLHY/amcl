package com.amcl.launcher;

import java.io.File;
import java.net.MalformedURLException;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;

/**
 * MC 启动配置。由 ArkTS 层 LaunchProfileBuilder 构建，序列化为 JSON 传入。
 * 使用纯手写 JSON 解析（无外部依赖，JDK 17 标准库）。
 */
public class LaunchConfig {
    public String mainClass;
    public String[] classpath;
    public String[] mcArgs;
    public String gameDir;
    public String mcDir;
    public String filesDir;
    public String assetsDir;
    public boolean isForge;
    public boolean isFabric;

    /**
     * 从 JSON 字符串解析 LaunchConfig。
     * 返回 null 如果输入无效。
     */
    public static LaunchConfig parse(String json) {
        if (json == null || json.isEmpty()) return null;
        // Basic validation: must start with '{' and contain at least one ':'
        String trimmed = json.trim();
        if (!trimmed.startsWith("{") || !trimmed.contains(":")) return null;
        try {
            LaunchConfig c = new LaunchConfig();
            c.mainClass = extractString(json, "mainClass");
            c.classpath = extractStringArray(json, "classpath");
            c.mcArgs = extractStringArray(json, "mcArgs");
            c.gameDir = extractString(json, "gameDir");
            c.mcDir = extractString(json, "mcDir");
            c.filesDir = extractString(json, "filesDir");
            c.assetsDir = extractString(json, "assetsDir");
            c.isForge = extractBoolean(json, "isForge");
            c.isFabric = extractBoolean(json, "isFabric");
            if (c.classpath == null) c.classpath = new String[0];
            if (c.mcArgs == null) c.mcArgs = new String[0];
            return c;
        } catch (Exception e) {
            System.err.println("[LaunchConfig] Parse failed: " + e.getMessage());
            return null;
        }
    }

    /**
     * 将 classpath 字符串数组转为 URL 数组（用于 URLClassLoader）。
     */
    public URL[] getClasspathUrls() {
        if (classpath == null) return new URL[0];
        List<URL> urls = new ArrayList<>();
        for (String path : classpath) {
            if (path == null || path.isEmpty()) continue;
            try {
                urls.add(new File(path).toURI().toURL());
            } catch (MalformedURLException e) {
                System.err.println("[LaunchConfig] Bad classpath entry: " + path);
            }
        }
        return urls.toArray(new URL[0]);
    }

    // ========== 轻量 JSON 解析（不依赖 Gson/Jackson）==========

    private static String extractString(String json, String key) {
        String pattern = "\"" + key + "\"";
        int ki = json.indexOf(pattern);
        if (ki < 0) return null;
        int colon = json.indexOf(':', ki + pattern.length());
        if (colon < 0) return null;
        // 跳过空白找到引号
        int start = -1;
        for (int i = colon + 1; i < json.length(); i++) {
            char ch = json.charAt(i);
            if (ch == '"') { start = i + 1; break; }
            if (ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r') return null;
        }
        if (start < 0) return null;
        StringBuilder sb = new StringBuilder();
        for (int i = start; i < json.length(); i++) {
            char ch = json.charAt(i);
            if (ch == '\\' && i + 1 < json.length()) {
                char next = json.charAt(i + 1);
                if (next == '"') { sb.append('"'); i++; }
                else if (next == '\\') { sb.append('\\'); i++; }
                else if (next == 'n') { sb.append('\n'); i++; }
                else if (next == 't') { sb.append('\t'); i++; }
                else if (next == 'u' && i + 5 < json.length()) {
                    String hex = json.substring(i + 2, i + 6);
                    sb.append((char) Integer.parseInt(hex, 16));
                    i += 5;
                } else { sb.append(ch); }
            } else if (ch == '"') {
                break;
            } else {
                sb.append(ch);
            }
        }
        return sb.toString();
    }

    private static boolean extractBoolean(String json, String key) {
        String pattern = "\"" + key + "\"";
        int ki = json.indexOf(pattern);
        if (ki < 0) return false;
        int colon = json.indexOf(':', ki + pattern.length());
        if (colon < 0) return false;
        String rest = json.substring(colon + 1).trim();
        return rest.startsWith("true");
    }

    private static String[] extractStringArray(String json, String key) {
        String pattern = "\"" + key + "\"";
        int ki = json.indexOf(pattern);
        if (ki < 0) return new String[0];
        int colon = json.indexOf(':', ki + pattern.length());
        if (colon < 0) return new String[0];
        int bracketStart = json.indexOf('[', colon);
        if (bracketStart < 0) return new String[0];
        int bracketEnd = findMatchingBracket(json, bracketStart);
        if (bracketEnd < 0) return new String[0];
        String arrayContent = json.substring(bracketStart + 1, bracketEnd).trim();
        if (arrayContent.isEmpty()) return new String[0];

        List<String> items = new ArrayList<>();
        int i = 0;
        while (i < arrayContent.length()) {
            // 找下一个引号
            int qStart = arrayContent.indexOf('"', i);
            if (qStart < 0) break;
            // 解析字符串值
            StringBuilder sb = new StringBuilder();
            int j = qStart + 1;
            while (j < arrayContent.length()) {
                char ch = arrayContent.charAt(j);
                if (ch == '\\' && j + 1 < arrayContent.length()) {
                    char next = arrayContent.charAt(j + 1);
                    if (next == '"') { sb.append('"'); j += 2; }
                    else if (next == '\\') { sb.append('\\'); j += 2; }
                    else if (next == 'n') { sb.append('\n'); j += 2; }
                    else if (next == 'u' && j + 5 < arrayContent.length()) {
                        sb.append((char) Integer.parseInt(arrayContent.substring(j + 2, j + 6), 16));
                        j += 6;
                    } else { sb.append(ch); j++; }
                } else if (ch == '"') { j++; break; }
                else { sb.append(ch); j++; }
            }
            items.add(sb.toString());
            i = j;
        }
        return items.toArray(new String[0]);
    }

    private static int findMatchingBracket(String s, int openPos) {
        int depth = 0;
        boolean inString = false;
        for (int i = openPos; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (ch == '\\' && inString) { i++; continue; }
            if (ch == '"') { inString = !inString; continue; }
            if (inString) continue;
            if (ch == '[') depth++;
            else if (ch == ']') { depth--; if (depth == 0) return i; }
        }
        return -1;
    }
}
