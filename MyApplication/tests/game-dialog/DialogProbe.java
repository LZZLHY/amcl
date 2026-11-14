package com.amcl.qa;

import org.lwjgl.util.tinyfd.TinyFileDialogs;

/**
 * 真机经真实游戏启动链调用现代槽原始JNI，不模拟Native对话框。只验证明确的人工按钮
 * 序列；任意结果不符立即失败，最后才请求退出0。没有Minecraft世界运行资格含义。
 */
public final class DialogProbe {
    private static void check(boolean value, String message) {
        if (!value) throw new IllegalStateException(message);
    }
    private static void dialog(String type, int expected, int defaultButton, String instruction) {
        System.out.println("AMCL_DIALOG_PROBE waiting=" + type + " expected=" + expected);
        int result = TinyFileDialogs.tinyfd_messageBox("AMCL TinyFD 验收 · " + type,
            instruction + "\n这是完整JNI—鸿蒙UI—真实回包验证。", type, "info", defaultButton);
        check(result == expected, type + " expected=" + expected + " actual=" + result);
        System.out.println("AMCL_DIALOG_PROBE passed=" + type + " actual=" + result);
    }
    public static void main(String[] arguments) {
        check(TinyFileDialogs.tinyfd_messageBox("tinyfd_query", "", "ok", "info", 1) == 1,
            "OHOS UI provider is not actually available");
        check("amcl-ohos".equals(TinyFileDialogs.tinyfd_getGlobalChar("tinyfd_response")), "wrong backend");
        check(TinyFileDialogs.tinyfd_inputBox("tinyfd_query", "", "") == null, "unimplemented input falsely advertised");
        check("no_solution".equals(TinyFileDialogs.tinyfd_getGlobalChar("tinyfd_response")), "unsupported query missing");
        TinyFileDialogs.tinyfd_setGlobalInt("tinyfd_forceConsole", 1);
        check(TinyFileDialogs.tinyfd_messageBox("tinyfd_query", "", "ok", "info", 1) == 0, "console falsely advertised");
        TinyFileDialogs.tinyfd_setGlobalInt("tinyfd_forceConsole", 0);
        check(TinyFileDialogs.tinyfd_notifyPopup("AMCL TinyFD", "通知已进入真实UI队列", "info") == 1, "notification not queued");
        dialog("ok", 1, 1, "请点击“确定”。");
        dialog("okcancel", 0, 1, "请点击“取消”；默认焦点不能替用户回答。");
        dialog("yesno", 0, 1, "请点击“否”。");
        dialog("yesnocancel", 2, 2, "请点击“否”；三按钮的否必须返回2。");
        System.out.println("AMCL_DIALOG_PROBE complete=true cases=4 query=passed unsupported=passed notification=queued");
        System.exit(0);
    }
}
