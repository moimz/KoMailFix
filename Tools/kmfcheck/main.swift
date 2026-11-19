import Foundation

// 개발용 점검 도구
//   kmfcheck test              — 샘플 메일로 보정 로직 확인
//   kmfcheck scan <폴더>        — .emlx/.eml을 읽기만 하고 고칠 대상을 출력
//   kmfcheck show <파일>        — 한 파일의 보정 결과 원문 출력

let name = "(사내) 업무관리 시스템 사용 매뉴얼.pdf"
let korean = MIMEFilenameRepair.koreanEncoding

func chunks(_ bytes: [UInt8], _ size: Int) -> [[UInt8]] {
    stride(from: 0, to: bytes.count, by: size).map { Array(bytes[$0..<min($0 + size, bytes.count)]) }
}

func bWords(_ charset: String, _ bytes: [UInt8], size: Int) -> String {
    chunks(bytes, size).map { "=?\(charset)?B?\(Data($0).base64EncodedString())?=" }.joined(separator: "\r\n ")
}

func qWords(_ charset: String, _ bytes: [UInt8], size: Int) -> String {
    chunks(bytes, size).map { "=?\(charset)?Q?" + $0.map { String(format: "=%02X", $0) }.joined() + "?=" }.joined(separator: " ")
}

func message(contentType: String = "application/pdf", disposition: String, top: String = "multipart/mixed; boundary=\"XX\"") -> Data {
    var m = "From: a@example.com\r\nSubject: test\r\nMIME-Version: 1.0\r\nContent-Type: \(top)\r\n\r\n"
    m += "--XX\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nhello\r\n"
    m += "--XX\r\nContent-Type: \(contentType)\r\nContent-Disposition: \(disposition)\r\nContent-Transfer-Encoding: base64\r\n\r\nJVBERi0=\r\n"
    m += "--XX--\r\n"
    return m.data(using: .isoLatin1)!
}

let utf8 = Array(name.utf8)
let cp949 = [UInt8](name.data(using: korean)!)
let pct = MIMEFilenameRepair.percentEncode(name)

struct Case { let title: String; let data: Data; let expectFix: Bool }
let cases: [Case] = [
    Case(title: "UTF-8 B 조각 분할", data: message(disposition: "attachment;\r\n filename=\"\(bWords("UTF-8", utf8, size: 10))\""), expectFix: true),
    Case(title: "ks_c_5601-1987 B 조각 분할", data: message(disposition: "attachment;\r\n filename=\"\(bWords("ks_c_5601-1987", cp949, size: 8))\""), expectFix: true),
    Case(title: "UTF-8 Q 조각 분할", data: message(disposition: "attachment; filename=\"\(qWords("utf-8", utf8, size: 7))\""), expectFix: true),
    Case(title: "Content-Type name 분할", data: message(contentType: "application/pdf;\r\n name=\"\(bWords("UTF-8", utf8, size: 10))\"", disposition: "attachment"), expectFix: true),
    Case(title: "RFC 2231 연속 분할", data: message(disposition: "attachment;\r\n " + chunks(utf8, 10).enumerated().map { i, c in "filename*\(i)*=" + (i == 0 ? "UTF-8''" : "") + c.map { String(format: "%%%02X", $0) }.joined() }.joined(separator: ";\r\n ")), expectFix: true),
    Case(title: "인코딩 없는 CP949", data: message(disposition: "attachment; filename=\"" + String(data: Data(cp949), encoding: .isoLatin1)! + "\""), expectFix: true),
    Case(title: "정상 UTF-8 B 한 조각", data: message(disposition: "attachment; filename=\"=?UTF-8?B?\(Data(utf8).base64EncodedString())?=\""), expectFix: false),
    Case(title: "정상 글자 단위 분할", data: message(disposition: "attachment; filename=\"=?UTF-8?B?\(Data("(사내) 업무".utf8).base64EncodedString())?= =?UTF-8?B?\(Data("관리 시스템 사용 매뉴얼.pdf".utf8).base64EncodedString())?=\""), expectFix: false),
    Case(title: "정상 RFC 2231", data: message(disposition: "attachment; filename*=UTF-8''\(pct)"), expectFix: false),
    Case(title: "ASCII 이름", data: message(disposition: "attachment; filename=\"manual.pdf\""), expectFix: false),
    Case(title: "서명 메일은 건드리지 않음", data: message(disposition: "attachment;\r\n filename=\"\(bWords("UTF-8", utf8, size: 10))\"", top: "multipart/signed; protocol=\"application/pkcs7-signature\"; boundary=\"XX\""), expectFix: false),
]

