// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import AlibabaCloudOSS
import Foundation

/// 可选的 OSS 自定义域名。域名配置状态和证书状态分别解析。
struct PublicLinkDomain: Identifiable, Hashable {
    let host: String
    let wantsHTTPS: Bool

    var id: String { host }

    /// 替换公开地址的主机与协议，完整保留 SDK 编码的对象路径。
    func applyDomain(to components: inout URLComponents) {
        components.host = host
        components.port = nil
        components.scheme = wantsHTTPS ? "https" : "http"
    }
}

/// 公开链接从 SDK 的对象地址派生，保留编码后的部署路径及对象 key，移除签名。
func publicObjectLink(from signedURL: URL, domain: PublicLinkDomain?) throws -> URL {
    guard var parts = URLComponents(url: signedURL, resolvingAgainstBaseURL: false) else {
        throw BrowserError.message(appText("无法解析对象链接。"))
    }
    parts.percentEncodedQuery = nil
    parts.percentEncodedFragment = nil
    domain?.applyDomain(to: &parts)
    guard let publicURL = parts.url else {
        throw BrowserError.message(appText("无法解析对象链接。"))
    }
    return publicURL
}

extension OssStorage {
    /// 原生 SDK 对自定义操作执行 OSS V4 签名，返回已启用域名。
    /// 需要 Bucket 上的 ListCname 权限。无绑定记录时返回空列表。
    /// https://www.alibabacloud.com/help/en/oss/developer-reference/listcname
    func listPublicLinkDomains(bucket: StorageBucket) async throws -> [PublicLinkDomain] {
        let input = OperationInput(
            operationName: "ListCname", method: "GET", parameters: ["cname": ""], bucket: bucket.name
        )
        do {
            let response = try await makeClient(bucket).invokeOperation(input)
            guard case let .data(data) = response.body, data.count <= 1024 * 1024 else {
                throw BrowserError.message(appText("无法解析 OSS 域名列表。"))
            }
            return try CnameXMLParser.parseDomains(data)
        } catch let error as ServerError where error.statusCode == 404 && error.code == "NoSuchCname" {
            return []
        }
    }
}

/// 按 XML 节点路径识别域名和证书字段，外部实体保持禁用。
final class CnameXMLParser: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""
    private var domain = ""
    private var enabled = false
    private var certificateEnabled = false
    private var isWildcard = false
    private var domains: [PublicLinkDomain] = []

    static func parseDomains(_ data: Data) throws -> [PublicLinkDomain] {
        let delegate = CnameXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw BrowserError.message(appText("OSS 域名列表不是有效 XML。")) }
        return delegate.domains
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        path.append(elementName)
        text = ""
        if path == ["ListCnameResult", "Cname"] {
            domain = ""
            enabled = false
            certificateEnabled = false
            isWildcard = false
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch path {
        case ["ListCnameResult", "Cname", "Domain"]:
            domain = value
        case ["ListCnameResult", "Cname", "Status"]:
            enabled = value == "Enabled"
        case ["ListCnameResult", "Cname", "Certificate", "Status"]:
            certificateEnabled = value == "Enabled"
        case ["ListCnameResult", "Cname", "IsWildCard"]:
            isWildcard = value.lowercased() == "true"
        case ["ListCnameResult", "Cname"]:
            let valid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
            if enabled, !isWildcard, !domain.isEmpty, domain.unicodeScalars.allSatisfy(valid.contains),
               !domains.contains(where: { $0.host.caseInsensitiveCompare(domain) == .orderedSame }) {
                domains.append(PublicLinkDomain(host: domain, wantsHTTPS: certificateEnabled))
            }
        default:
            break
        }
        _ = path.popLast()
        text = ""
    }
}
