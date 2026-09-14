import Darwin
import Foundation

/// Reads a process's full `argv` straight from the kernel.
///
/// We deliberately go through `sysctl(KERN_PROCARGS2)` rather than shelling out to `ps`:
/// the kernel hands back NUL-separated strings, so an argument that contains spaces —
/// e.g. `--user-data-dir=/Users/me/Library/Application Support/Claude-Work` — survives
/// intact. Any text-based approach would have to guess where one argument ends and the
/// next begins, and would split that path into three.
public enum ProcessArgs {

    /// The full argument vector of `pid`, including `argv[0]`.
    ///
    /// Returns `nil` on any failure (process gone, owned by another user, sysctl refused,
    /// truncated or malformed buffer). Never traps.
    ///
    /// - Important: failure is `nil`, never `[]`. Callers use the absence of a
    ///   `--user-data-dir` argument to mean "this is the default profile", so an
    ///   *unreadable* argv must not be reported as an empty one — otherwise any process we
    ///   lack permission to inspect would be silently attributed to the default account.
    public static func arguments(forPID pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }

        // --- sysctl call 1: how much room do arguments need? ---
        let capacity = argumentBufferSize(pid: pid)
        guard capacity > MemoryLayout<Int32>.size else { return nil }

        // --- sysctl call 2: fetch the argument space itself. ---
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: capacity)
        var size = capacity
        let status = sysctl(&mib, 3, &buffer, &size, nil, 0)

        // `size` is updated to the number of bytes actually written; everything past it
        // is stale zero-fill from our own allocation and must not be parsed.
        guard status == 0, size > MemoryLayout<Int32>.size, size <= capacity else { return nil }

        return parse(buffer, count: size)
    }

    /// Parses a raw `KERN_PROCARGS2` payload. Exposed so the unsafe parsing rules can be
    /// tested against synthetic buffers without needing a live process.
    public static func parseArgumentBuffer(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count > MemoryLayout<Int32>.size else { return nil }
        return parse(buffer, count: buffer.count)
    }

    // MARK: - Buffer layout
    //
    // KERN_PROCARGS2 returns:
    //   [ int32 argc ][ exec_path NUL ][ zero padding ][ argv[0] NUL ] ... [ argv[argc-1] NUL ][ envp ... ]
    //
    // The zero padding between the executable path and argv[0] is alignment slop of
    // unspecified length, so it has to be skipped by scanning rather than by arithmetic.
    private static func parse(_ buffer: [UInt8], count: Int) -> [String]? {
        let argc = buffer.withUnsafeBytes { raw -> Int32 in
            raw.loadUnaligned(fromByteOffset: 0, as: Int32.self)
        }
        // An argument can never be shorter than its own NUL terminator, so `count` is a
        // hard upper bound on argc. This also rejects negative/garbage argc values.
        guard argc > 0, Int(argc) <= count else { return nil }

        var index = MemoryLayout<Int32>.size

        // Skip the executable path.
        while index < count, buffer[index] != 0 { index += 1 }
        guard index < count else { return nil }

        // Skip the NUL padding that follows it; this lands us on argv[0].
        while index < count, buffer[index] == 0 { index += 1 }
        guard index < count else { return nil }

        let wanted = Int(argc)
        var arguments: [String] = []
        arguments.reserveCapacity(wanted)

        var start = index
        while index < count, arguments.count < wanted {
            if buffer[index] == 0 {
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }

        // A buffer that ended before the final NUL means the kernel handed us a truncated
        // argv. Fabricating a last argument out of the remaining bytes would invent a value
        // that was never on the command line — and this vector decides which account an
        // instance belongs to. Report the read as failed instead.
        guard arguments.count == wanted else { return nil }

        return arguments
    }

    // MARK: - Sizing

    /// Upper bound on the argument space, via `kern.argmax`, with fallbacks.
    private static func argumentBufferSize(pid: pid_t) -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 {
            return Int(argmax)
        }

        // Fallback: ask KERN_PROCARGS2 itself for the required length.
        var probeMib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var needed = 0
        if sysctl(&probeMib, 3, nil, &needed, nil, 0) == 0, needed > 0 {
            return needed
        }

        // Last resort: the historical kern.argmax default.
        return 256 * 1024
    }
}
