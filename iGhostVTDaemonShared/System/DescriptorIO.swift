import Darwin

/// Writes the whole buffer, retrying short writes and EINTR. Returns false
/// on any other error (EAGAIN on a full PTY, a closed log), leaving the
/// caller to decide whether a dropped tail matters.
func writeFully(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer) -> Bool {
    guard var pointer = buffer.baseAddress else { return true }
    var remaining = buffer.count
    while remaining > 0 {
        let written = Darwin.write(descriptor, pointer, remaining)
        if written > 0 {
            pointer += written
            remaining -= written
            continue
        }
        if written < 0, errno == EINTR {
            continue
        }
        return false
    }
    return true
}
