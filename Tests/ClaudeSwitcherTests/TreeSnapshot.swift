import CryptoKit
import Darwin
import Foundation

/// Everything under a directory, as `lstat` sees it: path, type, mode, owner, device, inode,
/// link count, size, modification time, the SHA-256 of every regular file and the target of
/// every link. Two equal snapshots mean nothing under the root was created, removed, replaced,
/// re-permissioned or rewritten — the "changes nothing" in a test.
struct TreeSnapshot: Equatable {

    struct Entry: Equatable, CustomStringConvertible {
        let path: String
        let type: String
        let mode: UInt16
        let owner: UInt32
        let device: Int32
        let inode: UInt64
        let linkCount: Int
        let size: Int64
        let modified: Int64
        let sha256: String?
        let linkTarget: String?

        var description: String {
            "\(path) \(type) \(String(mode, radix: 8)) uid=\(owner) ino=\(inode) nlink=\(linkCount) size=\(size) "
                + "mtime=\(modified) \(sha256.map { String($0.prefix(12)) } ?? "-") \(linkTarget.map { "-> " + $0 } ?? "")"
        }

        func withoutTime() -> Entry {
            Entry(path: path, type: type, mode: mode, owner: owner, device: device, inode: inode,
                  linkCount: linkCount, size: size, modified: 0, sha256: sha256, linkTarget: linkTarget)
        }
    }

    let entries: [Entry]

    init(of root: URL) {
        var entries: [Entry] = []
        Self.visit(root.path, relative: "", into: &entries)
        self.entries = entries.sorted { $0.path < $1.path }
    }

    private init(entries: [Entry]) { self.entries = entries }

    var paths: [String] { entries.map(\.path) }

    func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    /// The same snapshot with directory modification times zeroed — for comparisons across
    /// an operation that creates and then removes its own entries.
    var ignoringDirectoryTimes: TreeSnapshot {
        TreeSnapshot(entries: entries.map { $0.type == "dir" ? $0.withoutTime() : $0 })
    }

    /// What was added, removed and changed since `before`. A folder counts as changed only if
    /// it was replaced or re-permissioned: its size, link count and time move with its entries.
    struct Changes: Equatable {
        var added: Set<String> = []
        var removed: Set<String> = []
        var changed: Set<String> = []
    }

    func changes(since before: TreeSnapshot) -> Changes {
        let old = Dictionary(uniqueKeysWithValues: before.entries.map { ($0.path, $0) })
        let new = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        var changes = Changes()
        for path in Set(old.keys).union(new.keys) {
            switch (old[path], new[path]) {
            case (nil, _?): changes.added.insert(path)
            case (_?, nil): changes.removed.insert(path)
            case (let a?, let b?):
                if a.type == "dir" && b.type == "dir" {
                    if (a.mode, a.owner, a.device, a.inode) != (b.mode, b.owner, b.device, b.inode) { changes.changed.insert(path) }
                } else if a != b {
                    changes.changed.insert(path)
                }
            default: break
            }
        }
        return changes
    }

    /// The same snapshot without the entries at or below `path`.
    func excluding(_ path: String) -> TreeSnapshot {
        TreeSnapshot(entries: entries.filter { $0.path != path && !$0.path.hasPrefix(path + "/") })
    }

    /// A readable account of what differs, for assertion messages.
    func difference(from before: TreeSnapshot) -> String {
        let old = Dictionary(uniqueKeysWithValues: before.entries.map { ($0.path, $0) })
        let new = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        var lines: [String] = []
        for path in Set(old.keys).union(new.keys).sorted() {
            switch (old[path], new[path]) {
            case (nil, let added?): lines.append("+ \(added)")
            case (let removed?, nil): lines.append("- \(removed)")
            case (let a?, let b?) where a != b: lines.append("~ \(a)\n  \(b)")
            default: break
            }
        }
        return lines.isEmpty ? "(no difference)" : lines.joined(separator: "\n")
    }

    private static func visit(_ absolute: String, relative: String, into entries: inout [Entry]) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: absolute)
        } catch {
            entries.append(Entry(path: relative + "/<unreadable>", type: "unreadable", mode: 0, owner: 0, device: 0,
                                 inode: 0, linkCount: 0, size: 0, modified: 0, sha256: nil, linkTarget: nil))
            return
        }
        for name in names {
            let path = absolute + "/" + name
            let rel = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let type: String
            var hash: String?
            var target: String?
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                type = "file"
                if let data = FileManager.default.contents(atPath: path) {
                    hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                } else {
                    hash = "unreadable"
                }
            case S_IFDIR: type = "dir"
            case S_IFLNK:
                type = "link"
                target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            case S_IFIFO: type = "fifo"
            default: type = "other"
            }
            entries.append(Entry(
                path: rel, type: type, mode: info.st_mode & 0o7777, owner: info.st_uid, device: info.st_dev,
                inode: info.st_ino, linkCount: Int(info.st_nlink), size: info.st_size,
                modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                sha256: hash, linkTarget: target))
            if type == "dir" { visit(path, relative: rel, into: &entries) }
        }
    }
}
