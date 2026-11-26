package net.java.games.input;

import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Arrays;
import org.lwjgl.Sys;

/** 旧游戏内建 JInput 的默认平台实现。每个连接代次拥有独立对象，不扫描桌面插件。 */
final class DefaultControllerEnvironment extends ControllerEnvironment {
    private static final Charset UTF8 = Charset.forName("UTF-8");
    private final long[] generations = new long[16];
    private final Pad[] slots = new Pad[16];
    private Controller[] devices = new Controller[0];
    private long revision = -1;

    static { Sys.initialize(); }

    private static native long nTopology(long previous, long[] generations);
    private static native byte[] nName(int slot, long generation);
    private static native boolean nState(int slot, long generation, float[] state);

    public boolean isSupported() { return true; }

    public synchronized Controller[] getControllers() {
        long next = nTopology(revision, generations);
        if (next != revision) {
            ArrayList<Pad> added = new ArrayList<Pad>();
            ArrayList<Pad> removed = new ArrayList<Pad>();
            ArrayList<Pad> online = new ArrayList<Pad>();
            revision = next;
            for (int i = 0; i < slots.length; ++i) {
                Pad prior = slots[i];
                long generation = generations[i];
                if (prior != null && generation != prior.generation) {
                    removed.add(prior);
                    slots[i] = null;
                }
                if (generation != 0 && slots[i] == null) {
                    byte[] name = nName(i, generation);
                    if (name != null) {
                        slots[i] = new Pad(i, generation, new String(name, UTF8));
                        added.add(slots[i]);
                    } else {
                        revision = -1; // 查询名字期间已拔出，下次枚举重新取权威拓扑。
                    }
                }
                if (slots[i] != null) online.add(slots[i]);
            }
            devices = online.toArray(new Controller[online.size()]);
            // 先发布完整库存，再允许监听者重入读取，旧对象始终按原连接代次读零。
            for (Pad pad : removed) fireControllerRemoved(pad);
            for (Pad pad : added) fireControllerAdded(pad);
        }
        return devices.clone();
    }

    /** JInput 对绝对轴/按键同时提供轮询值和变更事件；失焦中和来自同一宿主快照。 */
    private static final class Pad extends AbstractController {
        private final int slot;
        private final long generation;
        private final float[] state;
        private final float[] previous;
        private int nextEvent;
        private long timestamp;
        private boolean connected;

        Pad(int slot, long generation, String name) {
            super(name, controls(), new Controller[0], new Rumbler[0]);
            this.slot = slot;
            this.generation = generation;
            state = new float[getComponents().length];
            previous = new float[state.length];
            Component[] components = getComponents();
            for (int i = 0; i < components.length; ++i) ((Control)components[i]).state = state;
        }

        public Controller.Type getType() { return Controller.Type.GAMEPAD; }

        public synchronized boolean poll() {
            // 上游 AbstractController 的临时 Event 为静态实例；不同设备可由不同 mod 线程轮询。
            synchronized (Pad.class) { return super.poll() && connected; }
        }

        protected void pollDevice() {
            System.arraycopy(state, 0, previous, 0, state.length);
            connected = nState(slot, generation, state);
            if (!connected) Arrays.fill(state, 0.0f);
            nextEvent = 0;
            timestamp = System.nanoTime();
        }

        protected boolean getNextDeviceEvent(Event event) {
            while (nextEvent < state.length) {
                int index = nextEvent++;
                if (state[index] != previous[index]) {
                    event.set(getComponents()[index], state[index], timestamp);
                    return true;
                }
            }
            return false;
        }
    }

    /** 每个组件复用上游标准 Identifier，保留 JInput 和 LWJGL 的 instanceof/== 契约。 */
    private static final class Control extends AbstractComponent {
        private final int index;
        private float[] state;
        Control(int index, Component.Identifier id) { super(id.getName(), id); this.index = index; }
        public boolean isRelative() { return false; }
        public boolean isAnalog() { return index < 6; }
        protected float poll() { return state[index]; }
    }

    private static Component[] controls() {
        Component.Identifier[] ids = {
            Component.Identifier.Axis.X, Component.Identifier.Axis.Y,
            Component.Identifier.Axis.RX, Component.Identifier.Axis.RY,
            Component.Identifier.Axis.Z, Component.Identifier.Axis.RZ,
            Component.Identifier.Button._0, Component.Identifier.Button._1,
            Component.Identifier.Button._2, Component.Identifier.Button._3,
            Component.Identifier.Button._4, Component.Identifier.Button._5,
            Component.Identifier.Button._6, Component.Identifier.Button._7,
            Component.Identifier.Button._8, Component.Identifier.Button._9,
            Component.Identifier.Button._10, Component.Identifier.Button._11,
            Component.Identifier.Button._12, Component.Identifier.Button._13,
            Component.Identifier.Button._14, Component.Identifier.Button._15,
            Component.Identifier.Button._16, Component.Identifier.Button._17,
            Component.Identifier.Axis.POV
        };
        Component[] controls = new Component[ids.length];
        for (int i = 0; i < ids.length; ++i) controls[i] = new Control(i, ids[i]);
        return controls;
    }
}
