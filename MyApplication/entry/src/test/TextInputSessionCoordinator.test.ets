import { describe, it, expect } from '@ohos/hypium'
import {
  TextInputKeyTapResult,
  TextInputSessionCoordinator,
  TextInputSessionLease,
  TextInputSessionSink,
  textInputKeyTapResultFromNative
} from 'gamecontrol'

class RecordingTextSink implements TextInputSessionSink {
  acceptBegin: boolean = true
  acceptEnd: boolean = true
  keyTapResult: TextInputKeyTapResult = TextInputKeyTapResult.Submitted
  calls: string[] = []

  begin(owner: string, generation: number): boolean {
    this.calls.push(`begin:${owner}:${generation}`)
    return this.acceptBegin
  }

  end(owner: string, generation: number, reason: string): boolean {
    this.calls.push(`end:${owner}:${generation}:${reason}`)
    return this.acceptEnd
  }

  abort(owner: string, generation: number, reason: string): void {
    this.calls.push(`abort:${owner}:${generation}:${reason}`)
  }

  commit(owner: string, generation: number, text: string): boolean {
    this.calls.push(`commit:${owner}:${generation}:${text}`)
    return true
  }

  keyTap(owner: string, generation: number, ohosKeyCode: number,
    glfwKey: number): TextInputKeyTapResult {
    this.calls.push(`keyTap:${owner}:${generation}:${ohosKeyCode}:${glfwKey}`)
    return this.keyTapResult
  }

  editing(
    owner: string,
    generation: number,
    text: string,
    selectionStart: number,
    selectionLength: number
  ): boolean {
    this.calls.push(
      `editing:${owner}:${generation}:${text}:${selectionStart}:${selectionLength}`)
    return true
  }

  selection(
    owner: string,
    generation: number,
    selectionStart: number,
    selectionLength: number
  ): boolean {
    this.calls.push(
      `selection:${owner}:${generation}:${selectionStart}:${selectionLength}`)
    return true
  }

  candidates(
    owner: string,
    generation: number,
    items: string[],
    selected: number,
    pageStart: number,
    pageSize: number
  ): boolean {
    this.calls.push(
      `candidates:${owner}:${generation}:${items.join('|')}:${selected}:${pageStart}:${pageSize}`)
    return true
  }
}

