import net.java.games.input.*;
import org.lwjgl.input.Controllers;

/** 在实际交付 JAR 上观测标准 JInput 与 LWJGL2 入口，夹具仅控制宿主设备快照。 */
public final class L2GamepadProbe {
    private static native void input(int mode, int slot, float axis);
    private static void check(boolean passed, String description) {
        if (!passed) throw new AssertionError(description);
    }
    public static void main(String[] args) throws Exception {
        ControllerEnvironment env = ControllerEnvironment.getDefaultEnvironment();
        Controllers.create();
        check(Controllers.getControllerCount() == 0, "empty on create");
        input(1, 2, 0);
        Controller pad = env.getControllers()[0];
        check(pad.getName().equals("Wireless Controller") && pad.getType() == Controller.Type.GAMEPAD, "device identity");
        check(Controllers.getControllerCount() == 1, "LWJGL hot plug");
        org.lwjgl.input.Controller wrapped = Controllers.getController(0);
        input(2, 2, .5f);
        Controllers.poll();
        check(wrapped.getXAxisValue() == .5f && wrapped.isButtonPressed(0), "LWJGL analog and buttons");
        check(wrapped.getPovY() < 0 && wrapped.getPovX() > 0, "diagonal dpad");
        check(pad.getComponent(Component.Identifier.Axis.Z).getPollData() == .75f, "continuous trigger");
        boolean down = false;
        while (Controllers.next()) if (Controllers.isEventButton() && Controllers.getEventButtonState()) down = true;
        check(down, "LWJGL press event");
        input(2, 2, 0);
        Controllers.poll();
        check(!wrapped.isButtonPressed(0) && wrapped.getXAxisValue() == 0 && wrapped.getPovX() == 0, "neutral");
        input(0, 2, 0);
        input(1, 2, 0);
        Controller replacement = env.getControllers()[0];
        check(pad != replacement && !pad.poll(), "old generation retired");
        Controllers.poll();
        check(wrapped != Controllers.getController(0), "LWJGL distinct replacement");
        input(3, 2, 0);
        check(env.getControllers().length == 0 && !replacement.poll(), "fork does not read the parent snapshot");
        input(4, 2, 0);
        check(Controllers.getControllerCount() == 1, "child retries after publication");
        input(0, 2, 0);
        check(Controllers.getControllerCount() == 0, "unplug");
        Controllers.destroy();
        Controllers.create();
        check(Controllers.getControllerCount() == 0, "new consumer");
        System.out.println("PASS real LWJGL2 Controllers and JInput APIs");
    }
}
