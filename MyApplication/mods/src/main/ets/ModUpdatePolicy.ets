import { LocalMod, ModSource, RemoteVersion, DependencyType, versionChannelRank, compareModVersionFreshness, pickLatestModVersion } from './ModTypes';
import { ModSourceRouter } from './ModSourceRouter';

async function installedRemote(source: ModSource, project: string, version: string, router: ModSourceRouter): Promise<RemoteVersion> {
  const repo = router.repoFor(source);
  if (repo === null) throw new Error('模组来源不可用');
  return repo.getVersion(source === ModSource.CURSEFORGE ? project + '/' + version : version);
}

/** The update list respects active mods' exact dependency pins; activation also checks JAR constraints. */
export async function pickModUpdate(source: ModSource, project: string, installedId: string,
  versions: RemoteVersion[], installed: LocalMod[], router: ModSourceRouter): Promise<RemoteVersion | null> {
  const current = await installedRemote(source, project, installedId, router);
  let candidates = versions.filter((v: RemoteVersion): boolean => v.id !== current.id && compareModVersionFreshness(v, current) > 0);
  candidates = candidates.filter((v: RemoteVersion): boolean => versionChannelRank(v.versionType) <= versionChannelRank(current.versionType));
  if (candidates.length === 0) return null;
  for (const mod of installed) {
    if (!mod.enabled || mod.remoteSource !== source || mod.remoteProjectId === project
      || (mod.remoteProjectId ?? '').length === 0 || (mod.remoteVersionId ?? '').length === 0) continue;
    const other = await installedRemote(source, mod.remoteProjectId ?? '', mod.remoteVersionId ?? '', router);
    for (const dependency of other.dependencies) {
      if (dependency.projectId !== project) continue;
      const pin = dependency.versionId ?? '';
      if (dependency.dependencyType === DependencyType.REQUIRED && pin.length > 0)
        candidates = candidates.filter((v: RemoteVersion): boolean => v.id === pin);
      if (dependency.dependencyType === DependencyType.INCOMPATIBLE)
        candidates = candidates.filter((v: RemoteVersion): boolean => pin.length > 0 && v.id !== pin);
    }
  }
  return pickLatestModVersion(candidates);
}
