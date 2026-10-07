import XCTest
@testable import ClaudeSwitcherCore

/// Download, verify, mount, copy and stage — section 7, run against `FakePrepare`. Nothing is
/// downloaded, mounted or copied: every effect is a recorded closure.
final class SwitcherPrepareTests: XCTestCase {

    private let trust = UpdateFixture.trust

    private func prepare(_ fake: FakePrepare, trust: SwitcherTrust? = nil) async -> Result<PreparedUpdate, Refusal> {
        await SwitcherUpdater.prepare(candidate: fake.candidate, trust: trust ?? self.trust,
                                      installPath: UpdateFixture.install, updatesDirectory: UpdateFixture.updates,
                                      env: fake.env)
    }

    private func refusal(_ result: Result<PreparedUpdate, Refusal>, file: StaticString = #filePath,
                         line: UInt = #line) -> Refusal? {
        switch result {
        case .success(let prepared):
            XCTFail("expected a refusal, prepared \(prepared.stagedAppPath)", file: file, line: line)
            return nil
        case .failure(let refusal):
            return refusal
        }
    }

    // MARK: - Order

    func testAPrepareRunsEveryStepInTheOrderOfSectionSeven() async throws {
        let fake = FakePrepare()
        let prepared = try await prepare(fake).get()

        XCTAssertEqual(fake.steps, PrepareStep.allCases)
        XCTAssertEqual(fake.steps, [.versionGate, .freeSpace, .download, .size, .digest, .imageSignature,
                                    .imageRequirement, .license, .attach, .layout, .mountedSignature,
                                    .mountedRequirement, .mountedIdentity, .copy, .detach, .quarantine,
                                    .stagedSignature, .stagedRequirement, .stagedIdentity, .assess, .prewarm, .volume])
        XCTAssertEqual(prepared.stagedAppPath, UpdateFixture.staged)
        XCTAssertEqual(prepared.dmgPath, fake.dmg)
        XCTAssertEqual(prepared.version, UpdateFixture.v080)
        XCTAssertEqual(fake.downloads, 1)
        XCTAssertEqual(fake.detached, [UpdateFixture.device])
        XCTAssertTrue(fake.stillAttached.isEmpty)
        XCTAssertEqual(fake.notes, [.staging(UpdateFixture.staging)])
        XCTAssertEqual(fake.quarantined, [UpdateFixture.staged])
        XCTAssertEqual(fake.removed, [fake.partial])
    }

    /// The image is detached right after the copy, before anything is done to the copy.
    func testTheImageIsDetachedAsSoonAsTheCopyIsMade() async throws {
        let fake = FakePrepare()
        _ = try await prepare(fake).get()
        let copy = try XCTUnwrap(fake.events.firstIndex { $0.hasPrefix("copy ") })
        let detach = try XCTUnwrap(fake.events.firstIndex { $0.hasPrefix("detach ") })
        let strip = try XCTUnwrap(fake.events.firstIndex { $0.hasPrefix("unquarantine ") })
        XCTAssertLessThan(copy, detach)
        XCTAssertLessThan(detach, strip)
    }

