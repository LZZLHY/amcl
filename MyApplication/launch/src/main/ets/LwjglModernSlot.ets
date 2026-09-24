/**
 * LWJGL 现代槽位的唯一运行时契约。
 *
 * 3.4.2 原子替换原 3.4.1 现代槽位；目录仍为 lwjgl-ohos，native 仍使用无版本后缀。
 * 3.2.3（_v322）与 LWJGL2 是独立兼容槽位，不得在此清单中混入。
 *
 * SHA-256 对应 prebuilt/lwjgl3/jars 经 AMCL bridge 注入、module-info/module-packages
 * 修补与 StackBackfill 后的最终制品，而不是 Maven 原始包。
 */

export interface LwjglModernJar {
  name: string;
  size: number;
  sha256: string;
}

export const LWJGL_MODERN_VERSION = '3.4.2';
export const LWJGL_MODERN_SOURCE_COMMIT = '32593afe25e2f1394c3425673f1b71a0122f5cd4';
export const LWJGL_MODERN_MANIFEST_SHA256 = '7226e9d757993cb805c00495bd02f1aaa5c2905028bdcfe81d5375ac3575cf68';
export const LWJGL_MODERN_MARKER = 'amcl.lwjgl.modern-slot\nversion=3.4.2\nsource=32593afe25e2f1394c3425673f1b71a0122f5cd4\nmanifest=7226e9d757993cb805c00495bd02f1aaa5c2905028bdcfe81d5375ac3575cf68\n';

export const LWJGL_MODERN_JARS: LwjglModernJar[] = [
  { name: 'lwjgl-egl.jar', size: 156718, sha256: '996784168f35a0384a53a8363fb2bcaf12d6ce997b2f677e275bf6a425b0510d' },
  { name: 'lwjgl-freetype.jar', size: 480076, sha256: '06791a74fd3f60b6f35663c63578e5ece2df73614129dbc3ad4e34e2a1a4201b' },
  { name: 'lwjgl-glfw.jar', size: 160161, sha256: '89ab944d309670b1bce76ad557f807589ff263db7022bb524c8a5d2520e50871' },
  { name: 'lwjgl-openal.jar', size: 155021, sha256: 'a9e6c05ce90f50074b93d9e987df2e6be693504a33adb6b5c7d6786855b5a910' },
  { name: 'lwjgl-opengl.jar', size: 954157, sha256: '027beefe18102b6393236ec632aeb5533c02ce788b4fdcb678018cc22bfdafbf' },
  { name: 'lwjgl-opengles.jar', size: 378087, sha256: '073271174edf1dbacdf62a8151f9960a863d4d1854d59fd6ae7446421c7f291c' },
  { name: 'lwjgl-sdl.jar', size: 1018499, sha256: '54999f33a6d574bf1a059aa7d4cf313f856b705e4a05e5bdc8996e2613ba3702' },
  { name: 'lwjgl-shaderc.jar', size: 158294, sha256: '52064b1de639697499b1395dcb8d3b9bb5844ce13ab424699bc8deb9d7c9580b' },
  { name: 'lwjgl-spng.jar', size: 124033, sha256: 'abbe686b1b59c51b60efe2b4be7d59a10ff69c3d2120151ace9e13ba6d392da0' },
  { name: 'lwjgl-spvc.jar', size: 155682, sha256: '0490ad461d60b77aa7eee46afda3ac4561d0a91a4544f7cff32304cbbfeb1564' },
  { name: 'lwjgl-stb.jar', size: 149340, sha256: '18892f1d6f42453f9fd228c52fcb146d63d78d2439ebed3857157ef43eb0feac' },
  { name: 'lwjgl-tinyfd.jar', size: 17499, sha256: '8a66f8b4b5b6826b17908e7c15ffac0693538f5929767db92227cf3583f1e65f' },
  { name: 'lwjgl-vma.jar', size: 113456, sha256: '33e5c1f7172d6ac8fef95e0fd0caf79e4b28ba23b1a6207bce20de36fcc6af40' },
  { name: 'lwjgl-vulkan.jar', size: 9159414, sha256: 'a2698a9200f4643aea82f5d13417db4987da5f6f68ff4265a4d330d6c90bc8a3' },
  { name: 'lwjgl.jar', size: 1273767, sha256: '8d35ad76334c86b037aa57bc73c8e7f32a4a6b0655e59f9a3b3d32d3d3f7bcf3' },
];
