import { RenderDiagnosticAttachment } from './ets/runtime/RenderDiagnosticAttachment';

// Non-desktop products never access retained desktop diagnostic files.
export class ProductRenderDiagnostics {
  static readonly enabled: boolean = false;
  static readonly shareCategory: string = '';

  static save(_filesDir: string, _text: string, _detailed: boolean, _activityId: number = 0): void {}

  static read(_filesDir: string, _activityId: number = 0): RenderDiagnosticAttachment | undefined {
    return undefined;
  }

  static appendForShare(content: string, _diagnostic: RenderDiagnosticAttachment | undefined): string {
    return content;
  }
}
