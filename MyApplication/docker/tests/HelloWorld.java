public class HelloWorld {
    public static void main(String[] args) {
        System.out.println("=== HelloWorld from HarmonyOS JVM ===");
        System.out.println("java.version: " + System.getProperty("java.version"));
        System.out.println("os.name: " + System.getProperty("os.name"));
        System.out.println("os.arch: " + System.getProperty("os.arch"));
        System.out.println("maxMemory: " + (Runtime.getRuntime().maxMemory() / 1024 / 1024) + " MB");
        if (args.length > 0) {
            System.out.println("args:");
            for (int i = 0; i < args.length; i++) {
                System.out.println("  [" + i + "] " + args[i]);
            }
        }
        System.out.println("=== HelloWorld DONE ===");
    }
}
