import Darwin
import Dispatch
import Foundation
import XPC

// The proxy path: IOSupervisor in this process, the real `ighostvtd-io`
// binary as its child, talking over the real socket. Everything ighostvtd
// does on the device except listen on the mach service and authenticate —
// so a request forwarded, a reply matched, output routed to the right
// peer, a peer's departure detaching it, the flow control that keeps the
// proxy small, a crashed child replaced, and the shutdown exit followed.

/// A client as the supervisor sees it. Output is acknowledged as sent
/// immediately, unless the test wants a client that never reads.
final class HarnessPeer: IOPeer {
    let peerID: UInt64
    var acknowledgesOutput = true
    weak var supervisor: IOSupervisor?
    private let lock = NSLock()
    private var events: [xpc_object_t] = []
    private(set) var cutReason: String?

    init(peerID: UInt64) {
        self.peerID = peerID
    }

    func deliver(event: xpc_object_t) {
        lock.lock()
        events.append(event)
        lock.unlock()
        guard xpc_dictionary_get_uint64(event, iGhostVTWireKey.event) == iGhostVTEvent.output.rawValue else {
            return
        }
        var length = 0
        guard xpc_dictionary_get_data(event, iGhostVTWireKey.data, &length) != nil, length > 0 else { return }
        supervisor?.willSend(length, to: peerID)
        if acknowledgesOutput {
            supervisor?.didSend(length, to: peerID)
        }
    }

    func cutConnection(reason: String) {
        lock.lock()
        cutReason = reason
        lock.unlock()
        supervisor?.peerGone(peerID)
    }

    var wasCut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cutReason != nil
    }

    /// Everything output so far for `sessionID`, as text.
    func output(of sessionID: UInt64) -> String {
        lock.lock()
        defer { lock.unlock() }
        var collected = Data()
        for event in events
            where xpc_dictionary_get_uint64(event, iGhostVTWireKey.event) == iGhostVTEvent.output.rawValue
            && xpc_dictionary_get_uint64(event, iGhostVTWireKey.sessionID) == sessionID
        {
            var length = 0
            if let bytes = xpc_dictionary_get_data(event, iGhostVTWireKey.data, &length) {
                collected.append(bytes.assumingMemoryBound(to: UInt8.self), count: length)
            }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    func outputByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        var total = 0
        for event in events
            where xpc_dictionary_get_uint64(event, iGhostVTWireKey.event) == iGhostVTEvent.output.rawValue
        {
            var length = 0
            _ = xpc_dictionary_get_data(event, iGhostVTWireKey.data, &length)
            total += length
        }
        return total
    }

    func exitCode(of sessionID: UInt64) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        for event in events
            where xpc_dictionary_get_uint64(event, iGhostVTWireKey.event) == iGhostVTEvent.sessionExit.rawValue
            && xpc_dictionary_get_uint64(event, iGhostVTWireKey.sessionID) == sessionID
        {
            return Int32(truncatingIfNeeded: xpc_dictionary_get_int64(event, iGhostVTWireKey.exitCode))
        }
        return nil
    }
}

func makeRequest(_ operation: iGhostVTOperation, _ fill: (xpc_object_t) -> Void = { _ in }) -> xpc_object_t {
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
    xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, operation.rawValue)
    fill(message)
    return message
}

/// Forwards a request the way PeerRelay does and waits for its reply.
func request(
    _ supervisor: IOSupervisor,
    from peer: HarnessPeer,
    _ operation: iGhostVTOperation,
    timeout: TimeInterval = 5,
    _ fill: (xpc_object_t) -> Void = { _ in }
) -> xpc_object_t? {
    let message = makeRequest(operation, fill)
    let done = DispatchSemaphore(value: 0)
    var reply: xpc_object_t?
    harnessQueue.async {
        supervisor.forward(from: peer, message: message, wantsReply: true) { result in
            reply = result
            done.signal()
        }
    }
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    return reply
}

func replyCode(_ reply: xpc_object_t?) -> iGhostVTReplyCode? {
    reply.flatMap { iGhostVTReplyCode(rawValue: xpc_dictionary_get_int64($0, iGhostVTWireKey.code)) }
}

