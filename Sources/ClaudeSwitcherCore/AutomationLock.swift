import Darwin
import Foundation

/// Makes sure only one switcher process does anything on its own initiative.
///
/// The in-app launch slot serialises launchers *within* a process. A second switcher — a
/// `swift run` next to the installed app — would get the same notifications, sleep the same
/// sleeps, and both would pass the "is it running yet?" check before either launch registered:
/// two processes on one profile directory. An advisory lock on a file in the switcher's own
/// config directory settles who acts. It is released by the kernel when the holder exits.
public enum AutomationLock {

    public static var defaultURL: URL {
        Config.configURL.deletingLastPathComponent().appendingPathComponent("automation.lock")
    }

    /// What taking the lock came to.
    public enum Acquisition: Equatable, Sendable {
        /// Held: keep the descriptor open for as long as the lock should be held.
        case acquired(Int32)
        /// Another process holds it — another switcher is running.
        case heldElsewhere
        /// The lock file could not be opened or locked at all (`errno`): nobody holds it, but
        /// this process does not either.
        case unavailable(errno: Int32)
    }

    /// Takes the lock without waiting, and says why when it cannot.
    public static func take(at url: URL = defaultURL) -> Acquisition {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .unavailable(errno: errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            return code == EWOULDBLOCK ? .heldElsewhere : .unavailable(errno: code)
        }
        return .acquired(descriptor)
    }

    /// Takes the lock without waiting. Returns a descriptor to keep open for as long as the lock
    /// should be held, or `nil` when someone else holds it — or when it cannot be taken at all,
    /// which also means "do nothing automatic". ``take(at:)`` tells the two apart.
    public static func acquire(at url: URL = defaultURL) -> Int32? {
        if case .acquired(let descriptor) = take(at: url) { return descriptor }
        return nil
    }

    public static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
