/** Legacy OpenGL view. All metadata is owned by GraphicsProfileRegistry. */
import { GRAPHICS_PROFILES, GRAPHICS_DEFAULT_PROFILE_ID, GraphicsGameApi,
  GraphicsProfileSpec, graphicsProfileById } from './GraphicsProfileRegistry';
export { RendererBackendLifecycle, RendererWindowAcquisition, GraphicsProfileSpec as RendererBackendSpec } from './GraphicsProfileRegistry';

export const RENDERER_BACKEND_DEFAULT_ID: string = GRAPHICS_DEFAULT_PROFILE_ID;
export const RENDERER_BACKENDS: GraphicsProfileSpec[] = GRAPHICS_PROFILES.filter(
  (profile: GraphicsProfileSpec): boolean => profile.api === GraphicsGameApi.OPENGL);

export function rendererBackendById(id: string): GraphicsProfileSpec | undefined {
  // 直接从兼容视图查找，避免 barrel 打包时 GraphicsGameApi 枚举被复制后
  // 发生跨模块身份比较失败；这个 API 的契约本来就是“旧 OpenGL registry”。
  for (let i = 0; i < RENDERER_BACKENDS.length; i++) {
    if (RENDERER_BACKENDS[i].id === id) return RENDERER_BACKENDS[i];
  }
  return undefined;
}

export function userSelectableRendererBackends(): GraphicsProfileSpec[] {
  // Compatibility callers keep the historical default list. The new peer
  // selector consumes GraphicsProfileResolver directly.
  return RENDERER_BACKENDS.filter((profile: GraphicsProfileSpec): boolean =>
    profile.userSelectable && profile.selectionRole === 'default');
}