/// The `listSessions` row for `sessionID` as `peer` sees it right now.
func listedRow(_ supervisor: IOSupervisor, from peer: HarnessPeer, sessionID: UInt64) -> xpc_object_t? {
    guard let listed = request(supervisor, from: peer, .listSessions),
          let sessions = xpc_dictionary_get_value(listed, iGhostVTWireKey.sessions)
    else { return nil }
    for index in 0 ..< xpc_array_get_count(sessions) {
        let row = xpc_array_get_value(sessions, index)
        if xpc_dictionary_get_uint64(row, iGhostVTWireKey.sessionID) == sessionID {
            return row
        }
    }
    return nil
}

/// A string field of a `listSessions` row. `xpc_dictionary_get_string`
/// hands back a pointer the dictionary owns, so the conversion happens
/// while the reply is still alive — reading it afterwards yields whatever
/// the freed allocation now holds.
func listedString(
    _ supervisor: IOSupervisor,
    from peer: HarnessPeer,
    sessionID: UInt64,
    _ key: String
) -> String? {
    guard let row = listedRow(supervisor, from: peer, sessionID: sessionID) else { return nil }
    return withExtendedLifetime(row) {
        xpc_dictionary_get_string(row, key).map { String(cString: $0) }
    }
}

func setInput(_ message: xpc_object_t, _ text: String) {
    let bytes = Array(text.utf8)
    bytes.withUnsafeBytes { xpc_dictionary_set_data(message, iGhostVTWireKey.data, $0.baseAddress!, $0.count) }
}

func dataText(_ reply: xpc_object_t?) -> String {
    var length = 0
    guard let bytes = reply.flatMap({ xpc_dictionary_get_data($0, iGhostVTWireKey.data, &length) }) else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
}

func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        usleep(50000)
    }
    return condition()
}

func runCodecTests() {
    print("wire codec")
    let original = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(original, "u", UInt64.max)
    xpc_dictionary_set_int64(original, "i", -42)
    xpc_dictionary_set_bool(original, "b", true)
    xpc_dictionary_set_string(original, "s", "héllo wörld")
    let bytes: [UInt8] = [0, 1, 2, 255, 0]
    bytes.withUnsafeBytes { xpc_dictionary_set_data(original, "d", $0.baseAddress!, $0.count) }
    let array = xpc_array_create(nil, 0)
    xpc_array_append_value(array, xpc_string_create("one"))
    let nested = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(nested, "n", 7)
    xpc_array_append_value(array, nested)
    xpc_dictionary_set_value(original, "a", array)
    let environment = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(environment, "TERM", "xterm-ghostty")
    xpc_dictionary_set_value(original, "env", environment)

    var encoded: [UInt8] = []
    check(IOCodec.encode(original, into: &encoded), "a protocol dictionary encodes")
    let decoded = encoded.withUnsafeBytes { IOCodec.decode($0) }
    check(decoded != nil, "the encoding decodes")
    if let decoded {
        check(xpc_dictionary_get_uint64(decoded, "u") == UInt64.max, "uint64 survives")
        check(xpc_dictionary_get_int64(decoded, "i") == -42, "int64 survives")
        check(xpc_dictionary_get_bool(decoded, "b"), "bool survives")
        check(
            xpc_dictionary_get_string(decoded, "s").map { String(cString: $0) } == "héllo wörld",
            "a non-ASCII string survives"
        )
        var length = 0
        let data = xpc_dictionary_get_data(decoded, "d", &length)
        check(
            length == 5 && data.map { Array(UnsafeRawBufferPointer(start: $0, count: 5)) } == bytes,
            "data with embedded NULs survives"
        )
        let decodedArray = xpc_dictionary_get_value(decoded, "a")
        check(
            decodedArray.map { xpc_array_get_count($0) } == 2
                && decodedArray.flatMap { xpc_array_get_string($0, 0) }.map { String(cString: $0) } == "one"
                && decodedArray.map { xpc_uint64_get_value(xpc_dictionary_get_value(xpc_array_get_value($0, 1), "n")!) } == 7,
            "an array of mixed values survives"
        )
        check(
            xpc_dictionary_get_value(decoded, "env").flatMap { xpc_dictionary_get_string($0, "TERM") }
                .map { String(cString: $0) } == "xterm-ghostty",
            "a nested dictionary survives"
        )
        check(xpc_dictionary_get_count(decoded) == 7, "no keys are invented or lost")
    }

    let truncated = Array(encoded.dropLast(3))
    check(truncated.withUnsafeBytes { IOCodec.decode($0) } == nil, "a truncated payload is refused")
    var overlong = encoded
    overlong.append(0)
    check(overlong.withUnsafeBytes { IOCodec.decode($0) } == nil, "trailing bytes are refused")

    let unsupported = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_fd(unsupported, "fd", STDIN_FILENO)
    var scratch: [UInt8] = []
    check(!IOCodec.encode(unsupported, into: &scratch), "a descriptor is not carried")

    var framed: [UInt8] = []
    IOWire.appendHeader(IOWire.Header(kind: .reply, peer: 9, tag: 12345, payloadByteCount: encoded.count), to: &framed)
    let header = framed.withUnsafeBytes { IOWire.decodeHeader($0) }
    check(
        header?.kind == .reply && header?.peer == 9 && header?.tag == 12345 && header?.payloadByteCount == encoded.count,
        "a frame header round-trips"
    )
    framed[4] = 200
    check(framed.withUnsafeBytes { IOWire.decodeHeader($0) } == nil, "an unknown frame kind is refused")
}

