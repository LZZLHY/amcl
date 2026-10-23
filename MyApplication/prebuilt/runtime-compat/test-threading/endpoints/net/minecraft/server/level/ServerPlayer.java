package net.minecraft.server.level;

/** 只提供生产服务器桥实际读取的 level()；无背包、菜单或其他业务逻辑。 */
public final class ServerPlayer {
    private final ServerLevel level;
    public ServerPlayer(ServerLevel level) { this.level = level; }
    public ServerLevel level() { return level; }
}
