import Foundation

/// Show actionable transport failures without exposing URLs, credentials, or raw errors.
public enum ConnectionFailure {
    public static func message(for error: Error, httpStatus: Int? = nil) -> String {
        if let status = httpStatus {
            switch status {
            case 401, 403:
                return "连接授权被拒绝，请在 iPhone 检查 OpenAI API Key 并重新同步（HTTP \(status)）。"
            case 404:
                return "翻译服务请求异常，请重试（HTTP 404）。"
            case 429:
                return "服务当前繁忙或达到限额，请稍后重试（HTTP 429）。"
            case 500...599:
                return "翻译服务暂不可用（HTTP \(status)）。"
            default:
                break
            }
        }
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain {
            return "网络连接被系统中断（\(value.code)），请检查手表网络后重新开始。"
        }
        guard value.domain == NSURLErrorDomain else {
            return "翻译连接失败（错误码 \(value.code)），请检查服务后重试。"
        }
        let detail: String
        switch value.code {
        case URLError.notConnectedToInternet.rawValue:
            detail = "手表当前无法联网，或系统尚未允许音频网络连接。请确认手表网络后重试。"
        case URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue:
            detail = "无法解析 OpenAI 服务地址，请检查手表网络后重试。"
        case URLError.cannotConnectToHost.rawValue:
            detail = "无法连接 OpenAI 翻译服务，请检查手表网络后重试。"
        case URLError.timedOut.rawValue:
            detail = "连接超时，请检查手表网络后重试。"
        case URLError.networkConnectionLost.rawValue:
            detail = "网络连接已断开，请检查手表网络后重新开始。"
        case URLError.secureConnectionFailed.rawValue,
             URLError.serverCertificateHasBadDate.rawValue,
             URLError.serverCertificateUntrusted.rawValue,
             URLError.serverCertificateHasUnknownRoot.rawValue,
             URLError.serverCertificateNotYetValid.rawValue:
            detail = "与 OpenAI 的安全连接校验失败，请检查手表网络；不会跳过证书校验。"
        default:
            detail = "翻译连接失败，请检查手表网络和 API Key 配置后重试。"
        }
        return "\(detail)（网络错误 \(value.code)）"
    }
}
