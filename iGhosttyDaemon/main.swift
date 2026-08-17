import Darwin
import Dispatch
import Foundation

// A dying shell must not take the daemon with it.
signal(SIGPIPE, SIG_IGN)
// SIGCHLD stays at default on purpose. SIG_IGN makes the kernel auto-reap
// children, and a `waitpid` racing that auto-reap can block forever — which
// froze the whole control queue (listener included) the first time a close's
// grace-kill path waited on a SIGKILLed shell. PTYSession reaps its own
// children with WNOHANG, so nothing here needs the auto-reap.
signal(SIGCHLD, SIG_DFL)

autoreleasepool {
    let server = DaemonServer()
    // An upgrade can briefly leave the outgoing instance holding the mach
    // service; failing instantly here turns that window into a KeepAlive
    // crash loop that launchd then throttles, and the app sees nothing but
    // "connection lost". A few paced retries ride the handover out instead.
    var started = false
    for attempt in 1 ... 10 {
        do {
            try server.start()
            started = true
            break
        } catch {
            DaemonFileLog.log("listener bootstrap attempt \(attempt) failed, retrying")
            Thread.sleep(forTimeInterval: 1)
        }
    }
    guard started else {
        DaemonFileLog.log("listener bootstrap failed for good, exiting")
        exit(EXIT_FAILURE)
    }
    withExtendedLifetime(server) {
        dispatchMain()
    }
}
