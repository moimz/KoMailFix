import Foundation

/// 메일 원문(RFC 822)에서 Apple Mail이 깨뜨려 보여주는 첨부파일 이름을 찾아
/// 하나의 RFC 2231 파라미터(`filename*=UTF-8''...`)로 다시 쓴다.
///
/// 고치는 유형
/// - RFC 2047 encoded-word가 여러 조각으로 나뉘면서 한글 한 글자의 바이트가 조각 경계에서 잘린 경우
///   (`=?UTF-8?B?...?= =?UTF-8?B?...?=`, `=?ks_c_5601-1987?B?...?=` 등)
/// - RFC 2231 연속 파라미터(`filename*0*=`, `filename*1*=`)가 글자 중간에서 잘린 경우
/// - 인코딩 없이 EUC-KR/CP949 바이트가 그대로 들어간 경우
/// - 선언된 문자셋과 실제 바이트가 맞지 않는 경우 (UTF-8 / CP949로 재시도)
///
/// 서명·암호화된 메일(multipart/signed, application/pkcs7-mime, multipart/encrypted)은 건드리지 않는다.
public enum MIMEFilenameRepair {

    public struct Fix: Equatable, Codable, Hashable {
        /// IMAP 방식 파트 번호 ("1", "2", "1.2" …)
        public let partID: String
        /// "Content-Type" 또는 "Content-Disposition"
        public let header: String
        /// "name" 또는 "filename"
        public let parameter: String
        /// 조각별로 따로 해독했을 때의 이름 (Mail이 보여주던 깨진 이름의 근사치)
        public let broken: String
        public let repaired: String
    }

    public struct Result {
        public let data: Data
        public let fixes: [Fix]

        /// 파트당 하나씩, filename 쪽을 우선한 목록
        public var attachmentFixes: [Fix] {
            var byPart: [String: Fix] = [:]
            for fix in fixes where byPart[fix.partID] == nil || fix.parameter == "filename" {
                byPart[fix.partID] = fix
            }
            return byPart.values.sorted { $0.partID < $1.partID }
        }
    }

    /// 고칠 것이 없으면 nil
    public static func repair(_ message: Data) -> Result? {
        rewrite(message, mode: .repair)
    }

    /// 보내는 메일의 첨부파일 이름을 NFC로 바꾼다. Apple Mail은 파일명을 NFD(자모 분리)로 보내므로
    /// Windows 쪽에서 자모가 풀려 보이는 것을 막는다. 바꿀 것이 없으면 nil
    public static func normalizeOutgoing(_ message: Data) -> Result? {
        rewrite(message, mode: .normalize)
    }

    private enum Mode { case repair, normalize }

