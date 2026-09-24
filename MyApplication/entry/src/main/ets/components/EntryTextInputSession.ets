import testNapi from 'libentry.so'
import { hilog } from '@kit.PerformanceAnalysisKit'
import {
  TextInputSessionCoordinator,
  TextInputSessionLease,
  TextInputSessionSink,
  isPrintableUnicodeCodepoint
} from 'gamecontrol'

const TAG: string = 'EntryTextSession'

/** Process-wide typed text sink. No accepted session writes legacy char events. */
class EntryTextInputSessionSink implements TextInputSessionSink {
  begin(_owner: string, generation: number): boolean {
    try {
      if (!testNapi.textInputSessionSupported() ||
          !testNapi.beginTextInputSession(generation)) return false
      // Do not count candidate degradation at BEGIN time. InputMethodController
      // may not expose a candidate-list callback, but a session that never
      // receives candidate data has not exercised that unsupported path. The
      // metric is recorded only by candidates(), where the capability gap is
      // observed explicitly.
      return true
    } catch (_) {
      return false
    }
  }

  end(_owner: string, generation: number, _reason: string): boolean {
    try {
      return testNapi.endTextInputSession(generation)
    } catch (_) {
      return false
    }
  }

  abort(_owner: string, generation: number, _reason: string): void {
    try {
      testNapi.abortTextInputSession(generation)
    } catch (_) {
      hilog.warn(0x0000, TAG,
        'native text-session abort failed generation=%{public}d', generation)
    }
  }

  commit(_owner: string, generation: number, text: string): boolean {
    const scalars: number[] = EntryTextInputSessionSink.toCodePoints(text)
    for (let i: number = 0; i < scalars.length; i++) {
      if (!isPrintableUnicodeCodepoint(scalars[i])) return false
    }
    try {
      return testNapi.commitTextInput(generation, text)
    } catch (_) {
      return false
    }
  }

  editing(
    _owner: string,
    generation: number,
    text: string,
    selectionStart: number,
    selectionLength: number
  ): boolean {
    try {
      return testNapi.updateTextInputEditing(
        generation, text, selectionStart, selectionLength)
    } catch (_) {
      return false
    }
  }

  selection(
    _owner: string,
    generation: number,
    selectionStart: number,
    selectionLength: number
  ): boolean {
    try {
      return testNapi.updateTextInputSelection(
        generation, selectionStart, selectionLength)
    } catch (_) {
      return false
    }
  }

  candidates(
    _owner: string,
    _generation: number,
    _items: string[],
    _selected: number,
    _pageStart: number,
    _pageSize: number
  ): boolean {
    // InputMethodController exposes no candidate-list producer. If a future
    // caller reaches this seam, record the degradation and never fabricate it.
    try {
      testNapi.noteTextInputCandidatesUnsupported()
    } catch (_) {
      hilog.warn(0x0000, TAG,
        'candidate unsupported counter unavailable generation=%{public}d', _generation)
    }
    return false
  }

  private static toCodePoints(text: string): number[] {
    const output: number[] = []
    let index: number = 0
    while (index < text.length) {
      const codepoint: number = text.codePointAt(index) ?? 0
      output.push(codepoint)
      index += codepoint > 65535 ? 2 : 1
    }
    return output
  }
}

const entryTextSession = new TextInputSessionCoordinator(
  new EntryTextInputSessionSink())
const availabilityListeners: Set<() => void> = new Set<() => void>()

export function getEntryTextInputSession(): TextInputSessionCoordinator {
  return entryTextSession
}

export function endEntryTextInputSession(
  lease: TextInputSessionLease,
  reason: string
): boolean {
  let ended: boolean = entryTextSession.end(lease, reason)
  if (!ended) ended = entryTextSession.abort(lease, `abort-after-${reason}`)
  if (ended) {
    // Never notify synchronously from an attach/detach failure stack. A listener
    // may immediately try to acquire and fail again; synchronous recursion would
    // turn one platform error into a stack overflow.
    setTimeout((): void => {
      availabilityListeners.forEach((listener: () => void) => { listener() })
    }, 0)
  }
  return ended
}

export function addEntryTextSessionAvailabilityListener(listener: () => void): void {
  availabilityListeners.add(listener)
}

export function removeEntryTextSessionAvailabilityListener(listener: () => void): void {
  availabilityListeners.delete(listener)
}