    func testTheRequirementsNameThisCopysTeamAndIdentifierAndNotarization() async throws {
        let fake = FakePrepare()
        _ = try await prepare(fake).get()
        let image = try XCTUnwrap(fake.requirements.first)
        XCTAssertTrue(image.contains(#"certificate leaf[subject.OU] = "FTHBLX7S63""#), image)
        XCTAssertTrue(image.hasSuffix(" and notarized"), image)
        XCTAssertFalse(image.contains("identifier"), "the disk image is signed under its own name: \(image)")
        for app in fake.requirements.dropFirst() {
            XCTAssertTrue(app.contains(#"identifier "tech.local.claude-switcher""#), app)
            XCTAssertTrue(app.contains(#"certificate leaf[subject.OU] = "FTHBLX7S63""#), app)
            XCTAssertTrue(app.hasPrefix("anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"), app)
            XCTAssertTrue(app.hasSuffix(" and notarized"), app)
        }
        XCTAssertEqual(fake.requirements.count, 3)
    }

    func testAnImageAlreadyDownloadedIsHashedAgainNotFetchedAgain() async throws {
        let fake = FakePrepare()
        fake.existingDMG = fake.candidate.assetSize
        _ = try await prepare(fake).get()
        XCTAssertEqual(fake.downloads, 0)
        XCTAssertEqual(fake.hashed, 1)
        XCTAssertFalse(fake.steps.contains(.download))
    }

    // MARK: - Before anything is fetched

    /// Never download what is not strictly newer: a replayed or older release stops here.
    func testAReleaseNotNewerThanTheRunningCopyIsNeverDownloaded() async {
        for version in [UpdateFixture.v070, UpdateFixture.v060] {
            let fake = FakePrepare(candidate: UpdateFixture.candidate(version))
            let refused = refusal(await prepare(fake))
            XCTAssertEqual(refused?.kind, .permanent)
            XCTAssertEqual(refused?.step, PrepareStep.versionGate.rawValue)
            XCTAssertEqual(fake.downloads, 0)
            XCTAssertEqual(fake.attaches, 0)
        }
    }

    func testNotEnoughFreeSpaceIsNotAnAttemptAndFetchesNothing() async {
        let fake = FakePrepare()
        fake.freeBytes = Int64(fake.candidate.assetSize) * 10 + 49_999_999
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .transient)
        XCTAssertEqual(refused?.reason, "not enough free space")
        XCTAssertEqual(refused?.countsAsAttempt, false)
        XCTAssertEqual(fake.downloads, 0)
    }

    /// The download's volume and the install's volume each need room of their own: one with
    /// plenty does not stand in for the other.
    func testEachVolumeNeedsItsOwnFreeSpace() async {
        for short in [UpdateFixture.updates, "/Applications"] {
            let fake = FakePrepare()
            fake.freeSpaceByPath = [short: Int64(fake.candidate.assetSize) * 10 + 49_999_999]
            let refused = refusal(await prepare(fake))
            XCTAssertEqual(refused?.reason, "not enough free space", short)
            XCTAssertEqual(refused?.countsAsAttempt, false, short)
            XCTAssertEqual(fake.downloads, 0, short)
        }
    }

    func testATransportErrorBeforeTheFirstByteIsPassedOnAsNotAnAttempt() async {
        let fake = FakePrepare()
        fake.downloadRefusal = .transient(.download, "offline", countsAsAttempt: false)
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.countsAsAttempt, false)
        XCTAssertEqual(fake.removed, [fake.partial, fake.partial])
        XCTAssertEqual(fake.attaches, 0)
    }

    func testAnUnexpectedRedirectHostIsPermanentAndKeepsNothing() async {
        let fake = FakePrepare()
        fake.downloadRefusal = .permanent(.download, "the download was sent to an unexpected host (evil.example)")
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .permanent)
        XCTAssertTrue(fake.removed.contains(fake.dmg))
        XCTAssertEqual(fake.attaches, 0)
    }

    // MARK: - Steps 1 to 5: nothing is attached that has not passed them

    func testASizeMismatchStopsBeforeHashing() async {
        let fake = FakePrepare()
        fake.downloadedBytes = fake.candidate.assetSize - 1
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .transient)
        XCTAssertEqual(refused?.step, PrepareStep.size.rawValue)
        XCTAssertEqual(fake.hashed, 0)
        XCTAssertEqual(fake.attaches, 0)
        XCTAssertEqual(fake.removed.last, fake.partial)
    }

    /// An image left from an earlier attempt with the wrong byte count is a broken download, not a
    /// bad release: it is removed unhashed and fetched again later — never rejected.
    func testAnImageAlreadyDownloadedWithTheWrongSizeIsNotHashedNorRejected() async {
        let fake = FakePrepare()
        fake.existingDMG = fake.candidate.assetSize - 1
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .transient)
        XCTAssertEqual(refused?.step, PrepareStep.size.rawValue)
        XCTAssertEqual(fake.hashed, 0)
        XCTAssertEqual(fake.attaches, 0)
        XCTAssertEqual(fake.removed, [fake.dmg])
    }

    func testADigestMismatchDeletesTheFileAndNeverAttaches() async {
        let fake = FakePrepare()
        fake.digestOnDisk = String(repeating: "00", count: 32)
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .permanent)
        XCTAssertEqual(refused?.step, PrepareStep.digest.rawValue)
        XCTAssertTrue(fake.removed.contains(fake.partial))
        XCTAssertTrue(fake.removed.contains(fake.dmg))
        XCTAssertEqual(fake.attaches, 0)
        XCTAssertEqual(fake.removedFolders, [UpdateFixture.updates + "/downloads/v0.8.0"],
                       "the folder that held only it goes too — rmdir, never recursive")
    }

