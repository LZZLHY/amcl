// mouse_synth_touch_source.cpp — 分类器实现。契约与真机差异见 .h。
#include "mouse_synth_touch_source.h"

namespace amcl::input {

MouseSynthTouchSource ClassifyMouseSynthTouchSource(
    bool changedPointMatched, bool toolQuerySucceeded, bool toolIsUnknown,
    bool sourceQuerySucceeded, bool sourceIsMouse) {
    if (!changedPointMatched || !toolQuerySucceeded || !sourceQuerySucceeded) {
        return MouseSynthTouchSource::kUnknown;
    }
    return toolIsUnknown && sourceIsMouse ? MouseSynthTouchSource::kMouseSynth
                                          : MouseSynthTouchSource::kOther;
}

}  // namespace amcl::input
