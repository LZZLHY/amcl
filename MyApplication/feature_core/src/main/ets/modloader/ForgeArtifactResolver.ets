/**
 * Forge 发布身份解析。整合包写的是加载器 build，Maven 工件还可能带发布分支；
 * 本模块只解释输入与发布列表，不访问网络、不猜后缀、不选择另一个 build。
 * 服务层负责刷新发布列表和下载，纯函数可由宿主及 ArkTS 测试共同验证。
 */

/** 同一次安装贯穿下载、运行库路径和生成版本 JSON 的完整发布身份。 */
export interface ForgeArtifactIdentity {
  artifactVersion: string; // Maven 的完整版本，包含 Minecraft 前缀与实际分支。
  loaderVersion: string;   // 去掉 Minecraft 前缀的完整 tail；用于 Forge 安装分流。
  versionId: string;       // 生成的基础加载器目录身份，不改变父整合包的实例名称。
  metadataMatched: boolean; // 发布列表是否明确包含此工件；false 不能被日志写成已确认发布。
}

/** 只允许安全版本单段，防止输入或远端列表进入 URL/目录时产生路径语义。 */
function safeVersion(value: string): boolean {
  return value.length > 0 && value.length <= 160 && /^[0-9][0-9A-Za-z._+\-]*$/.test(value);
}

/**
 * 归一化调用方输入。支持 loader tail 与带当前 Minecraft 前缀的 artifactVersion。
 * 不接受另一 Minecraft 的完整坐标：其前缀以 1.x（历史 MC）或两段数字纪元表示，
 * 并可携带 pre/rc/snapshot 标签，后面又有 Forge 的三/四段 build；
 * 这与加载器尾部的 MC 分支（如 -1.7.10）不同。
 */
function loaderTail(gameVersion: string, requested: string): string {
  if (!safeVersion(gameVersion) || !safeVersion(requested)) {
    throw new Error('Forge 发布版本包含不安全或空的版本标识');
  }
  let prefix = gameVersion + '-';
  let tail = requested.indexOf(prefix) === 0 ? requested.substring(prefix.length) : requested;
  let otherGame = /^(1\.[0-9]+(?:\.[0-9]+)?(?:_[0-9A-Za-z.]+)?|[0-9]+\.[0-9]+)(?:-(?:pre|rc|snapshot)[0-9A-Za-z._\-]*)?-[0-9]+(?:\.[0-9]+){2,3}(?:-[0-9A-Za-z._+\-]+)?$/.exec(tail);
  if (otherGame !== null || !/^[0-9]+(?:\.[0-9]+){2,3}(?:-[0-9A-Za-z._+\-]+)?$/.test(tail)) {
    throw new Error('Forge 版本格式无效或与 Minecraft ' + gameVersion + ' 不匹配：' + requested);
  }
  return tail;
}

/** 显式分支已经固定作者意图；服务无需为它增加一次发布列表请求。 */
export function hasExplicitForgeBranch(gameVersion: string, requestedLoaderVersion: string): boolean {
  return loaderTail(gameVersion, requestedLoaderVersion).indexOf('-') >= 0;
}

/**
 * 把短 build 解析成完整发布坐标。精确条目优先，只有同 MC、同 build 的唯一分支可补全；
 * 多分支无精确条目时拒绝歧义，不按列表顺序或“最新”替用户选择。
 * metadata 可能落后/离线：没有正向证据时只保留调用方指定的精确坐标，交现有下载、
 * checksum 和安装器校验裁决；不会追加猜测分支，也不会凭缺项判定工件不存在。
 */
export function resolveForgeArtifact(gameVersion: string, requestedLoaderVersion: string,
  publishedVersions: string[]): ForgeArtifactIdentity {
  let tail = loaderTail(gameVersion, requestedLoaderVersion);
  let requestedArtifact = gameVersion + '-' + tail;
  let candidates: string[] = [];
  let exact = false;
  for (let published of publishedVersions) {
    if (!safeVersion(published)) continue;
    if (published === requestedArtifact) exact = true;
    // '-' 是 build/branch 边界，不能把 1614 匹配到 16140 或把 1.7.1 匹配到 1.7.10。
    if (published.indexOf(requestedArtifact + '-') === 0 && candidates.indexOf(published) < 0) {
      try {
        if (hasExplicitForgeBranch(gameVersion, published)) candidates.push(published);
      } catch (e) { /* 非法发布项不参与候选，不破坏其余合法元数据。 */ }
    }
  }
  let artifact = requestedArtifact;
  let matched = exact;
  if (!exact && tail.indexOf('-') < 0) {
    if (candidates.length > 1) {
      throw new Error('Forge ' + requestedArtifact + ' 存在多个发布分支，请选择完整版本：' + candidates.join(', '));
    }
    if (candidates.length === 1) { artifact = candidates[0]; matched = true; }
  }
  let resolvedTail = artifact.substring(gameVersion.length + 1);
  return { artifactVersion: artifact, loaderVersion: resolvedTail,
    versionId: gameVersion + '-forge-' + resolvedTail, metadataMatched: matched };
}