    /// A release refused for what it is leaves no empty folder under downloads/, however far it got;
    /// one refused for the moment keeps its folder and its image for the next try.
    func testAPermanentRefusalLeavesNoEmptyDownloadFolder() async throws {
        let folder = UpdateFixture.updates + "/downloads/v0.8.0"
        let permanent: [(String, (FakePrepare) -> Void)] = [
            ("not newer", { $0.candidate = UpdateFixture.candidate(UpdateFixture.v060) }),
            ("image signature", { $0.signatureFailures["dmg+req"] = SignatureRefusal(status: -67050, message: "x") }),
            ("layout", { $0.mountEntries = [] }),
            ("spctl", { $0.verdict = .rejected("x") }),
        ]
        for (name, script) in permanent {
            let fake = FakePrepare()
            script(fake)
            let refused = refusal(await prepare(fake))
            XCTAssertEqual(refused?.kind, .permanent, name)
            XCTAssertTrue(fake.removedFolders.contains(fake.candidate.version == UpdateFixture.v060
                                                       ? UpdateFixture.updates + "/downloads/v0.6.0" : folder), name)
            let rmdir = fake.events.lastIndex { $0.hasPrefix("rmdir \(UpdateFixture.updates)/downloads/") }
            let image = fake.events.lastIndex(of: "remove \(fake.dmg)")
            XCTAssertLessThan(try XCTUnwrap(image, name), try XCTUnwrap(rmdir, name), "emptied first: \(name)")
        }
        let transient = FakePrepare()
        transient.verdict = .unavailable("spctl did not answer in time")
        _ = refusal(await prepare(transient))
        XCTAssertFalse(transient.removedFolders.contains(folder))
    }