func runProxyLinkTests() {
    runCodecTests()

    print("proxy link")
    guard let ioBinary = ProcessInfo.processInfo.environment["IGHOSTVT_IO_BINARY"] else {
        check(false, "IGHOSTVT_IO_BINARY names the io binary")
        return
    }
    IOSupervisor.peerCongestionGrace = .seconds(2)
    let supervisor = IOSupervisor(queue: harnessQueue, executablePath: ioBinary)
    var shutdownFollowed = false
    supervisor.onShutdownExit = { shutdownFollowed = true }
    var spawned = false
    harnessQueue.sync {
        do {
            try supervisor.start()
            spawned = true
        } catch {
            spawned = false
        }
    }
    check(spawned, "the supervisor spawns ighostvtd-io")
    guard spawned else { return }
    let firstChild = supervisor.childProcessID
    check(firstChild > 0, "the child has a pid")
    check(kill(firstChild, 0) == 0, "the child is running")

    let peer = HarnessPeer(peerID: 1)
    peer.supervisor = supervisor
    harnessQueue.sync { supervisor.register(peer) }

    check(
        replyCode(request(supervisor, from: peer, .openSession)) == .handshakeRequired,
        "a request before hello is refused by io, through the proxy"
    )
    check(replyCode(request(supervisor, from: peer, .hello)) == .success, "hello is forwarded and answered")

    let opened = request(supervisor, from: peer, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "echo hello-from-io; exec cat"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.columns, 80)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.rows, 24)
    }
    check(replyCode(opened) == .success, "a session opens through the proxy (\(String(describing: opened)))")
    let sessionID = opened.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(sessionID > 0, "the reply names the session")
    check(
        opened.flatMap { xpc_dictionary_get_string($0, iGhostVTWireKey.processName) }.map { String(cString: $0) } == "sh",
        "the reply states the foreground process"
    )
    check(
        waitUntil { peer.output(of: sessionID).contains("hello-from-io") },
        "output reaches the peer that opened the session"
    )

    // A write the app sends without expecting a reply: no tag, no reply.
    harnessQueue.async {
        let message = makeRequest(.write) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
            let bytes = Array("ping-through-proxy\n".utf8)
            bytes.withUnsafeBytes { xpc_dictionary_set_data(message, iGhostVTWireKey.data, $0.baseAddress!, $0.count) }
        }
        supervisor.forward(from: peer, message: message, wantsReply: false) { _ in
            check(false, "a request without a reply never completes")
        }
    }
    check(
        waitUntil { peer.output(of: sessionID).contains("ping-through-proxy") },
        "input written through the proxy comes back out"
    )

    // A paste: more than one chunk, sent back to back without waiting for
    // anything, the way the app sends one. It has to come out the far end
    // whole and in order — the proxy forwards frames as it reads them, and
    // the session queues them in that order — and none of it may be lost to
    // a PTY master that only takes about a kilobyte at a time.
    //
    // Its own session, in raw mode: a canonical-mode terminal has a line
    // length of its own and would hold a chunk with no newline in it, which
    // is the kernel's business and not this test's.
    print("proxy chunked paste")
    let pasteOpened = request(supervisor, from: peer, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "stty raw -echo; exec cat"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let pasteID = pasteOpened.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(pasteOpened) == .success && pasteID > 0, "a session for the paste opens")
    // Let `stty` run before anything is typed at it.
    Thread.sleep(forTimeInterval: 0.5)
    let pasteChunk = String(repeating: "0123456789abcdef", count: 1024) // 16 KiB
    let pasteChunkCount = 3
    harnessQueue.async {
        for index in 0 ..< pasteChunkCount {
            let message = makeRequest(.write) { message in
                xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, pasteID)
                setInput(message, "<\(index)>" + pasteChunk)
            }
            supervisor.forward(from: peer, message: message, wantsReply: false) { _ in }
        }
        let terminator = makeRequest(.write) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, pasteID)
            setInput(message, "paste-end")
        }
        supervisor.forward(from: peer, message: terminator, wantsReply: false) { _ in }
    }
    check(
        waitUntil(20) { peer.output(of: pasteID).contains("paste-end") },
        "a multi-chunk paste reaches the end of the session's input"
    )
    let pasted = peer.output(of: pasteID)
    let arrived = pasted.components(separatedBy: pasteChunk).count - 1
    check(
        arrived == pasteChunkCount,
        "every chunk of it arrived whole (\(arrived) of \(pasteChunkCount))"
    )
    check(
        pasted.count == pasteChunkCount * (pasteChunk.count + 3) + "paste-end".count,
        "with nothing added or lost around them (\(pasted.count) characters)"
    )
    check(
        (0 ..< pasteChunkCount).allSatisfy { index in
            guard let marker = pasted.range(of: "<\(index)>"),
                  let end = pasted.range(of: "paste-end") else { return false }
            guard index > 0 else { return marker.lowerBound < end.lowerBound }
            guard let previous = pasted.range(of: "<\(index - 1)>") else { return false }
            return previous.lowerBound < marker.lowerBound && marker.lowerBound < end.lowerBound
        },
        "and in the order it was sent"
    )
    check(
        replyCode(request(supervisor, from: peer, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, pasteID)
        }) == .success,
        "the paste session closes"
    )
    _ = waitUntil { listedRow(supervisor, from: peer, sessionID: pasteID) == nil }

    let listed = request(supervisor, from: peer, .listSessions)
    let sessions = listed.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }
    check(sessions.map { xpc_array_get_count($0) } == 1, "listSessions sees the one session")
    check(
        sessions.map { xpc_dictionary_get_bool(xpc_array_get_value($0, 0), iGhostVTWireKey.isAttached) } == true,
        "and reports it attached"
    )

    let second = HarnessPeer(peerID: 2)
    second.supervisor = supervisor
    harnessQueue.sync { supervisor.register(second) }
    check(replyCode(request(supervisor, from: second, .hello)) == .success, "a second peer says hello")
    check(
        replyCode(request(supervisor, from: second, .attachSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }) == .sessionBusy,
        "a session attached elsewhere is busy"
    )

    // The CLI's requests hold nothing: a snapshot reads the replay and
    // injected input reaches the PTY while the first peer keeps the session.
    print("proxy snapshot and inject")
    // The foreground-name poll runs every 500 ms, so wait for it to settle
    // on `cat` (through the list) before asserting the snapshot names it.
    _ = waitUntil {
        listedRow(supervisor, from: second, sessionID: sessionID).map {
            xpc_dictionary_get_string($0, iGhostVTWireKey.processName).map { String(cString: $0) } == "cat"
        } == true
    }
    let snapshot = request(supervisor, from: second, .snapshotSession) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
    }
    check(replyCode(snapshot) == .success, "a snapshot needs no attachment")
    let snapshotText = dataText(snapshot)
    check(
        snapshotText.contains("hello-from-io") && snapshotText.contains("ping-through-proxy"),
        "the snapshot carries the replay"
    )
    check(
        snapshot.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.columns) } == 80
            && snapshot.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.rows) } == 24,
        "the snapshot states the size"
    )
    check(
        snapshot.flatMap { xpc_dictionary_get_string($0, iGhostVTWireKey.processName) }.map { String(cString: $0) } == "cat",
        "the snapshot states the foreground process"
    )
    check(
        listedRow(supervisor, from: second, sessionID: sessionID)
            .map { xpc_dictionary_get_bool($0, iGhostVTWireKey.isAttached) } == true,
        "the snapshot left the session attached to its peer"
    )
    check(
        replyCode(request(supervisor, from: second, .injectInput) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
            setInput($0, "from-second\n")
        }) == .success,
        "injected input needs no attachment"
    )
    check(waitUntil { peer.output(of: sessionID).contains("from-second") }, "injected input reaches the attached peer")
    check(!second.output(of: sessionID).contains("from-second"), "and nothing comes back to the peer that injected it")
    check(
        replyCode(request(supervisor, from: second, .injectInput) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }) == .invalidRequest,
        "injected input without data is refused"
    )
    check(
        replyCode(request(supervisor, from: second, .snapshotSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, 999)
        }) == .unknownSession,
        "a snapshot of an unknown session is refused"
    )
    check(
        replyCode(request(supervisor, from: second, .injectInput) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, 999)
            setInput($0, "x")
        }) == .unknownSession,
        "input into an unknown session is refused"
    )
    check(
        waitUntil {
            listedRow(supervisor, from: second, sessionID: sessionID).map {
                xpc_dictionary_get_string($0, iGhostVTWireKey.processName).map { String(cString: $0) } == "cat"
                    && xpc_dictionary_get_bool($0, iGhostVTWireKey.foregroundIsShell)
            } == true
        },
        "a listed row names the foreground process"
    )
    let listedDirectory = listedString(
        supervisor,
        from: second,
        sessionID: sessionID,
        iGhostVTWireKey.currentDirectory
    )
    check(
        listedDirectory?.hasPrefix("/") == true,
        "a listed row states the shell's directory (got \(listedDirectory ?? "nil"))"
    )
    let placed = request(supervisor, from: second, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "cd /private/tmp && exec cat"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let placedID = placed.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(placed) == .success && placedID > 0, "a session opens in a chosen directory")
    check(
        waitUntil {
            listedString(supervisor, from: second, sessionID: placedID, iGhostVTWireKey.currentDirectory)
                == "/private/tmp"
        },
        "and its row states that directory as the kernel spells it"
    )
    check(
        replyCode(request(supervisor, from: second, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, placedID)
        }) == .success,
        "the placed session closes"
    )
    check(
        waitUntil { listedRow(supervisor, from: second, sessionID: placedID) == nil },
        "and leaves the list"
    )

    // The first peer's connection drops: its sessions are detached, not
    // killed, and its replay is what the next peer gets.
    harnessQueue.sync { supervisor.peerGone(1) }
    let attached = request(supervisor, from: second, .attachSession) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
    }
    check(replyCode(attached) == .success, "after the peer is gone the session attaches elsewhere")
    var replayLength = 0
    let replay = attached.flatMap { xpc_dictionary_get_data($0, iGhostVTWireKey.data, &replayLength) }
    let replayText = replay.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: replayLength), as: UTF8.self) } ?? ""
    check(replayText.contains("hello-from-io") && replayText.contains("ping-through-proxy"), "the attach reply replays the buffer")
    harnessQueue.async {
        let message = makeRequest(.write) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
            let bytes = Array("second-peer\n".utf8)
            bytes.withUnsafeBytes { xpc_dictionary_set_data(message, iGhostVTWireKey.data, $0.baseAddress!, $0.count) }
        }
        supervisor.forward(from: second, message: message, wantsReply: false) { _ in }
    }
    check(
        waitUntil { second.output(of: sessionID).contains("second-peer") },
        "output now goes to the attached peer"
    )
    check(!peer.output(of: sessionID).contains("second-peer"), "and not to the departed one")

    check(
        replyCode(request(supervisor, from: second, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }) == .success,
        "closeSession is forwarded"
    )
    check(waitUntil { second.exitCode(of: sessionID) != nil }, "the exit event reaches the attached peer")
    check(
        waitUntil {
            let listed = request(supervisor, from: second, .listSessions)
            return listed.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }.map { xpc_array_get_count($0) } == 0
        },
        "the closed session leaves the list"
    )

    // Flow control. A client that never reads: the proxy must stop taking
    // output, so what it holds stays bounded, then cut the peer.
    print("proxy flow control")
    let stuck = HarnessPeer(peerID: 3)
    stuck.supervisor = supervisor
    stuck.acknowledgesOutput = false
    harnessQueue.sync { supervisor.register(stuck) }
    check(replyCode(request(supervisor, from: stuck, .hello)) == .success, "a stuck peer says hello")
    // Enough to overrun the in-flight cap several times (so the pause and
    // the peer-cut both fire), then a sentinel, then a sleep that keeps the
    // shell alive so its exit does not race the assertions. Kept small on
    // purpose: the point is that the shell reaches its end once someone
    // reads, not how fast a slow runner can move fifty megabytes.
    let flood = request(supervisor, from: stuck, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "yes | head -c 3000000; echo flood-done; sleep 30"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let floodID = flood.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(flood) == .success && floodID > 0, "a flooding session opens")
    _ = waitUntil(3) { stuck.outputByteCount() >= IOSupervisor.pauseAboveByteCount }
    let delivered = stuck.outputByteCount()
    check(
        delivered >= IOSupervisor.pauseAboveByteCount,
        "output flows until the in-flight cap (\(delivered) bytes)"
    )
    usleep(500_000)
    let afterPause = stuck.outputByteCount()
    check(
        afterPause - delivered < IOSupervisor.pauseAboveByteCount,
        "past the cap the proxy stops taking output (\(afterPause - delivered) more bytes)"
    )
    check(waitUntil(6) { stuck.wasCut }, "a peer that does not drain is cut (\(stuck.cutReason ?? "not cut"))")
    // The cut peer's session lives on, detached, and its shell keeps
    // running into the replay buffer instead of blocking.
    let observer = HarnessPeer(peerID: 4)
    observer.supervisor = supervisor
    harnessQueue.sync { supervisor.register(observer) }
    check(replyCode(request(supervisor, from: observer, .hello)) == .success, "an observer says hello")
    let reattached = request(supervisor, from: observer, .attachSession, timeout: 10) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, floodID)
    }
    check(replyCode(reattached) == .success, "the flooding session survives its peer being cut")
    // The reattach reply's replay covers the tail already produced; the rest
    // arrives live now that a reader is draining. Either way the sentinel at
    // the shell's end reaches the observer, which is the proof the shell was
    // never blocked or killed by its first peer going away.
    let reattachReplay: String = {
        var length = 0
        guard let bytes = reattached.flatMap({ xpc_dictionary_get_data($0, iGhostVTWireKey.data, &length) }) else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
    }()
    check(
        waitUntil(15) {
            reattachReplay.contains("flood-done") || observer.output(of: floodID).contains("flood-done")
        },
        "the shell ran to completion while nobody was reading"
    )
    check(
        replyCode(request(supervisor, from: observer, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, floodID)
        }) == .success,
        "the flooding session closes"
    )
    _ = waitUntil {
        let listed = request(supervisor, from: observer, .listSessions)
        return listed.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }.map { xpc_array_get_count($0) } == 0
    }

    // The child dies: peers are cut, pending replies fail, a new child
    // comes up and serves.
    print("proxy child replacement")
    let bystander = HarnessPeer(peerID: 5)
    bystander.supervisor = supervisor
    harnessQueue.sync { supervisor.register(bystander) }
    check(replyCode(request(supervisor, from: bystander, .hello)) == .success, "a bystander says hello")
    kill(firstChild, SIGKILL)
    check(waitUntil { bystander.wasCut }, "a peer is cut when io dies (\(bystander.cutReason ?? "not cut"))")
    check(
        waitUntil(5) { supervisor.childProcessID > 0 && supervisor.childProcessID != firstChild },
        "a replacement io is spawned"
    )
    let replacement = HarnessPeer(peerID: 6)
    replacement.supervisor = supervisor
    harnessQueue.sync { supervisor.register(replacement) }
    check(
        waitUntil(5) { replyCode(request(supervisor, from: replacement, .hello, timeout: 1)) == .success },
        "the replacement answers"
    )
    let afterCrash = request(supervisor, from: replacement, .listSessions)
    check(
        afterCrash.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }.map { xpc_array_get_count($0) } == 0,
        "the replacement starts empty"
    )

    // Shutdown: refused while something is held, followed when nothing is.
    print("proxy shutdown")
    let held = request(supervisor, from: replacement, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "exec cat"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let heldID = held.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(held) == .success, "a session opens on the replacement")
    check(replyCode(request(supervisor, from: replacement, .shutdown)) == .sessionBusy, "shutdown with a session held is busy")
    check(
        replyCode(request(supervisor, from: replacement, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, heldID)
        }) == .success,
        "the held session closes"
    )
    _ = waitUntil {
        let listed = request(supervisor, from: replacement, .listSessions)
        return listed.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }.map { xpc_array_get_count($0) } == 0
    }
    let lastChild = supervisor.childProcessID
    check(replyCode(request(supervisor, from: replacement, .shutdown)) == .success, "shutdown with nothing held succeeds")
    check(waitUntil { shutdownFollowed }, "the proxy follows io's exit after shutdown")
    check(waitUntil { kill(lastChild, 0) != 0 || supervisor.childProcessID == 0 }, "io is gone after shutdown")
}
