import { LoaderGeneration } from './LoaderGenerationRegistry';
import { GAME_COMPAT_RUNTIME_JAR } from './GameCompatibilityArtifact';

interface GameCompatibilityRule {
  minecraft: string;
  generation: LoaderGeneration;
}

const GAME_COMPATIBILITY_RULES: GameCompatibilityRule[] = [
  { minecraft: '1.21.11', generation: LoaderGeneration.FabricKnot },
  // 26.2 的 Create Fly 补丁在 JAR 内继续按实际类 SHA-256 门控；未安装该模组时不应用变换。
  { minecraft: '26.2', generation: LoaderGeneration.FabricKnot },
];

export function gameCompatibilityPath(filesDir: string): string {
  return filesDir + '/runtime-compat/' + GAME_COMPAT_RUNTIME_JAR;
}

/** Compatibility delivery is separate from classpath ownership and renderer policy. */
export function applyGameCompatibility(args: string[], minecraft: string,
  generation: LoaderGeneration, filesDir: string): string[] {
  let enabled = false;
  for (const rule of GAME_COMPATIBILITY_RULES) {
    if (rule.minecraft === minecraft && rule.generation === generation) enabled = true;
  }
  if (!enabled) return args;
  const key = '-Dfabric.addMods=';
  const managedPrefix = filesDir + '/runtime-compat/amcl-fabric-compat-';
  const result: string[] = [];
  const mods: string[] = [];
  for (const arg of args) {
    if (!arg.startsWith(key)) {
      result.push(arg);
      continue;
    }
    for (const path of arg.substring(key.length).split(':')) {
      if (path.length > 0 && !path.startsWith(managedPrefix) && mods.indexOf(path) < 0) mods.push(path);
    }
  }
  mods.push(gameCompatibilityPath(filesDir));
  result.push(key + mods.join(':'));
  return result;
}
