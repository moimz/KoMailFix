import MailKit

class MailExtension: NSObject, MEExtension {
    func handlerForMessageSecurity() -> MEMessageSecurityHandler {
        MessageSecurityHandler.shared
    }
}
