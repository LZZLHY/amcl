/** 完整布局目录的UI分页；只切名字摘要，不读取方案payload，所有目录项仍可逐页或跳到当前方案访问。 */
export const LAYOUT_CATALOG_PAGE_SIZE: number = 32
export function layoutCatalogPageCount(names: string[]): number {
  return Math.max(1,Math.ceil(names.length/LAYOUT_CATALOG_PAGE_SIZE))
}
/** 删除末页、非法页号或库替换后夹回当前有效页，不修改完整目录本身。 */
export function clampLayoutCatalogPage(names: string[],page: number): number {
  const value: number=Number.isFinite(page) ? Math.trunc(page) : 0
  return Math.max(0,Math.min(layoutCatalogPageCount(names)-1,value))
}
export function layoutCatalogPage(names: string[],page: number): string[] {
  const start: number=clampLayoutCatalogPage(names,page)*LAYOUT_CATALOG_PAGE_SIZE
  return names.slice(start,start+LAYOUT_CATALOG_PAGE_SIZE)
}
export function layoutCatalogContainingPage(names: string[],name: string): number {
  const index: number=names.indexOf(name)
  return index<0 ? 0 : Math.floor(index/LAYOUT_CATALOG_PAGE_SIZE)
}