export default function textInputSessionCoordinatorTest(): void {
  describe('TextInputSessionCoordinator', () => {
    it('宿主RESET只换宿主代次，保留同一UI租约并拒绝结束后的迟到提交', 0, () => {
      const sink = new RecordingTextSink()
      const coordinator = new TextInputSessionCoordinator(sink)
      const lease: TextInputSessionLease = coordinator.begin('desktop-ime') ?? new TextInputSessionLease()
      coordinator.invalidateHostSession()
      expect(coordinator.commit(lease, '恢复')).assertTrue()
      expect(sink.calls[sink.calls.length - 1]).assertEqual('commit:desktop-ime:2:恢复')
      expect(coordinator.editing(lease, '预编辑', 3, 0)).assertTrue()
      expect(coordinator.end(lease, 'close')).assertTrue()
      expect(sink.calls[sink.calls.length - 1]).assertEqual('end:desktop-ime:2:close')
      expect(coordinator.commit(lease, '迟到')).assertFalse()
    })

    it('RESET后宿主暂拒BEGIN保持租约，下一合法命令可以重试且非法文本不重建', 0, () => {
      const sink = new RecordingTextSink()
      const coordinator = new TextInputSessionCoordinator(sink)
      const lease: TextInputSessionLease = coordinator.begin('field') ?? new TextInputSessionLease()
      coordinator.invalidateHostSession()
      expect(coordinator.commit(lease, '\uD800')).assertFalse()
      expect(sink.calls.length).assertEqual(1)
      sink.acceptBegin = false
      expect(coordinator.commit(lease, '等待')).assertFalse()
      expect(coordinator.isActive()).assertTrue()
      sink.acceptBegin = true
      expect(coordinator.commit(lease, '恢复')).assertTrue()
      expect(sink.calls[sink.calls.length - 1]).assertEqual('commit:field:3:恢复')
    })
    it('grants exactly one client lease even when owner labels match', 0, () => {
      const sink = new RecordingTextSink()
      const coordinator = new TextInputSessionCoordinator(sink)
      const first: TextInputSessionLease | undefined = coordinator.begin('chat')
      const again: TextInputSessionLease | undefined = coordinator.begin('chat')
      const denied: TextInputSessionLease | undefined = coordinator.begin('field')
      expect(first !== undefined).assertTrue()
      expect(again === undefined).assertTrue()
      expect(denied === undefined).assertTrue()
      expect(sink.calls.length).assertEqual(1)
    })

    it('rejects late callbacks after the lease ended', 0, () => {
      const sink = new RecordingTextSink()
      const coordinator = new TextInputSessionCoordinator(sink)
      const lease: TextInputSessionLease = coordinator.begin('chat') ?? new TextInputSessionLease()
      expect(coordinator.commit(lease, '中文😀')).assertTrue()
      expect(coordinator.end(lease, 'close')).assertTrue()
      expect(coordinator.commit(lease, 'late')).assertFalse()
      expect(coordinator.selection(lease, 0, 0)).assertFalse()
    })

    it('bounds standalone selection to the wire-safe session window', 0, () => {
      const sink = new RecordingTextSink()
      const coordinator = new TextInputSessionCoordinator(sink)
      const lease: TextInputSessionLease = coordinator.begin('field') ?? new TextInputSessionLease()
      expect(coordinator.selection(lease, 4096, 0)).assertTrue()
      expect(coordinator.selection(lease, 4097, 0)).assertFalse()
      expect(coordinator.selection(lease, 0, 4097)).assertFalse()
      expect(coordinator.selection(lease, 4096, 1)).assertFalse()
    })

    it('uses Unicode scalar indices for editing ranges', 0, () => {
      const sink = new RecordingTextSink()
      const coordinator = new TextInputSessionCoordinator(sink)
      const lease: TextInputSessionLease = coordinator.begin('field') ?? new TextInputSessionLease()
      expect(coordinator.editing(lease, 'a😀中', 1, 2)).assertTrue()
      expect(coordinator.editing(lease, 'a😀中', 2, 2)).assertFalse()
      expect(coordinator.editing(lease, 'a😀中', 1.5, 1)).assertFalse()
      expect(coordinator.editing(lease, '\uD800', 0, 0)).assertFalse()
      expect(coordinator.commit(lease, '\uDC00')).assertFalse()
    })

    it('bounds and validates candidate packets', 0, () => {
      const sink = new RecordingTextSink()
      const coordinator = new TextInputSessionCoordinator(sink)
      const lease: TextInputSessionLease = coordinator.begin('field') ?? new TextInputSessionLease()
      const items: string[] = ['你', '泥', '拟']
      expect(coordinator.candidates(lease, items, 1, 0, 3)).assertTrue()
      expect(coordinator.candidates(lease, items, 1, 1, 2)).assertTrue()
      expect(coordinator.candidates(lease, items, 0, 1, 2)).assertFalse()
      expect(coordinator.candidates(lease, items, 3, 0, 3)).assertFalse()
      expect(coordinator.candidates(lease, [], 0, 0, 0)).assertTrue()
      const invalidItems: string[] = ['ok', '\uD800']
      expect(coordinator.candidates(lease, invalidItems, 0, 0, 2)).assertFalse()
    })

    it('编辑键与提交共用宿主会话号：RESET后先重建会话再发键', 0, () => {
      const sink = new RecordingTextSink()
      const coordinator = new TextInputSessionCoordinator(sink)
      const lease: TextInputSessionLease = coordinator.begin('desktop-ime') ?? new TextInputSessionLease()
      expect(coordinator.keyTap(lease, 2055, 259) === TextInputKeyTapResult.Submitted).assertTrue()
      expect(sink.calls[sink.calls.length - 1]).assertEqual('keyTap:desktop-ime:1:2055:259')
      coordinator.invalidateHostSession()
      expect(coordinator.hostGenerationOf(lease)).assertEqual(0)
      expect(coordinator.keyTap(lease, 2054, 257) === TextInputKeyTapResult.Submitted).assertTrue()
      expect(sink.calls[sink.calls.length - 2]).assertEqual('begin:desktop-ime:2')
      expect(sink.calls[sink.calls.length - 1]).assertEqual('keyTap:desktop-ime:2:2054:257')
      expect(coordinator.hostGenerationOf(lease)).assertEqual(2)
    })

    it('宿主拒绝重建时仍交给宿主判路由（0号），迟到租约直接拒绝', 0, () => {
      const sink = new RecordingTextSink()
      const coordinator = new TextInputSessionCoordinator(sink)
      const lease: TextInputSessionLease = coordinator.begin('chat') ?? new TextInputSessionLease()
      coordinator.invalidateHostSession()
      sink.acceptBegin = false
      sink.keyTapResult = TextInputKeyTapResult.NotTypedRoute
      expect(coordinator.keyTap(lease, 2055, 259) === TextInputKeyTapResult.NotTypedRoute).assertTrue()
      expect(sink.calls[sink.calls.length - 1]).assertEqual('keyTap:chat:0:2055:259')
      sink.acceptBegin = true
      expect(coordinator.abort(lease, 'close')).assertTrue()
      const before: number = sink.calls.length
      expect(coordinator.keyTap(lease, 2055, 259) === TextInputKeyTapResult.Rejected).assertTrue()
      expect(sink.calls.length).assertEqual(before)
      expect(coordinator.hostGenerationOf(lease)).assertEqual(0)
    })

    it('宿主三态镜像：未知数值一律按拒绝处理', 0, () => {
      expect(textInputKeyTapResultFromNative(0) === TextInputKeyTapResult.Submitted).assertTrue()
      expect(textInputKeyTapResultFromNative(1) === TextInputKeyTapResult.NotTypedRoute).assertTrue()
      expect(textInputKeyTapResultFromNative(2) === TextInputKeyTapResult.Rejected).assertTrue()
      expect(textInputKeyTapResultFromNative(7) === TextInputKeyTapResult.Rejected).assertTrue()
      expect(textInputKeyTapResultFromNative(-1) === TextInputKeyTapResult.Rejected).assertTrue()
    })

    it('does not activate when the host rejects begin or end', 0, () => {
      const sink = new RecordingTextSink()
      sink.acceptBegin = false
      const coordinator = new TextInputSessionCoordinator(sink)
      expect(coordinator.begin('chat') === undefined).assertTrue()
      expect(coordinator.isActive()).assertFalse()

      sink.acceptBegin = true
      const lease: TextInputSessionLease = coordinator.begin('chat') ?? new TextInputSessionLease()
      sink.acceptEnd = false
      expect(coordinator.end(lease, 'focus-lost')).assertFalse()
      expect(coordinator.isActive()).assertTrue()
      expect(coordinator.abort(lease, 'forced-lifecycle-fence')).assertTrue()
      expect(coordinator.isActive()).assertFalse()
    })
  })
}
