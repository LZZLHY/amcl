package com.amcl.launcher;

import java.io.IOException;
import java.util.*;

/**
 * JarJar metadata 的有界严格 JSON 读取器，仅提取顶层 jars[].path。
 * 不执行脚本、不解析第三方类；拒绝重复键、截断、过深嵌套和尾随正文，避免字符串搜索误认声明。
 */
final class JarJarMetadata {
    private final String text;
    private int at, nodes;
    private JarJarMetadata(String text) { this.text = text; }
    /** Forge声明要求jars存在；路径是ZIP内相对项，不把打包工具的默认目录当成格式要求。 */
    static List<String> paths(String text) throws IOException {
        return paths(text, "path", false);
    }
    /** Fabric的jars可缺席；这里只读file字段，不执行加载器，也不将任意内嵌ZIP当依赖。 */
    static List<String> fabricPaths(String text) throws IOException {
        return paths(text, "file", true);
    }
    /** 两种声明共用严格JSON解析和相对路径边界，调用方另负责深度、字节和重复来源预算。 */
    private static List<String> paths(String text, String member, boolean optional) throws IOException {
        JarJarMetadata parser = new JarJarMetadata(text);
        Object root = parser.value(0); parser.space();
        if (parser.at != text.length() || !(root instanceof Map)) throw new IOException("jarjar_metadata_shape");
        Object jars = ((Map<?, ?>) root).get("jars");
        if (jars == null && optional) return Collections.emptyList();
        if (!(jars instanceof List) || ((List<?>) jars).size() > 128) throw new IOException("jarjar_jars_shape");
        List<String> paths = new ArrayList<String>(); Set<String> unique = new HashSet<String>();
        for (Object item : (List<?>) jars) {
            if (!(item instanceof Map)) throw new IOException("jarjar_item_shape");
            Object path = ((Map<?, ?>) item).get(member);
            if (!(path instanceof String)) throw new IOException("jarjar_path_shape");
            String value = (String) path;
            if (value.startsWith("/") || value.indexOf(':') >= 0 || value.startsWith("./") || value.contains("/./")
                || !value.endsWith(".jar") || value.length() > 512
                || value.indexOf('\\') >= 0 || value.indexOf('\0') >= 0 || value.contains("../") || value.contains("//")
                || !unique.add(value)) throw new IOException("jarjar_path_invalid_or_duplicate");
            paths.add(value);
        }
        return paths;
    }
    private void space() { while (at < text.length() && " \t\r\n".indexOf(text.charAt(at)) >= 0) at++; }
    private IOException bad() { return new IOException("jarjar_json_invalid"); }
    private Object value(int depth) throws IOException {
        if (depth > 16 || ++nodes > 8192) throw bad(); space(); if (at == text.length()) throw bad();
        char token = text.charAt(at);
        if (token == '"') return string();
        if (token == '{') {
            at++; Map<String, Object> map = new LinkedHashMap<String, Object>(); space();
            if (take('}')) return map;
            do {
                space(); if (at == text.length() || text.charAt(at) != '"') throw bad();
                String key = string(); space(); if (!take(':') || map.containsKey(key)) throw bad();
                map.put(key, value(depth + 1)); space(); if (take('}')) return map;
            } while (take(',')); throw bad();
        }
        if (token == '[') {
            at++; List<Object> list = new ArrayList<Object>(); space(); if (take(']')) return list;
            do { list.add(value(depth + 1)); space(); if (take(']')) return list; } while (take(',')); throw bad();
        }
        for (String literal : new String[]{"true", "false", "null"})
            if (text.startsWith(literal, at)) { at += literal.length(); return literal; }
        int begin = at; if (take('-')) { if (at == text.length()) throw bad(); }
        if (take('0')) { } else { if (at == text.length() || text.charAt(at) < '1' || text.charAt(at) > '9') throw bad(); digits(); }
        if (take('.')) { int start = at; digits(); if (start == at) throw bad(); }
        if (take('e') || take('E')) { if (!take('+')) take('-'); int start = at; digits(); if (start == at) throw bad(); }
        return text.substring(begin, at);
    }
    private void digits() { while (at < text.length() && text.charAt(at) >= '0' && text.charAt(at) <= '9') at++; }
    private boolean take(char token) { if (at < text.length() && text.charAt(at) == token) { at++; return true; } return false; }
    private String string() throws IOException {
        if (!take('"')) throw bad(); StringBuilder result = new StringBuilder();
        while (at < text.length()) {
            char token = text.charAt(at++); if (token == '"') return result.toString(); if (token < 32) throw bad();
            if (token == '\\') {
                if (at == text.length()) throw bad(); char escape = text.charAt(at++);
                if (escape == 'u') {
                    if (at > text.length() - 4) throw bad();
                    try { token = (char) Integer.parseInt(text.substring(at, at + 4), 16); } catch (NumberFormatException invalid) { throw bad(); }
                    at += 4;
                } else { int index = "\"\\/bfnrt".indexOf(escape); if (index < 0) throw bad(); token = "\"\\/\b\f\n\r\t".charAt(index); }
            }
            result.append(token); if (result.length() > 65536) throw bad();
        }
        throw bad();
    }
}
