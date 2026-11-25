import { RemoteProject, SearchOptions } from 'mods';

/** 页偏移只决定续页位置；同筛选的后台刷新可以换请求对象而不换搜索意图。 */
export function resourceSearchKey(options: SearchOptions | null): string {
  if (options === null) return '';
  return JSON.stringify([options.kind, options.query, options.gameVersion ?? '', options.loaders ?? [],
    options.categories ?? [], options.sortBy, options.pageSize]);
}

/** 双源项目必须以来源和项目身份一起绑定，不能仅按标题或跨源 ID 认领。 */
export function resourceProjectKey(project: RemoteProject): string {
  return JSON.stringify([project.source, project.id]);
}
