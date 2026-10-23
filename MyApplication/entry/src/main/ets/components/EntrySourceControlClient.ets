import testNapi from 'libentry.so'
import { SourceControlClient, SourceControlPort, InputDeviceConnectionReader, ControlGroupWitness } from 'gamecontrol'

/** entry 只负责把平台 NAPI 注入纯客户端；控件身份、失败重试和缓存由客户端统一处理。 */
export function createEntrySourceControlClient(source: number,
  publicationToken: () => string = (): string => '',
  connectionReader: InputDeviceConnectionReader | undefined = undefined,
  groupWitness: ((control: string) => ControlGroupWitness | undefined) | undefined = undefined): SourceControlClient {
  // 平台token提供者绑定本控件面，不能从进程全局最新页面取身份；纯客户端仍只冻结输出租约。
  const sourceControlPort: SourceControlPort = {
    acquire: (inputSource: number, deviceId: number, controlId: string, codes: number[], originalControl?: string): string => {
      const witness: ControlGroupWitness | undefined = groupWitness?.(originalControl ?? '')
      if (witness !== undefined) return testNapi.acquireSourceControl(inputSource, deviceId, controlId, codes,
        publicationToken(), witness.memberId, witness.eligibility)
      return testNapi.acquireSourceControl(inputSource, deviceId, controlId, codes, publicationToken())
    },
    release: (token: string): boolean => { return testNapi.releaseSourceControl(token) }
  }
  // 硬件来源借Monitor的同一只读原对象资格；触控前端沿原publication，不能以device数字补造连接。
  return new SourceControlClient(source, sourceControlPort, connectionReader)
}
