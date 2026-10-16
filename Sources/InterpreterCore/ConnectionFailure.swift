import Foundation

/// Show actionable transport failures without exposing URLs, credentials, or raw errors.
public enum ConnectionFailure {
    public static func message(for error: Error, httpStatus: Int? = nil) -> String {
        if let status = httpStatus {
            switch status {
            case 401, 403:
                return "连接授权被拒绝，请在 iPhone 检查开发设备令牌并重新同步（HTTP \(status)）。"
            case 404:
                return "翻译服务地址不存在，请检查临时通道地址及 /interpret 路径（HTTP 404）。"
            case 429:
                return "服务当前繁忙或已有会话，请结束其他会话后重试（HTTP 429）。"
            case 500...599:
                return "翻译后端或临时通道暂不可用，请检查 Mac 服务（HTTP \(status)）。"
            default:
                break
            }
        }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else {
            return "翻译连接失败（错误码 \(value.code)），请检查服务后重试。"
        }
        let detail: String
        switch value.code {
        case URLError.notConnectedToInternet.rawValue:
            detail = "手表当前无法联网，或系统尚未允许音频网络连接。请确认手表网络后重试。"
        case URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue:
            detail = "无法解析服务地址，请检查临时通道是否仍在运行，并从 iPhone 重新同步地址。"
        case URLError.cannotConnectToHost.rawValue:
            detail = "无法连接翻译服务，请检查 Mac 后端和临时通道是否运行。"
        case URLError.timedOut.rawValue:
            detail = "连接超时，请检查手表网络、Mac 后端和临时通道。"
        case URLError.networkConnectionLost.rawValue:
            detail = "网络连接已断开，请检查手表网络后重新开始。"
        case URLError.secureConnectionFailed.rawValue,
             URLError.serverCertificateHasBadDate.rawValue,
             URLError.serverCertificateUntrusted.rawValue,
             URLError.serverCertificateHasUnknownRoot.rawValue,
             URLError.serverCertificateNotYetValid.rawValue:
            detail = "服务的安全连接校验失败，请检查服务地址和证书；不会跳过证书校验。"
        default:
            detail = "翻译连接失败，请检查服务地址、设备令牌和网络。"
        }
        return "\(detail)（网络错误 \(value.code)）"
    }
}
