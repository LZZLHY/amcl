import { describe, it, expect } from '@ohos/hypium'
import {
  TextInputSessionCoordinator,
  TextInputSessionLease,
  TextInputSessionSink
} from 'gamecontrol'

class RecordingTextSink implements TextInputSessionSink {
  acceptBegin: boolean = true
  acceptEnd: boolean = true
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