    private static func rewrite(_ message: Data, mode: Mode) -> Result? {
        let bytes = [UInt8](message)
        var edits: [(range: Range<Int>, bytes: [UInt8])] = []
        var fixes: [Fix] = []
        walk(bytes, 0..<bytes.count, partID: "1", isRoot: true, mode: mode, edits: &edits, fixes: &fixes)
        guard !edits.isEmpty else { return nil }

        var out = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(edit.range, with: edit.bytes)
        }
        return Result(data: Data(out), fixes: fixes)
    }

    // MARK: - MIME 구조

    private static let untouchableTypes: Set<String> = [
        "multipart/signed", "multipart/encrypted",
        "application/pkcs7-mime", "application/x-pkcs7-mime",
    ]

    private static func walk(_ b: [UInt8], _ range: Range<Int>, partID: String, isRoot: Bool, mode: Mode,
                             edits: inout [(range: Range<Int>, bytes: [UInt8])], fixes: inout [Fix]) {
        let header = parseHeader(b, range)
        let contentType = header.fields.first { $0.name == "content-type" }.map { parseStructured($0.value) }
        let mimeType = contentType?.token.lowercased() ?? "text/plain"
        if untouchableTypes.contains(mimeType) { return }

        let charset = contentType?.params.first { $0.name == "charset" }?.value
        for field in header.fields {
            let family: String
            switch field.name {
            case "content-type": family = "name"
            case "content-disposition": family = "filename"
            default: continue
            }
            let structured = parseStructured(field.value)
            let resolved = switch mode {
            case .repair: resolve(structured.params, family: family, fallbackCharset: charset)
            case .normalize: normalize(structured.params, family: family, fallbackCharset: charset)
            }
            guard let resolved else { continue }

            var text = "\(field.rawName): \(structured.token)"
            for param in structured.params where !belongs(param.rawName, to: family) {
                text += ";\(header.newline)\t\(param.raw)"
            }
            if mode == .normalize, family == "name" {
                // 보내는 메일은 받는 쪽 호환을 위해 Apple Mail이 쓰던 RFC 2047 형태를 유지한다
                text += ";\(header.newline)\tname=\"\(encodedWords(resolved.repaired, newline: header.newline))\"\(header.newline)"
            } else {
                text += ";\(header.newline)\t\(family)*=UTF-8''\(percentEncode(resolved.repaired))\(header.newline)"
            }
            edits.append((field.range, Array(text.utf8)))
            fixes.append(Fix(partID: partID, header: field.rawName.lowercased() == "content-type" ? "Content-Type" : "Content-Disposition",
                             parameter: family, broken: resolved.broken, repaired: resolved.repaired))
        }

        guard mimeType.hasPrefix("multipart/"),
              let boundary = contentType?.params.first(where: { $0.name == "boundary" })?.value,
              !boundary.isEmpty else { return }
        for (index, part) in splitMultipart(b, header.bodyStart..<range.upperBound, boundary: boundary).enumerated() {
            let childID = isRoot ? "\(index + 1)" : "\(partID).\(index + 1)"
            walk(b, part, partID: childID, isRoot: false, mode: mode, edits: &edits, fixes: &fixes)
        }
    }

    private struct Field {
        /// 소문자 이름
        let name: String
        let rawName: String
        /// 필드 전체 (접힌 줄과 마지막 줄바꿈 포함)
        var range: Range<Int>
        /// 접힘을 푼 값 (Latin-1로 바이트 보존)
        var value: String
    }

    private struct Header {
        var fields: [Field] = []
        var bodyStart: Int
        var newline = "\r\n"
    }

    private static func parseHeader(_ b: [UInt8], _ range: Range<Int>) -> Header {
        var header = Header(bodyStart: range.upperBound)
        var sawFirstLine = false
        var i = range.lowerBound
        while i < range.upperBound {
            let lineEnd = b[i..<range.upperBound].firstIndex(of: 0x0A) ?? range.upperBound
            var contentEnd = lineEnd
            if contentEnd > i, b[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            if !sawFirstLine, lineEnd < range.upperBound {
                header.newline = contentEnd < lineEnd ? "\r\n" : "\n"
                sawFirstLine = true
            }
            let next = min(lineEnd + 1, range.upperBound)

            if contentEnd == i {
                header.bodyStart = next
                return header
            }
            let line = latin1(b[i..<contentEnd])
            if b[i] == 0x20 || b[i] == 0x09 {
                if !header.fields.isEmpty {
                    header.fields[header.fields.count - 1].value += line
                    header.fields[header.fields.count - 1].range = header.fields[header.fields.count - 1].range.lowerBound..<next
                }
            } else if let colon = line.firstIndex(of: ":") {
                let rawName = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...])
                header.fields.append(Field(name: rawName.lowercased(), rawName: rawName, range: i..<next, value: value))
            }
            i = next
        }
        return header
    }

    private static func splitMultipart(_ b: [UInt8], _ range: Range<Int>, boundary: String) -> [Range<Int>] {
        let delimiter: [UInt8] = [0x2D, 0x2D] + Array(boundary.data(using: .isoLatin1) ?? Data(boundary.utf8))
        var parts: [Range<Int>] = []
        var partStart: Int?
        var i = range.lowerBound
        while i < range.upperBound {
            let lineEnd = b[i..<range.upperBound].firstIndex(of: 0x0A) ?? range.upperBound
            var contentEnd = lineEnd
            if contentEnd > i, b[contentEnd - 1] == 0x0D { contentEnd -= 1 }

            if contentEnd - i >= delimiter.count, b[i..<(i + delimiter.count)].elementsEqual(delimiter) {
                var rest = b[(i + delimiter.count)..<contentEnd]
                let isClose = rest.starts(with: [0x2D, 0x2D])
                if isClose { rest = rest.dropFirst(2) }
                if rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    if let start = partStart {
                        var end = i
                        if end > start, b[end - 1] == 0x0A { end -= 1 }
                        if end > start, b[end - 1] == 0x0D { end -= 1 }
                        parts.append(start..<max(start, end))
                    }
                    if isClose { return parts }
                    partStart = min(lineEnd + 1, range.upperBound)
                }
            }
            i = lineEnd + 1
        }
        if let start = partStart, start < range.upperBound { parts.append(start..<range.upperBound) }
        return parts
    }

    // MARK: - 구조화 필드 (값; 파라미터=값; …)

    private struct Param {
        let name: String
        let rawName: String
        let value: String
        /// 원문 그대로의 "이름=값"
        let raw: String
    }

    private static func parseStructured(_ value: String) -> (token: String, params: [Param]) {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in value {
            if escaped { current.append(ch); escaped = false; continue }
            switch ch {
            case "\\" where inQuotes: escaped = true; current.append(ch)
            case "\"": inQuotes.toggle(); current.append(ch)
            case ";" where !inQuotes: pieces.append(current); current = ""
            default: current.append(ch)
            }
        }
        pieces.append(current)

        let token = pieces.removeFirst().trimmingCharacters(in: .whitespaces)
        let params = pieces.compactMap { piece -> Param? in
            let raw = piece.trimmingCharacters(in: .whitespaces)
            guard let eq = raw.firstIndex(of: "=") else { return nil }
            let rawName = raw[..<eq].trimmingCharacters(in: .whitespaces)
            var v = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
                v = String(v.dropFirst().dropLast())
                v = v.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            return Param(name: rawName.lowercased(), rawName: rawName, value: v, raw: raw)
        }
        return (token, params)
    }

    /// "filename", "filename*", "filename*0", "filename*0*" …
    private static func belongs(_ rawName: String, to family: String) -> Bool {
        let name = rawName.lowercased()
        if name == family { return true }
        guard name.hasPrefix(family + "*") else { return false }
        let rest = name.dropFirst(family.count + 1)
        return rest.isEmpty || rest.allSatisfy { $0.isNumber || $0 == "*" }
    }

    // MARK: - 이름 해석

    /// onlyBroken이 false이면 깨지지 않은 이름도 해독해 repaired로 돌려준다
    private static func resolve(_ params: [Param], family: String, fallbackCharset: String?, onlyBroken: Bool = true) -> (broken: String, repaired: String)? {
        let extended = params.filter { $0.name != family && belongs($0.rawName, to: family) }
        if !extended.isEmpty { return resolveRFC2231(extended, family: family, onlyBroken: onlyBroken) }
        guard let plain = params.first(where: { $0.name == family }) else { return nil }
        if plain.value.contains("=?"), let result = resolveEncodedWords(plain.value, onlyBroken: onlyBroken) { return result }
        return resolveRaw(plain.value, fallbackCharset: fallbackCharset, onlyBroken: onlyBroken)
    }

    /// 이름이 NFC가 아니면 (원래 이름, NFC 이름)
    private static func normalize(_ params: [Param], family: String, fallbackCharset: String?) -> (broken: String, repaired: String)? {
        guard let name = resolve(params, family: family, fallbackCharset: fallbackCharset, onlyBroken: false)?.repaired else { return nil }
        let nfc = name.precomposedStringWithCanonicalMapping
        // String의 ==는 NFC와 NFD를 같다고 보므로 바이트로 비교한다
        guard !nfc.utf8.elementsEqual(name.utf8) else { return nil }
        return (name, nfc)
    }

    /// filename*=, filename*0*=, filename*1= …
    private static func resolveRFC2231(_ params: [Param], family: String, onlyBroken: Bool) -> (broken: String, repaired: String)? {
        var segments: [(index: Int, encoded: Bool, value: String)] = []
        for param in params {
            var rest = param.name.dropFirst(family.count + 1)
            let encoded = rest.hasSuffix("*") || rest.isEmpty
            if rest.hasSuffix("*") { rest = rest.dropLast() }
            segments.append((Int(rest) ?? 0, encoded, param.value))
        }
        segments.sort { $0.index < $1.index }

        var charset = "us-ascii"
        var pieces: [[UInt8]] = []
        for (n, segment) in segments.enumerated() {
            var value = Substring(segment.value)
            if n == 0, segment.encoded {
                let quoteParts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if quoteParts.count == 3 {
                    charset = String(quoteParts[0])
                    value = quoteParts[2]
                }
            }
            pieces.append(segment.encoded ? percentDecode(value) : latin1Bytes(String(value)))
        }

        let joined = pieces.flatMap { $0 }
        guard joined.contains(where: { $0 >= 0x80 }) else { return nil }
        let declared = decode(joined, charset: charset)
        guard let repaired = declared ?? decodeFallback(joined) else { return nil }

        let separate = pieces.map { decode($0, charset: charset) }
        let brokenSeparately = segments.count > 1 && separate.contains { $0 == nil }
        guard !onlyBroken || declared == nil || brokenSeparately else { return nil }
        return (separate.map { $0 ?? "?" }.joined(), repaired)
    }

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#)

    /// =?UTF-8?B?...?= =?UTF-8?B?...?=
    private static func resolveEncodedWords(_ value: String, onlyBroken: Bool) -> (broken: String, repaired: String)? {
        let ns = value as NSString
        let matches = encodedWord.matches(in: value, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        enum Token { case text(String); case word(charset: String, bytes: [UInt8]) }
        var tokens: [Token] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                tokens.append(.text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            var charset = ns.substring(with: match.range(at: 1))
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }
            let payload = ns.substring(with: match.range(at: 3))
            let bytes = ns.substring(with: match.range(at: 2)).uppercased() == "B" ? base64Decode(payload) : qDecode(payload)
            guard let bytes else { return nil }
            tokens.append(.word(charset: charset, bytes: bytes))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { tokens.append(.text(ns.substring(from: cursor))) }

        // 조각마다 따로 해독 (Mail이 하는 방식)
        var broken = ""
        for token in tokens {
            switch token {
            case .text(let text):
                if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                broken += text
            case .word(let charset, let bytes):
                broken += decode(bytes, charset: charset) ?? "?"
            }
        }

        // 이어진 같은 문자셋 조각을 합쳐서 해독
        var repaired = ""
        var pending: (charset: String, bytes: [UInt8])?
        func flush() -> Bool {
            guard let p = pending else { return true }
            pending = nil
            guard let s = decode(p.bytes, charset: p.charset) ?? decodeFallback(p.bytes) else { return false }
            repaired += s
            return true
        }
        for token in tokens {
            switch token {
            case .text(let text):
                if text.trimmingCharacters(in: .whitespaces).isEmpty, pending != nil { continue }
                guard flush() else { return nil }
                repaired += text
            case .word(let charset, let bytes):
                if let p = pending, p.charset.lowercased() == charset.lowercased() {
                    pending = (p.charset, p.bytes + bytes)
                } else {
                    guard flush() else { return nil }
                    pending = (charset, bytes)
                }
            }
        }
        guard flush() else { return nil }

        guard !onlyBroken || repaired != broken, !repaired.isEmpty else { return nil }
        return (broken, repaired)
    }

    /// 인코딩 없이 8비트 바이트가 그대로 들어간 이름
    private static func resolveRaw(_ value: String, fallbackCharset: String?, onlyBroken: Bool) -> (broken: String, repaired: String)? {
        let bytes = latin1Bytes(value)
        guard bytes.contains(where: { $0 >= 0x80 }) else { return nil }
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return onlyBroken ? nil : (utf8, utf8) }
        let repaired = fallbackCharset.flatMap { decode(bytes, charset: $0) } ?? decodeFallback(bytes)
        guard let repaired, !repaired.isEmpty else { return nil }
        return (String(decoding: bytes, as: UTF8.self), repaired)
    }

    // MARK: - 문자셋

    static let koreanEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

    static func encoding(for charset: String) -> String.Encoding? {
        switch charset.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "ks_c_5601-1987", "ks_c_5601-1989", "ks_c_5601", "ksc5601", "korean",
             "euc-kr", "euckr", "cp949", "windows-949", "x-windows-949", "ms949", "uhc":
            return koreanEncoding
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    /// 엄격한 해독: 잘린 글자가 있으면 nil
    static func decode(_ bytes: [UInt8], charset: String) -> String? {
        guard let enc = encoding(for: charset) else { return nil }
        if enc == .ascii, bytes.contains(where: { $0 >= 0x80 }) { return nil }
        guard let s = String(data: Data(bytes), encoding: enc), !s.contains("\u{FFFD}") else { return nil }
        // 일부 디코더는 잘린 끝 바이트를 조용히 버리므로 다시 인코딩해 길이를 확인
        if enc != .utf8, let back = s.data(using: enc), back.count != bytes.count { return nil }
        return s
    }

    private static func decodeFallback(_ bytes: [UInt8]) -> String? {
        decode(bytes, charset: "utf-8") ?? decode(bytes, charset: "cp949")
    }

    // MARK: - 바이트 유틸

    private static func latin1(_ bytes: ArraySlice<UInt8>) -> String {
        String(data: Data(bytes), encoding: .isoLatin1) ?? ""
    }

    private static func latin1Bytes(_ s: String) -> [UInt8] {
        [UInt8](s.data(using: .isoLatin1) ?? Data(s.utf8))
    }

    private static func base64Decode(_ s: String) -> [UInt8]? {
        var t = s.filter { !$0.isWhitespace }
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map { [UInt8]($0) }
    }

    private static func qDecode(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        var bytes = latin1Bytes(s)[...]
        while let c = bytes.popFirst() {
            if c == 0x5F {
                out.append(0x20)
            } else if c == 0x3D, bytes.count >= 2, let v = UInt8(latin1(bytes.prefix(2)), radix: 16) {
                out.append(v)
                bytes = bytes.dropFirst(2)
            } else {
                out.append(c)
            }
        }
        return out
    }

    private static func percentDecode(_ s: Substring) -> [UInt8] {
        var out: [UInt8] = []
        var bytes = latin1Bytes(String(s))[...]
        while let c = bytes.popFirst() {
            if c == 0x25, bytes.count >= 2, let v = UInt8(latin1(bytes.prefix(2)), radix: 16) {
                out.append(v)
                bytes = bytes.dropFirst(2)
            } else {
                out.append(c)
            }
        }
        return out
    }

    private static let attrChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)

    static func percentEncode(_ s: String) -> String {
        s.utf8.map { attrChars.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    /// RFC 2047 B 인코딩. 한 조각이 75자를 넘지 않도록 글자 경계에서 나누고 접어서 잇는다
    static func encodedWords(_ s: String, newline: String) -> String {
        let maxBytes = 45  // base64 60자 + "=?UTF-8?B?" + "?=" = 72자
        var words: [[UInt8]] = [[]]
        for ch in s {
            let bytes = Array(String(ch).utf8)
            if words[words.count - 1].count + bytes.count > maxBytes, !words[words.count - 1].isEmpty { words.append([]) }
            words[words.count - 1] += bytes
        }
        return words.map { "=?UTF-8?B?\(Data($0).base64EncodedString())?=" }.joined(separator: "\(newline) ")
    }
}
