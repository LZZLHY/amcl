package com.amcl.launcher;

/** Safe fallback for standalone javac/tests. The HAP builder generates the product constant. */
public final class AmclBuildProfile {
    public static final boolean DEVELOPER_DIAGNOSTICS = false;
    private AmclBuildProfile() {}
}
