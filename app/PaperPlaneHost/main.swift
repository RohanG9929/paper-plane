import Foundation
import PaperPlaneCore

// Chrome and Brave start this for each message from the extension (spec §5.2): one framed
// request on stdin, relayed to the app's socket, and the app's framed reply on stdout. Only the
// Paper Plane extension may start it (its manifest's allowed_origins), and only this user can
// reach the socket.
let reply: Data
if let request = HostRelay.readRequest(from: .standardInput) {
    let helper = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    reply = HostRelay.relay(request, socket: BridgeServer.standardSocket, startApp: {
        if let app = HostRelay.app(containing: helper.resolvingSymlinksInPath()) {
            HostRelay.open(app)
        }
    })
} else {
    reply = PlayReply.failed("Paper Plane couldn't read the request.").encoded()
}
FileHandle.standardOutput.write(NativeMessaging.frame(reply))
