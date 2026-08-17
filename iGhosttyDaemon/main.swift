import Darwin
import Dispatch
import Foundation

// A dying shell must not take the daemon with it.
signal(SIGPIPE, SIG_IGN)
signal(SIGCHLD, SIG_IGN)

autoreleasepool {
    do {
        let server = DaemonServer()
        try server.start()
        withExtendedLifetime(server) {
            dispatchMain()
        }
    } catch {
        exit(EXIT_FAILURE)
    }
}
