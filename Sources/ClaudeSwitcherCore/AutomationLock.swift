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

    /// Takes the lock without waiting. Returns a descriptor to keep open for as long as the lock
    /// should be held, or `nil` when someone else holds it — or when it cannot be taken at all,
    /// which also means "do nothing automatic".
    public static func acquire(at url: URL = defaultURL) -> Int32? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    public static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
