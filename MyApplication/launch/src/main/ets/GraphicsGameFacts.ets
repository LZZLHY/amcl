import { GraphicsGameApi } from './GraphicsProfileRegistry';

export interface GraphicsGameFacts {
  realMcVersion: string;
  lwjglVersion: number;
  needsLwjgl322Slot: boolean;
  usesSdl3: boolean;
  gameApi: GraphicsGameApi;
  providerConflict: boolean;
}

/** Both settings and launch consume the installed, merged manifest library list. */
export function graphicsGameFacts(libraries: string[], version: string): GraphicsGameFacts {
  let lwjgl: number = 3;
  let slot322: boolean = false;
  let sdl: boolean = false;
  let glfw: boolean = false;
  let vulkan: boolean = false;
  let opengl: boolean = false;
  for (const library of libraries) {
    const value: string = library.split('\\').join('/');
    if (value.indexOf('/lwjgl-2.') >= 0 || value.indexOf('org/lwjgl/lwjgl/lwjgl/2.') >= 0
        || value.indexOf('org/lwjgl/lwjgl/2.') >= 0) lwjgl = 2;
    if (new RegExp('org/lwjgl/lwjgl/3\\.[0-2]\\.').test(value)) slot322 = true;
    if (value.indexOf('org/lwjgl/lwjgl-sdl/') >= 0) sdl = true;
    if (value.indexOf('org/lwjgl/lwjgl-glfw/') >= 0) glfw = true;
    if (value.indexOf('org/lwjgl/lwjgl-vulkan/') >= 0) vulkan = true;
    if (value.indexOf('org/lwjgl/lwjgl-opengl/') >= 0) opengl = true;
  }
  return { realMcVersion: version, lwjglVersion: lwjgl, needsLwjgl322Slot: slot322,
    usesSdl3: sdl, gameApi: vulkan ? (opengl ? GraphicsGameApi.DUAL : GraphicsGameApi.VULKAN)
      : (opengl || lwjgl === 2 || slot322 ? GraphicsGameApi.OPENGL : GraphicsGameApi.UNKNOWN),
    providerConflict: sdl && glfw };
}
