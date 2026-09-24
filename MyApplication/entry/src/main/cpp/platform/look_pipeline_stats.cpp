#include "look_pipeline_stats.h"

#include <cmath>

namespace amcl::input {
namespace {
double Magnitude(double x, double y) { return std::hypot(x, y); }

// 非有限值绝不进累计量：一个 inf 会让整份快照此后永久不可读，而快照的全部价值就是可读。
bool FinitePair(double x, double y) {
    return std::isfinite(x) && std::isfinite(y);
}
}  // namespace

void LookPipelineStats::NoteRejected() { ++s_.rejected; }

void LookPipelineStats::NoteAccepted(double scaledDx, double scaledDy,
                                     double emitDx, double emitDy,
                                     double pendingDx, double pendingDy) {
    if (!FinitePair(scaledDx, scaledDy) || !FinitePair(emitDx, emitDy) ||
        !FinitePair(pendingDx, pendingDy)) {
        ++s_.rejected;
        return;
    }
    ++s_.accepted;
    s_.scaledDx += scaledDx;
    s_.scaledDy += scaledDy;
    // 行程：与方向无关，来回扫不抵消。恒等式**不用**它（那边必须带符号）。
    s_.travelDx += (scaledDx < 0.0 ? -scaledDx : scaledDx);
    s_.travelDy += (scaledDy < 0.0 ? -scaledDy : scaledDy);
    s_.emitDx += emitDx;
    s_.emitDy += emitDy;
    if (emitDx != 0.0 || emitDy != 0.0) ++s_.emitted;
    s_.backlogDx = pendingDx;
    s_.backlogDy = pendingDy;
    const double magnitude = Magnitude(pendingDx, pendingDy);
    if (magnitude > s_.maxBacklog) s_.maxBacklog = magnitude;
}

void LookPipelineStats::NoteFlush(bool emit, double pendingDx,
                                  double pendingDy) {
    if (!FinitePair(pendingDx, pendingDy)) {
        ++s_.rejected;
        return;
    }
    if (emit) {
        ++s_.flushEmit;
        s_.emitDx += pendingDx;
        s_.emitDy += pendingDy;
    } else {
        ++s_.flushDiscard;
        s_.discardedDx += pendingDx;
        s_.discardedDy += pendingDy;
    }
    s_.backlogDx = 0.0;
    s_.backlogDy = 0.0;
}

void LookPipelineStats::Reset() { s_ = LookPipelineSnapshot{}; }

bool LookPipelineStats::ConservationHolds(double tolerance) const {
    if (!(tolerance >= 0.0)) return false;
    const double x = s_.emitDx + s_.discardedDx + s_.backlogDx - s_.scaledDx;
    const double y = s_.emitDy + s_.discardedDy + s_.backlogDy - s_.scaledDy;
    if (!FinitePair(x, y)) return false;
    return std::fabs(x) <= tolerance && std::fabs(y) <= tolerance;
}

}  // namespace amcl::input