    func testADigestMismatchOnAnImageAlreadyDownloadedDeletesIt() async {
        let fake = FakePrepare()
        fake.existingDMG = fake.candidate.assetSize
        fake.digestOnDisk = String(repeating: "00", count: 32)
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .permanent)
        XCTAssertTrue(fake.removed.contains(fake.dmg))
        XCTAssertEqual(fake.attaches, 0)
    }

    func testAnImageWhoseSignatureIsInvalidOrNotThisDevelopersIsNeverAttached() async {
        for key in ["dmg", "dmg+req"] {
            let fake = FakePrepare()
            fake.signatureFailures[key] = SignatureRefusal(status: key == "dmg" ? -67061 : -67050, message: "no")
            let refused = refusal(await prepare(fake))
            XCTAssertEqual(refused?.kind, .permanent, key)
            XCTAssertEqual(refused?.step, key == "dmg" ? PrepareStep.imageSignature.rawValue : PrepareStep.imageRequirement.rawValue)
            XCTAssertEqual(fake.attaches, 0, key)
            XCTAssertTrue(fake.removed.contains(fake.dmg), key)
        }
    }

    func testAnImageWithALicenseAgreementIsNeverAttached() async {
        let fake = FakePrepare()
        fake.license = .success(true)
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .permanent)
        XCTAssertEqual(refused?.step, PrepareStep.license.rawValue)
        XCTAssertEqual(fake.attaches, 0)

        let unreadable = FakePrepare()
        unreadable.license = .failure(.transient(.license, "the disk image\u{2019}s properties could not be read"))
        let unreadableResult = await prepare(unreadable)
        XCTAssertEqual(refusal(unreadableResult)?.kind, .transient)
        XCTAssertEqual(unreadable.attaches, 0)
    }

    // MARK: - Step 6: the mount, and getting rid of it

    /// hdiutil can finish attaching after the deadline. `hdiutil info` names it; it is detached,
    /// and an attempt that cleaned up after itself does not count.
    func testATimedOutAttachThatHdiutilFinishedIsDetachedAndIsNotAnAttempt() async {
        let fake = FakePrepare()
        fake.attachFailure = .timedOut
        fake.attachLeavesImageAttached = true
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .transient)
        XCTAssertEqual(refused?.countsAsAttempt, false)
        XCTAssertEqual(fake.detached, [UpdateFixture.device])
        XCTAssertTrue(fake.stillAttached.isEmpty)

        let earlier = AttemptRecord(count: 2, lastStep: PrepareStep.attach.rawValue,
                                    nextNotBefore: Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertEqual(SwitcherUpdatePolicy.nextAttempt(after: refused!, attempts: earlier,
                                                        now: Date(timeIntervalSince1970: 1_791_100_000)), earlier)
    }

    func testATimedOutAttachWithNothingToCleanUpIsAnAttempt() async {
        let fake = FakePrepare()
        fake.attachFailure = .timedOut
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.countsAsAttempt, true)
        XCTAssertEqual(fake.detached, [])
    }

    /// hdiutil is never ended, so an attach that timed out may still land: the image is noted as
    /// possibly mounted, for the next check or launch to look for. One that was found and
    /// detached is not.
    func testATimedOutAttachThatMayStillLandIsNoted() async {
        let fake = FakePrepare()
        fake.attachFailure = .timedOut
        _ = refusal(await prepare(fake))
        XCTAssertTrue(fake.notes.contains(.stillMounted(fake.dmg)))

        let cleaned = FakePrepare()
        cleaned.attachFailure = .timedOut
        cleaned.attachLeavesImageAttached = true
        _ = refusal(await prepare(cleaned))
        XCTAssertEqual(cleaned.detached, [UpdateFixture.device])
        XCTAssertFalse(cleaned.notes.contains(.stillMounted(cleaned.dmg)))
    }

    /// A noted image is looked for at the next due check and detached under the prepare lock;
    /// with nothing noted, hdiutil is not even asked.
    func testANotedImageIsDetachedBeforeTheNextCheck() async throws {
        let (store, directory) = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakePrepare()
        fake.otherImages.append(AttachedImage(imagePath: fake.dmg, devices: ["/dev/disk7s1", "/dev/disk7"]))
        let nothing = await SwitcherUpdater.detachLeftoverImages(updatesDirectory: UpdateFixture.updates, store: store,
                                                                 env: fake.env)
        XCTAssertNil(nothing)
        XCTAssertEqual(fake.detached, [])

        try await store.update(now: fake.clock) { $0.mounted = fake.dmg }
        fake.prepareLockHeld = true
        let held = await SwitcherUpdater.detachLeftoverImages(updatesDirectory: UpdateFixture.updates, store: store,
                                                              env: fake.env)
        XCTAssertNil(held, "another copy is checking: its image is not touched")
        XCTAssertEqual(fake.detached, [])

        fake.prepareLockHeld = false
        let swept = await SwitcherUpdater.detachLeftoverImages(updatesDirectory: UpdateFixture.updates, store: store,
                                                               env: fake.env)
        XCTAssertEqual(fake.detached, ["/dev/disk7"])
        XCTAssertNil(swept?.mounted)
        let recorded = await store.load(now: fake.clock).mounted
        XCTAssertNil(recorded)
    }

    /// The note is cleared only while it still names what the sweep went by: another copy's
    /// prepare may take the lock the moment it is let go, and an image it notes then stands.
    func testAnImageNotedByAnotherCopyAfterTheSweepStaysNoted() async throws {
        let (store, directory) = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakePrepare()
        try await store.update(now: fake.clock) { $0.mounted = fake.dmg }
        let landing: SwitcherUpdateState = {
            var state = SwitcherUpdateState()
            state.host = UpdateFixture.host
            state.format = SwitcherUpdateState.currentFormat
            state.mounted = UpdateFixture.mountPoint
            return state
        }()
        let file = directory.appendingPathComponent(SwitcherUpdateStore.stateName)
        var env = fake.env
        let take = env.takePrepareLock
        env.takePrepareLock = {
            guard let release = take() else { return nil }
            return {
                release()
                // Another copy takes the lock now and notes an image it could not detach.
                if let data = try? SwitcherUpdateStore.encoder.encode(landing) { try? data.write(to: file, options: .atomic) }
            }
        }
        let swept = await SwitcherUpdater.detachLeftoverImages(updatesDirectory: UpdateFixture.updates, store: store,
                                                               env: env)
        XCTAssertEqual(swept?.mounted, UpdateFixture.mountPoint)
        let recorded = await store.load(now: fake.clock).mounted
        XCTAssertEqual(recorded, UpdateFixture.mountPoint)
    }

    func testAFailedAttachStillLooksForTheImageAndDetachesIt() async {
        let fake = FakePrepare()
        fake.attachFailure = .failed("hdiutil exited 1")
        fake.attachLeavesImageAttached = true
        _ = refusal(await prepare(fake))
        XCTAssertEqual(fake.detached, [UpdateFixture.device])
        XCTAssertTrue(fake.stillAttached.isEmpty)
    }

    /// Only an image whose file is under `updates/downloads/` is ours; nothing else is detached.
    func testOnlyImagesUnderTheDownloadsFolderAreEverDetached() {
        let fake = FakePrepare()
        fake.otherImages = [
            AttachedImage(imagePath: "/Users/testhome/Downloads/Other.dmg", devices: ["/dev/disk4s1", "/dev/disk4"]),
            AttachedImage(imagePath: UpdateFixture.updates + "/downloadsX/v0.8.0/Claude.Switcher.dmg", devices: ["/dev/disk5"]),
            AttachedImage(imagePath: UpdateFixture.updates + "/mounts/x.dmg", devices: ["/dev/disk6"]),
            AttachedImage(imagePath: UpdateFixture.configDirectory + "/downloads/x.dmg", devices: ["/dev/disk7"]),
            AttachedImage(imagePath: UpdateFixture.updates + "/downloads/v0.9.0/Claude.Switcher.dmg",
                          devices: ["/dev/disk8s1", "/dev/disk8"]),
        ]
        let detached = SwitcherUpdater.detachOurs(env: fake.env, updatesDirectory: UpdateFixture.updates)
        XCTAssertEqual(fake.detached, ["/dev/disk8"])
        XCTAssertEqual(detached, [UpdateFixture.updates + "/downloads/v0.9.0/Claude.Switcher.dmg"])
    }

    /// Every way out after the attach detaches the image and then sweeps for anything of ours.
    func testEveryRefusalAfterTheAttachStillDetaches() async {
        let scenarios: [(String, (FakePrepare) -> Void)] = [
            ("layout", { $0.mountEntries = [DirectoryEntry(name: "Claude.app", kind: .directory)] }),
            ("mounted signature", { $0.signatureFailures["mounted"] = SignatureRefusal(status: -67054, message: "x") }),
            ("mounted requirement", { $0.signatureFailures["mounted+req"] = SignatureRefusal(status: -67050, message: "x") }),
            ("mounted identity", { $0.mountedIdentity = UpdateFixture.identity(UpdateFixture.v080, team: "ABCDEFGHIJ") }),
            ("staging folder", { $0.stagingResult = .failure(.transient(.copy, "no staging folder")) }),
            ("copy", { $0.copyRefusal = .transient(.copy, "copy failed") }),
            ("quarantine", { $0.quarantineRefusal = .transient(.quarantine, "EPERM") }),
            ("staged signature", { $0.signatureFailures["staged"] = SignatureRefusal(status: -67061, message: "x") }),
            ("spctl", { $0.verdict = .rejected("rejected") }),
            ("volume", { $0.stagedDevice = 1 }),
        ]
        for (name, script) in scenarios {
            let fake = FakePrepare()
            script(fake)
            _ = refusal(await prepare(fake))
            XCTAssertEqual(fake.detached.first, UpdateFixture.device, name)
            XCTAssertTrue(fake.stillAttached.isEmpty, name)
            XCTAssertTrue(fake.steps.contains(.detach), name)
        }
    }

    func testAnImageThatWillNotDetachIsNotedNotRefused() async throws {
        let fake = FakePrepare()
        fake.detachSucceeds = false
        let prepared = try await prepare(fake).get()
        XCTAssertEqual(prepared.stagedAppPath, UpdateFixture.staged)
        XCTAssertTrue(fake.notes.contains(.stillMounted(UpdateFixture.mountPoint)))
    }

    // MARK: - Step 7: the image holds Claude Switcher and nothing else

    func testTheMountRootMustHoldJustTheAppAndItsApplicationsLink() async {
        let app = DirectoryEntry(name: "Claude Switcher.app", kind: .directory)
        let link = DirectoryEntry(name: "Applications", kind: .symlink, linkTarget: "/Applications")
        let layouts: [(String, [DirectoryEntry])] = [
            ("two apps", [app, DirectoryEntry(name: "Other.app", kind: .directory)]),
            ("the app is a link", [DirectoryEntry(name: "Claude Switcher.app", kind: .symlink, linkTarget: "/tmp/x.app")]),
            ("the app is a file", [DirectoryEntry(name: "Claude Switcher.app", kind: .file)]),
            ("wrong name", [DirectoryEntry(name: "Claude.app", kind: .directory)]),
            ("empty", []),
            ("a link elsewhere", [app, DirectoryEntry(name: "Applications", kind: .symlink, linkTarget: "/Users")]),
            ("an extra file", [app, link, DirectoryEntry(name: ".DS_Store", kind: .file)]),
            ("Applications as a folder", [app, DirectoryEntry(name: "Applications", kind: .directory)]),
        ]
        for (name, entries) in layouts {
            let fake = FakePrepare()
            fake.mountEntries = entries
            let refused = refusal(await prepare(fake))
            XCTAssertEqual(refused?.kind, .permanent, name)
            XCTAssertEqual(refused?.step, PrepareStep.layout.rawValue, name)
            XCTAssertFalse(fake.events.contains { $0.hasPrefix("copy ") }, name)
            XCTAssertTrue(fake.removed.contains(fake.dmg), name)
        }
        for entries in [[app], [link, app]] {
            let fake = FakePrepare()
            fake.mountEntries = entries
            if case .failure(let refused) = await prepare(fake) { XCTFail("\(entries): \(refused)") }
        }
    }

    // MARK: - Steps 8 to 10 and 14: the app, on the image and staged

    func testEverySignatureStatusOnTheMountedOrStagedCopyIsPermanent() async {
        for status: Int32 in [-67054, -67061, -67056, -67030, -67014, -67050] {
            for key in ["mounted", "mounted+req", "staged", "staged+req"] {
                let fake = FakePrepare()
                fake.signatureFailures[key] = SignatureRefusal(status: status, message: "status \(status)")
                let refused = refusal(await prepare(fake))
                XCTAssertEqual(refused?.kind, .permanent, "\(key) \(status)")
                XCTAssertTrue(fake.removed.contains(fake.dmg), "\(key) \(status)")
                if key.hasPrefix("mounted") {
                    XCTAssertFalse(fake.events.contains { $0.hasPrefix("copy ") }, "\(key) \(status)")
                } else {
                    XCTAssertTrue(fake.removed.contains(UpdateFixture.staged), "\(key) \(status)")
                    XCTAssertTrue(fake.removedFolders.contains(UpdateFixture.staging), "\(key) \(status)")
                    XCTAssertEqual(fake.notes.last, .stagingGone(UpdateFixture.staging), "\(key) \(status)")
                }
            }
        }
    }

    private var foreignIdentities: [(String, CodeIdentity)] {
        let v = UpdateFixture.v080
        return [
            ("another team", UpdateFixture.identity(v, team: "ABCDEFGHIJ")),
            ("no team", UpdateFixture.identity(v, team: nil)),
            ("another identifier", UpdateFixture.identity(v, identifier: "com.example.other")),
            ("no hardened runtime", UpdateFixture.identity(v, flags: 0)),
            ("ad hoc", UpdateFixture.identity(v, flags: 0x10002)),
            ("no version", UpdateFixture.identity(nil)),
        ]
    }

    func testAnotherTeamIdentifierNoRuntimeOrAdHocIsRefusedOnTheImage() async {
        for (name, identity) in foreignIdentities {
            let fake = FakePrepare()
            fake.mountedIdentity = identity
            let refused = refusal(await prepare(fake))
            XCTAssertEqual(refused?.kind, .permanent, name)
            XCTAssertEqual(refused?.step, PrepareStep.mountedIdentity.rawValue, name)
            XCTAssertFalse(fake.events.contains { $0.hasPrefix("copy ") }, name)
        }
    }

    func testAnotherTeamIdentifierNoRuntimeOrAdHocIsRefusedOnTheStagedCopy() async {
        for (name, identity) in foreignIdentities {
            let fake = FakePrepare()
            fake.stagedIdentity = identity
            let refused = refusal(await prepare(fake))
            XCTAssertEqual(refused?.kind, .permanent, name)
            XCTAssertEqual(refused?.step, PrepareStep.stagedIdentity.rawValue, name)
            XCTAssertTrue(fake.removed.contains(UpdateFixture.staged), name)
        }
    }

    /// The sealed version must be the tag's: older, equal to the running one, or another newer
    /// one are all refused, on the image and again on the staged copy.
    func testASealedVersionOtherThanTheTagsIsRefusedOnTheImageAndStaged() async {
        for version in [UpdateFixture.v060, UpdateFixture.v070, ReleaseVersion(major: 0, minor: 9, patch: 0)] {
            let mounted = FakePrepare()
            mounted.mountedIdentity = UpdateFixture.identity(version)
            let mountedResult = await prepare(mounted)
            XCTAssertEqual(refusal(mountedResult)?.step, PrepareStep.mountedIdentity.rawValue, "\(version)")

            let staged = FakePrepare()
            staged.stagedIdentity = UpdateFixture.identity(version)
            let stagedResult = await prepare(staged)
            XCTAssertEqual(refusal(stagedResult)?.step, PrepareStep.stagedIdentity.rawValue, "\(version)")
        }
    }

    /// The identity check refuses a copy that is not newer than the running one even when it
    /// matches the version it was expected to be.
    func testTheIdentityCheckRefusesAVersionNotNewerThanTheRunningOne() {
        let trust = UpdateFixture.trust
        for version in [UpdateFixture.v060, UpdateFixture.v070] {
            let refusal = SwitcherUpdatePolicy.verifyBundleIdentity(UpdateFixture.identity(version), trust: trust,
                                                                    expected: version)
            XCTAssertEqual(refusal?.kind, .permanent, "\(version)")
        }
        XCTAssertNil(SwitcherUpdatePolicy.verifyBundleIdentity(UpdateFixture.identity(UpdateFixture.v080), trust: trust,
                                                               expected: UpdateFixture.v080))
        // Going back is the one case where older is expected.
        XCTAssertNil(SwitcherUpdatePolicy.verifyBundleIdentity(UpdateFixture.identity(UpdateFixture.v060), trust: trust,
                                                               expected: UpdateFixture.v060, mustBeNewer: false))
    }

    // MARK: - Steps 13, 15 and 17

    func testAQuarantineFlagThatWillNotClearRefusesAndRemovesTheStagedCopy() async {
        let fake = FakePrepare()
        fake.quarantineRefusal = .transient(.quarantine, "could not clear the quarantine flag (Operation not permitted)")
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .transient)
        XCTAssertEqual(fake.removed.filter { $0 == UpdateFixture.staged }.count, 1)
        XCTAssertEqual(fake.removedFolders, [UpdateFixture.staging])
        XCTAssertFalse(fake.removed.contains(fake.dmg), "a transient refusal keeps the image for next time")
    }

    func testGatekeeperSayingNoIsPermanentAndNoAnswerIsTransient() async {
        let rejected = FakePrepare()
        rejected.verdict = .rejected("rejected (the code is valid but does not seem to be an app)")
        let rejectedResult = await prepare(rejected)
        XCTAssertEqual(refusal(rejectedResult)?.kind, .permanent)
        XCTAssertTrue(rejected.removed.contains(UpdateFixture.staged))
        XCTAssertTrue(rejected.removed.contains(rejected.dmg))

        let silent = FakePrepare()
        silent.verdict = .unavailable("spctl did not answer in time")
        let silentResult = await prepare(silent)
        XCTAssertEqual(refusal(silentResult)?.kind, .transient)
        XCTAssertTrue(silent.removed.contains(UpdateFixture.staged))
        XCTAssertFalse(silent.removed.contains(silent.dmg))
    }

    /// Step 17 holds the staged copy to a plain folder as well as to the install's volume.
    func testAStagedCopyThatIsNotAFolderIsRefused() async {
        let fake = FakePrepare()
        fake.kinds[UpdateFixture.staged] = .symlink
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .permanent)
        XCTAssertEqual(refused?.step, PrepareStep.volume.rawValue)
    }

    func testAStagingFolderOnAnotherVolumeIsRefused() async {
        let fake = FakePrepare()
        fake.stagedDevice = 42
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .permanent)
        XCTAssertEqual(refused?.step, PrepareStep.volume.rawValue)
        XCTAssertEqual(refused?.reason, "staging folder is on another volume")
        XCTAssertTrue(fake.removed.contains(UpdateFixture.staged))
    }

    // MARK: - What a prepare may remove

    /// The fake fails the test on any removal outside `updates/downloads/`, `updates/mounts/`
    /// and the staged copy this prepare made; this runs every way a prepare can end.
    func testEveryPathAPrepareRemovesIsItsOwn() async {
        let scenarios: [(FakePrepare) -> Void] = [
            { _ in },
            { $0.existingDMG = 1 },
            { $0.downloadedBytes = 3 },
            { $0.digestOnDisk = "00" },
            { $0.signatureFailures["dmg"] = SignatureRefusal(status: -67061, message: "x") },
            { $0.license = .success(true) },
            { $0.attachFailure = .timedOut; $0.attachLeavesImageAttached = true },
            { $0.mountEntries = [] },
            { $0.signatureFailures["mounted+req"] = SignatureRefusal(status: -67050, message: "x") },
            { $0.copyRefusal = .transient(.copy, "x") },
            { $0.quarantineRefusal = .transient(.quarantine, "x") },
            { $0.signatureFailures["staged+req"] = SignatureRefusal(status: -67050, message: "x") },
            { $0.verdict = .rejected("x") },
            { $0.stagedDevice = 1 },
        ]
        for script in scenarios {
            let fake = FakePrepare()
            script(fake)
            _ = await prepare(fake)
            for path in fake.removed {
                XCTAssertTrue(path.hasPrefix(UpdateFixture.updates + "/downloads/") || path == UpdateFixture.staged, path)
            }
        }
    }

    /// A staged copy that could not be removed stays named in `state.json`: its folder is not
    /// emptied, and `state.staging` is not cleared.
    func testAStagedCopyThatCannotBeRemovedStaysNamed() async {
        let fake = FakePrepare()
        fake.quarantineRefusal = .transient(.quarantine, "x")
        fake.removeFails = [UpdateFixture.staged]
        _ = refusal(await prepare(fake))
        XCTAssertTrue(fake.removed.contains(UpdateFixture.staged))
        XCTAssertEqual(fake.removedFolders, [])
        XCTAssertEqual(fake.notes, [.staging(UpdateFixture.staging)])
    }

    // MARK: - One prepare at a time

    /// Another copy of Claude Switcher is checking: nothing is fetched, attached or removed, and
    /// it is not counted as an attempt.
    func testWhileAnotherCopyChecksNothingIsTouched() async {
        let fake = FakePrepare()
        fake.prepareLockHeld = true
        fake.existingDMG = 1
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .transient)
        XCTAssertEqual(refused?.reason, "another Claude Switcher is checking")
        XCTAssertEqual(refused?.countsAsAttempt, false)
        XCTAssertEqual(fake.downloads, 0)
        XCTAssertEqual(fake.attaches, 0)
        XCTAssertEqual(fake.removed, [])
        XCTAssertEqual(fake.detached, [])
        XCTAssertEqual(fake.steps, [])
    }

    /// The lock is taken before anything is done and let go after everything, on every way out.
    func testThePrepareLockIsHeldThroughoutAndLetGoOnEveryPath() async {
        let scenarios: [(String, (FakePrepare) -> Void)] = [
            ("success", { _ in }),
            ("not newer", { $0.candidate = UpdateFixture.candidate(UpdateFixture.v060) }),
            ("digest", { $0.digestOnDisk = "00" }),
            ("attach timeout", { $0.attachFailure = .timedOut }),
            ("staged signature", { $0.signatureFailures["staged"] = SignatureRefusal(status: -67061, message: "x") }),
            ("volume", { $0.stagedDevice = 1 }),
        ]
        for (name, script) in scenarios {
            let fake = FakePrepare()
            script(fake)
            _ = await prepare(fake)
            XCTAssertEqual(fake.lockTakes, 1, name)
            XCTAssertEqual(fake.lockReleases, 1, name)
            XCTAssertEqual(fake.events.first, "lock", name)
            XCTAssertEqual(fake.events.last, "unlock", name)
        }
    }

    /// A copy that vanished from under the check — another copy detached the image or removed
    /// the folder — is not a verdict on the release: tried again, never rejected.
    func testACopyThatVanishedDuringTheCheckIsTransient() async {
        for status: Int32 in [-67068, ENOENT] {
            for step in [0, 1] {
                let refused = SwitcherUpdater.verifyApp(
                    UpdateFixture.staged, requirement: "r", trust: trust, expected: UpdateFixture.v080,
                    steps: (.stagedSignature, .stagedRequirement, .stagedIdentity), hook: { _ in },
                    verify: { _, requirement in
                        (requirement == nil) == (step == 0) ? .failure(SignatureRefusal(status: status, message: "gone"))
                            : .success(UpdateFixture.identity(UpdateFixture.v080))
                    })
                guard case .failure(let refusal) = refused else { return XCTFail("\(status) \(step)") }
                XCTAssertEqual(refusal.kind, .transient, "\(status) \(step)")
            }
        }
        let fake = FakePrepare()
        fake.signatureFailures["mounted"] = SignatureRefusal(status: -67068, message: "gone")
        let refused = refusal(await prepare(fake))
        XCTAssertEqual(refused?.kind, .transient)
        XCTAssertFalse(fake.removed.contains(fake.dmg), "the image is kept for the next try")
    }

    // MARK: - Letting go of a kept copy

    /// Quitting with a verified copy kept: the staged copy and its emptied folder go at once; the
    /// disk image stays for the next check.
    func testQuittingRemovesOnlyTheKeptStagedCopy() async throws {
        let fake = FakePrepare()
        let prepared = try await prepare(fake).get()
        let before = fake.removed
        XCTAssertTrue(SwitcherUpdater.discardStagedOnly(prepared, env: fake.env))
        XCTAssertEqual(Array(fake.removed.dropFirst(before.count)), [UpdateFixture.staged])
        XCTAssertEqual(fake.removedFolders, [UpdateFixture.staging])
        XCTAssertFalse(fake.removed.contains(fake.dmg))
        XCTAssertFalse(fake.removed.contains(UpdateFixture.updates + "/downloads/v0.8.0"))

        let stuck = FakePrepare()
        let kept = try await prepare(stuck).get()
        stuck.removeFails = [UpdateFixture.staged]
        XCTAssertFalse(SwitcherUpdater.discardStagedOnly(kept, env: stuck.env))
        XCTAssertEqual(stuck.removedFolders, [])
    }

    /// Discarding while another copy checks: the staged copy is this process's own and goes; the
    /// download may be in use there and stays for the next launch to tidy.
    func testDiscardingWhileAnotherCopyChecksLeavesTheDownload() async throws {
        let fake = FakePrepare()
        let prepared = try await prepare(fake).get()
        fake.prepareLockHeld = true
        await SwitcherUpdater.discard(prepared, updatesDirectory: UpdateFixture.updates, env: fake.env)
        XCTAssertEqual(fake.removed.last, UpdateFixture.staged)
        XCTAssertFalse(fake.removed.contains(UpdateFixture.updates + "/downloads/v0.8.0"))
    }

    func testDiscardingAPreparedUpdateRemovesOnlyItsStagedCopyAndItsDownload() async throws {
        let fake = FakePrepare()
        let prepared = try await prepare(fake).get()
        await SwitcherUpdater.discard(prepared, updatesDirectory: UpdateFixture.updates, env: fake.env)
        XCTAssertEqual(Array(fake.removed.suffix(2)), [UpdateFixture.staged, UpdateFixture.updates + "/downloads/v0.8.0"])
        XCTAssertEqual(fake.removedFolders, [UpdateFixture.staging])
        XCTAssertEqual(fake.notes.last, .stagingGone(UpdateFixture.staging))
    }
}