func runTests() -> Int32 {
    var failures = 0
    for c in cases {
        let result = MIMEFilenameRepair.repair(c.data)
        var ok = (result != nil) == c.expectFix
        var detail = ""
        if let result {
            let out = String(data: result.data, encoding: .isoLatin1)!
            ok = ok && out.contains("*=UTF-8''\(pct)") && result.fixes.allSatisfy { $0.repaired == name && $0.partID == "2" }
            ok = ok && MIMEFilenameRepair.repair(result.data) == nil  // 두 번 고치지 않음
            ok = ok && out.contains("--XX\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nhello\r\n")
            detail = result.fixes.map { "\($0.broken) → \($0.repaired)" }.joined(separator: ", ")
        }
        if !ok { failures += 1 }
        print("\(ok ? "✅" : "❌") \(c.title)  \(detail)")
    }
    failures += runOutgoingTests()
    print(failures == 0 ? "\n모두 통과 (\(cases.count + outgoingCases.count)건)" : "\n실패 \(failures)건")
    return failures == 0 ? 0 : 1
}

// MARK: - 보내는 메일 NFC 정규화

let outgoingName = "한글첨부테스트_NFD.txt"
let nfd = outgoingName.decomposedStringWithCanonicalMapping

/// Apple Mail이 실제로 보낸 형태
func appleMailPart(_ fileName: String) -> String {
    let words = chunks(Array(fileName.utf8), 45).map { "=?utf-8?B?\(Data($0).base64EncodedString())?=" }.joined(separator: "\r\n ")
    return "Content-Disposition: attachment;\r\n\tfilename*=utf-8''\(MIMEFilenameRepair.percentEncode(fileName))\r\n"
        + "Content-Type: text/plain;\r\n\tx-unix-mode=0644;\r\n\tname=\"\(words)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n7J20Cg==\r\n"
}

func outgoing(_ fileName: String, top: String = "multipart/mixed;\r\n\tboundary=\"XX\"") -> Data {
    var m = "From: a@example.com\r\nContent-Type: \(top)\r\nMime-Version: 1.0\r\n\r\n\r\n"
    m += "--XX\r\nContent-Type: text/plain;\r\n\tcharset=utf-8\r\n\r\nhello\r\n"
    m += "--XX\r\n\(appleMailPart(fileName))--XX--\r\n"
    return Data(m.utf8)
}

let outgoingCases: [Case] = [
    Case(title: "보내기: NFD 이름 → NFC", data: outgoing(nfd), expectFix: true),
    Case(title: "보내기: 이미 NFC", data: outgoing(outgoingName), expectFix: false),
    Case(title: "보내기: ASCII 이름", data: outgoing("manual.pdf"), expectFix: false),
    Case(title: "보내기: 서명 메일은 건드리지 않음", data: outgoing(nfd, top: "multipart/signed; protocol=\"application/pkcs7-signature\"; boundary=\"XX\""), expectFix: false),
]

func runOutgoingTests() -> Int {
    var failures = 0
    for c in outgoingCases {
        let result = MIMEFilenameRepair.normalizeOutgoing(c.data)
        var ok = (result != nil) == c.expectFix
        var detail = ""
        if let result {
            let out = String(decoding: result.data, as: UTF8.self)
            ok = ok && result.fixes.count == 2 && result.fixes.allSatisfy { $0.repaired.utf8.elementsEqual(outgoingName.utf8) && $0.partID == "2" }
            ok = ok && out.contains("filename*=UTF-8''\(MIMEFilenameRepair.percentEncode(outgoingName))\r\n")
            ok = ok && out.contains("name=\"\(MIMEFilenameRepair.encodedWords(outgoingName, newline: "\r\n"))\"\r\n")
            ok = ok && out.contains("\tx-unix-mode=0644;") && out.contains("\r\n\r\n7J20Cg==\r\n")
            ok = ok && !out.contains("%E1%84")
            ok = ok && MIMEFilenameRepair.normalizeOutgoing(result.data) == nil  // 두 번 고치지 않음
            ok = ok && MIMEFilenameRepair.repair(result.data) == nil  // 받는 쪽 보정 대상도 아님
            detail = result.fixes.map { "\($0.parameter): \($0.broken.unicodeScalars.count)자 → \($0.repaired.unicodeScalars.count)자" }.joined(separator: ", ")
        }
        if !ok { failures += 1 }
        print("\(ok ? "✅" : "❌") \(c.title)  \(detail)")
    }
    return failures
}

func messageData(_ url: URL) -> Data? {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
    return url.pathExtension == "emlx" ? EMLX(data)?.message : data
}

func scan(_ root: URL) {
    var total = 0, broken = 0
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
        guard url.pathExtension == "emlx" || url.pathExtension == "eml", let msg = messageData(url) else { continue }
        total += 1
        guard let result = MIMEFilenameRepair.repair(msg) else { continue }
        broken += 1
        for fix in result.attachmentFixes {
            print("\(url.path)\n   [\(fix.partID)] \(fix.broken)  →  \(fix.repaired)")
        }
    }
    print("\n검사 \(total)개, 보정 대상 \(broken)개")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "test" {
case "scan" where args.count > 2:
    scan(URL(fileURLWithPath: args[2]))
case "show" where args.count > 2:
    let url = URL(fileURLWithPath: args[2])
    if let msg = messageData(url), let result = MIMEFilenameRepair.repair(msg) {
        print(String(data: result.data, encoding: .isoLatin1)!)
    } else {
        print("고칠 것 없음")
    }
default:
    exit(runTests())
}
