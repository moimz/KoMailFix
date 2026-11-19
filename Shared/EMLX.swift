import Foundation

/// Apple Mail의 .emlx / .partial.emlx 파일
/// 형식: "<메시지 바이트 수>\n" + 메시지 원문 + XML plist
public struct EMLX {
    public var message: Data
    public let trailer: Data

    public init?(_ data: Data) {
        guard let newline = data.prefix(32).firstIndex(of: 0x0A),
              let length = Int(String(decoding: data[data.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
              length >= 0 else { return nil }
        let start = newline + 1
        let end = min(start + length, data.endIndex)
        message = data[start..<end]
        trailer = data[end...]
    }

    public var data: Data {
        var out = Data("\(message.count)\n".utf8)
        out.append(message)
        out.append(trailer)
        return out
    }

    /// 12345.partial.emlx → "12345"
    public static func messageNumber(of url: URL) -> String {
        String(url.lastPathComponent.prefix { $0 != "." })
    }

    /// Mail이 첨부파일을 따로 풀어 저장하는 폴더: …/Attachments/<번호>/<파트>/<파일명>
    public static func attachmentDirectory(for url: URL, partID: String) -> URL {
        url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Attachments")
            .appendingPathComponent(messageNumber(of: url))
            .appendingPathComponent(partID)
    }
}
