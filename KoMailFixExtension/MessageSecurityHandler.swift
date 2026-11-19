import MailKit
import os

/// Mail이 메시지를 표시하기 전에 원문을 넘겨주는 "보안 핸들러" 자리를 빌려,
/// 깨진 첨부파일 이름만 고친 원문을 돌려준다. 서명·암호화는 하지 않는다.
class MessageSecurityHandler: NSObject, MEMessageSecurityHandler {

    static let shared = MessageSecurityHandler()

    private let log = Logger(subsystem: "com.moimz.KoMailFix", category: "decode")

    // MARK: - 보내는 메일: 첨부파일 이름만 NFC로

    func getEncodingStatus(for message: MEMessage, composeContext: MEComposeContext, completionHandler: @escaping (MEOutgoingMessageEncodingStatus) -> Void) {
        // canSign이 false이면 Mail이 encode를 부르지 않는다. 서명할 수 있다고 알려야 작성 창의 서명 옵션이
        // 켜진 채로 encode가 불린다. 실제 서명은 하지 않고 isSigned: false로 돌려준다.
        completionHandler(MEOutgoingMessageEncodingStatus(canSign: true, canEncrypt: false, securityError: nil, addressesFailingEncryption: []))
    }

    func encode(_ message: MEMessage, composeContext: MEComposeContext, completionHandler: @escaping (MEMessageEncodingResult) -> Void) {
        guard let data = message.rawData, let result = MIMEFilenameRepair.normalizeOutgoing(data) else {
            completionHandler(MEMessageEncodingResult(encodedMessage: nil, signingError: nil, encryptionError: nil))
            return
        }
        for fix in result.attachmentFixes {
            log.info("보내는 첨부파일 이름 NFC [\(fix.partID, privacy: .public)] → \(fix.repaired, privacy: .private)")
        }
        let encoded = MEEncodedOutgoingMessage(rawData: result.data, isSigned: false, isEncrypted: false)
        completionHandler(MEMessageEncodingResult(encodedMessage: encoded, signingError: nil, encryptionError: nil))
    }

    // MARK: - 받은 메일

    func decodedMessage(forMessageData data: Data) -> MEDecodedMessage? {
        guard let result = MIMEFilenameRepair.repair(data) else { return nil }
        for fix in result.attachmentFixes {
            log.info("첨부파일 이름 보정 [\(fix.partID, privacy: .public)] → \(fix.repaired, privacy: .private)")
        }
        let info = MEMessageSecurityInformation(signers: [], isEncrypted: false, signingError: nil, encryptionError: nil)
        return MEDecodedMessage(data: result.data, securityInformation: info, context: nil)
    }

    // MARK: - 보안 정보 화면: 없음

    func extensionViewController(signers messageSigners: [MEMessageSigner]) -> MEExtensionViewController? {
        nil
    }

    func extensionViewController(messageContext context: Data) -> MEExtensionViewController? {
        nil
    }

    func primaryActionClicked(forMessageContext context: Data, completionHandler: @escaping (MEExtensionViewController?) -> Void) {
        completionHandler(nil)
    }
}
