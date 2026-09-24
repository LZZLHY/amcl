#include "exception.h"

#include <sstream>

namespace download {

const char* errorKindToString(ErrorKind k) {
    switch (k) {
        case ErrorKind::Unknown:          return "Unknown";
        case ErrorKind::ConnectionError:  return "ConnectionError";
        case ErrorKind::ProtocolError:    return "ProtocolError";
        case ErrorKind::Timeout:          return "Timeout";
        case ErrorKind::AbortedByUser:    return "AbortedByUser";
        case ErrorKind::SslError:         return "SslError";
        case ErrorKind::FileIoError:      return "FileIoError";
        case ErrorKind::DiskFullError:    return "DiskFullError";
        case ErrorKind::ChecksumMismatch: return "ChecksumMismatch";
        case ErrorKind::SizeMismatch:     return "SizeMismatch";
        case ErrorKind::InvalidConfig:       return "InvalidConfig";
        case ErrorKind::InternalError:       return "InternalError";
        case ErrorKind::QuotaExceededError:  return "QuotaExceededError";
        case ErrorKind::StorageIoError:      return "StorageIoError";
    }
    return "Unknown";
}

std::string DownloadException::toString() const {
    std::ostringstream os;
    os << "[" << errorKindToString(kind) << "]";
    if (native_code != 0) {
        os << " (code=" << native_code << ")";
    }
    if (http_status > 0) {
        os << " http=" << http_status;
    }
    if (!url_context.empty()) {
        os << " " << url_context;
    }
    if (!message.empty()) {
        os << ": " << message;
    }
    return os.str();
}

} // namespace download
