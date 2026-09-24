#include "net_state.h"

namespace download {

const char* netStateToString(NetState s) {
    switch (s) {
        case NetState::WaitingForSchedule: return "WaitingForSchedule";
        case NetState::CheckingLocal:      return "CheckingLocal";
        case NetState::Connecting:         return "Connecting";
        case NetState::Reading:            return "Reading";
        case NetState::Downloading:        return "Downloading";
        case NetState::FinalCheck:         return "FinalCheck";
        case NetState::Finished:           return "Finished";
        case NetState::Failed:             return "Failed";
        case NetState::Aborted:            return "Aborted";
    }
    return "Unknown";
}

const char* loadStateToString(LoadState s) {
    switch (s) {
        case LoadState::Waiting:  return "Waiting";
        case LoadState::Loading:  return "Loading";
        case LoadState::Finished: return "Finished";
        case LoadState::Failed:   return "Failed";
        case LoadState::Aborted:  return "Aborted";
    }
    return "Unknown";
}

} // namespace download
