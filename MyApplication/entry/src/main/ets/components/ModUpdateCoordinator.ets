/** Updates and repairs share the same validated installation transaction as new installs. */
import { ModInstallTask, ModInstallRequest, ModSourceRouter, RemoteVersion } from 'mods';
import { getDownloadTaskRegistry } from 'feature_core';

interface ModUpdateState { pct: number; latestVersionNumber: string; }
export interface ModUpdateParams {
  oldPath: string;
  wasEnabled: boolean;
  mcDir: string;
  versionId: string;
  versionIsolation: boolean;
  displayName: string;
  latest: RemoteVersion;
  router: ModSourceRouter;
}
type CoordListener = () => void;

export class ModUpdateCoordinator {
  private static inst_: ModUpdateCoordinator | null = null;
  private jobs_: Map<string, ModUpdateState> = new Map();
  private promises_: Map<string, Promise<void>> = new Map();
  private listeners_: CoordListener[] = [];
  static instance(): ModUpdateCoordinator {
    if (ModUpdateCoordinator.inst_ === null) ModUpdateCoordinator.inst_ = new ModUpdateCoordinator();
    return ModUpdateCoordinator.inst_;
  }
  addListener(l: CoordListener): void { if (this.listeners_.indexOf(l) < 0) this.listeners_.push(l); }
  removeListener(l: CoordListener): void { this.listeners_ = this.listeners_.filter((item: CoordListener): boolean => item !== l); }
  private notify(): void { for (const l of this.listeners_) { try { l(); } catch (e) { /* Observer only. */ } } }
  isUpdating(path: string): boolean { return this.jobs_.has(path); }
  pctOf(path: string): number { return this.jobs_.get(path)?.pct ?? 0; }
  latestOf(path: string): string { return this.jobs_.get(path)?.latestVersionNumber ?? ''; }

  start(p: ModUpdateParams): Promise<void> {
    const existing = this.promises_.get(p.oldPath);
    if (existing !== undefined) return existing;
    const path = p.oldPath;
    const request: ModInstallRequest = { mcDir: p.mcDir, versionId: p.versionId, versionIsolation: p.versionIsolation,
      root: p.latest, title: p.displayName, router: p.router, optionalIds: [], oldPath: path, wasEnabled: p.wasEnabled };
    const task = new ModInstallTask(request);
    this.jobs_.set(path, { pct: 0, latestVersionNumber: p.latest.versionNumber });
    this.notify();
    const timer = setInterval((): void => {
      const state = this.jobs_.get(path);
      if (state !== undefined) { state.pct = Math.floor(task.view.progress); this.notify(); }
    }, 300);
    const running = getDownloadTaskRegistry().enqueue(task).finally((): void => {
      clearInterval(timer); this.jobs_.delete(path); this.promises_.delete(path); this.notify();
    });
    this.promises_.set(path, running);
    return running;
  }
}
