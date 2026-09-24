/** Device facts used by graphics admission. Product identity is deliberately absent. */
import { CapabilityEvidence } from './GraphicsCapabilityContract';
import { GraphicsPlatformFamily } from './GraphicsProfileRegistry';

export enum GraphicsDeviceType {
  PHONE = 'phone',
  TABLET = 'tablet',
  TWO_IN_ONE = '2in1',
  UNKNOWN = 'unknown',
}

export interface DeviceGraphicsFacts {
  deviceType: GraphicsDeviceType;
  runtimeApi: number;
  platformFamily: GraphicsPlatformFamily;
  nativeWindow: CapabilityEvidence;
  systemGlEntry: CapabilityEvidence;
  systemEgl: CapabilityEvidence;
  glesContext: CapabilityEvidence;
  vulkanLoader: CapabilityEvidence;
  vulkanPhysicalDevice: CapabilityEvidence;
  vulkanFeatures: CapabilityEvidence;
  surfacePresent: CapabilityEvidence;
  surfaceGeneration: number;
}

export function graphicsDeviceType(value: string): GraphicsDeviceType {
  if (value === GraphicsDeviceType.PHONE) return GraphicsDeviceType.PHONE;
  if (value === GraphicsDeviceType.TABLET) return GraphicsDeviceType.TABLET;
  if (value === GraphicsDeviceType.TWO_IN_ONE) return GraphicsDeviceType.TWO_IN_ONE;
  return GraphicsDeviceType.UNKNOWN;
}

export function graphicsPlatformForDeviceType(type: GraphicsDeviceType): GraphicsPlatformFamily {
  if (type === GraphicsDeviceType.TWO_IN_ONE) return GraphicsPlatformFamily.DESKTOP;
  if (type === GraphicsDeviceType.PHONE || type === GraphicsDeviceType.TABLET) {
    return GraphicsPlatformFamily.MOBILE;
  }
  return GraphicsPlatformFamily.UNKNOWN;
}

export function createDeviceGraphicsFacts(deviceTypeValue: string, runtimeApiValue: number): DeviceGraphicsFacts {
  const type: GraphicsDeviceType = graphicsDeviceType(deviceTypeValue);
  const api: number = Number.isFinite(runtimeApiValue) && runtimeApiValue > 0
    ? Math.trunc(runtimeApiValue) : 0;
  return {
    deviceType: type,
    runtimeApi: api,
    platformFamily: graphicsPlatformForDeviceType(type),
    nativeWindow: CapabilityEvidence.NOT_RUN,
    systemGlEntry: CapabilityEvidence.NOT_RUN,
    systemEgl: CapabilityEvidence.NOT_RUN,
    glesContext: CapabilityEvidence.NOT_RUN,
    vulkanLoader: CapabilityEvidence.NOT_RUN,
    vulkanPhysicalDevice: CapabilityEvidence.NOT_RUN,
    vulkanFeatures: CapabilityEvidence.NOT_RUN,
    surfacePresent: CapabilityEvidence.NOT_RUN,
    surfaceGeneration: 0,
  };
}
