import Foundation
import XCTest
@testable import KadmosCore

final class SecurityHardeningTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadmos-sec-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    func testResolveCanonicalURLHandlesRegularSymlinkAndNonExistentLeaf() throws {
        let realDir = tempRoot.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realFile = realDir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: realFile)

        let direct = DocumentSecurity.resolveCanonicalURL(realFile)
        XCTAssertFalse(direct.wasSymlink)
        XCTAssertEqual(direct.resolved.path, realFile.path)

        let symFile = tempRoot.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symFile, withDestinationURL: realFile)
        let resolvedFile = DocumentSecurity.resolveCanonicalURL(symFile)
        XCTAssertTrue(resolvedFile.wasSymlink)
        XCTAssertEqual(resolvedFile.resolved.path, realFile.path)

        let symDir = tempRoot.appendingPathComponent("symdir")
        try FileManager.default.createSymbolicLink(at: symDir, withDestinationURL: realDir)
        let nonExistentLeaf = symDir.appendingPathComponent("future.txt")
        let resolvedLeaf = DocumentSecurity.resolveCanonicalURL(nonExistentLeaf)
        XCTAssertTrue(resolvedLeaf.wasSymlink)
        XCTAssertEqual(resolvedLeaf.resolved.path, realDir.appendingPathComponent("future.txt").path)

        let missingPlain = realDir.appendingPathComponent("sub/missing.txt")
        let resolvedMissing = DocumentSecurity.resolveCanonicalURL(missingPlain)
        XCTAssertFalse(resolvedMissing.wasSymlink)
        XCTAssertEqual(resolvedMissing.resolved.path, missingPlain.path)
    }

    func testValidateWithinScopeRejectsSiblingPrefixTraversalAndEscapingSymlinks() throws {
        let workspace = tempRoot.appendingPathComponent("root", isDirectory: true)
        let sibling = tempRoot.appendingPathComponent("root2", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        let insideFile = workspace.appendingPathComponent("inside.txt")
        let siblingFile = sibling.appendingPathComponent("secret.txt")
        try Data("inside".utf8).write(to: insideFile)
        try Data("secret".utf8).write(to: siblingFile)

        XCTAssertTrue(DocumentSecurity.validateWithinScope(candidate: workspace, allowedRoot: workspace))
        XCTAssertTrue(DocumentSecurity.validateWithinScope(candidate: insideFile, allowedRoot: workspace))
        XCTAssertFalse(DocumentSecurity.validateWithinScope(candidate: siblingFile, allowedRoot: workspace))

        let traversal = workspace.appendingPathComponent("../root2/secret.txt")
        XCTAssertFalse(DocumentSecurity.validateWithinScope(candidate: traversal, allowedRoot: workspace))

        let escapingSymlink = workspace.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: escapingSymlink, withDestinationURL: siblingFile)
        XCTAssertFalse(DocumentSecurity.validateWithinScope(candidate: escapingSymlink, allowedRoot: workspace))

        let internalSymlink = workspace.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: internalSymlink, withDestinationURL: insideFile)
        XCTAssertTrue(DocumentSecurity.validateWithinScope(candidate: internalSymlink, allowedRoot: workspace))
    }

    func testOpenDocumentNormalLimitedStreamingAndNonRegularErrors() throws {
        // Exact boundary checks
        XCTAssertEqual(DocumentSecurity.classifyTier(byteSize: 0), .normal)
        XCTAssertEqual(DocumentSecurity.classifyTier(byteSize: DocumentSecurity.limitedModeBytes), .normal)
        XCTAssertEqual(
            DocumentSecurity.classifyTier(byteSize: DocumentSecurity.limitedModeBytes + 1),
            .limitedMode(byteSize: DocumentSecurity.limitedModeBytes + 1)
        )
        XCTAssertEqual(
            DocumentSecurity.classifyTier(byteSize: DocumentSecurity.streamingModeBytes),
            .limitedMode(byteSize: DocumentSecurity.streamingModeBytes)
        )
        XCTAssertEqual(
            DocumentSecurity.classifyTier(byteSize: DocumentSecurity.streamingModeBytes + 1),
            .streamingReadOnly(byteSize: DocumentSecurity.streamingModeBytes + 1)
        )

        // Open normal file with UTF-8 BOM + CRLF -> normalizes editor text to LF
        let normalFile = tempRoot.appendingPathComponent("normal.txt")
        let bomCRLF = try TextEncodingCodec.encode("line1\r\nline2\r\n", as: .utf8BOM)
        try bomCRLF.write(to: normalFile)

        let payload = try DocumentSecurity.openDocument(at: normalFile)
        XCTAssertFalse(payload.wasSymlink)
        XCTAssertEqual(payload.tier, .normal)
        XCTAssertEqual(payload.detectedLineEnding, .crlf)
        XCTAssertEqual(payload.decoded?.encoding, .utf8BOM)
        XCTAssertEqual(payload.decoded?.text, "line1\nline2\n")
        XCTAssertNil(payload.streamingReader)

        // Open using low test thresholds for limited and streaming tiers
        let limitedPayload = try DocumentSecurity.openDocument(
            at: normalFile,
            limitedThreshold: 4,
            streamingThreshold: 1024
        )
        XCTAssertEqual(limitedPayload.tier, .limitedMode(byteSize: Int64(bomCRLF.count)))
        XCTAssertNotNil(limitedPayload.decoded)

        let streamingPayload = try DocumentSecurity.openDocument(
            at: normalFile,
            limitedThreshold: 4,
            streamingThreshold: 5
        )
        XCTAssertEqual(streamingPayload.tier, .streamingReadOnly(byteSize: Int64(bomCRLF.count)))
        XCTAssertNil(streamingPayload.decoded)
        XCTAssertNotNil(streamingPayload.streamingReader)

        // Directory is rejected as non-regular file
        XCTAssertThrowsError(try DocumentSecurity.openDocument(at: tempRoot)) { error in
            XCTAssertEqual(error as? DocumentSecurityError, .notARegularFile)
        }

        // Named pipe (FIFO) is rejected immediately without blocking
        let fifoURL = tempRoot.appendingPathComponent("pipe.fifo")
        XCTAssertEqual(mkfifo(fifoURL.path, 0o600), 0)
        XCTAssertThrowsError(try DocumentSecurity.openDocument(at: fifoURL)) { error in
            XCTAssertEqual(error as? DocumentSecurityError, .notARegularFile)
        }

        // Missing file fails cleanly via direct open
        let missing = tempRoot.appendingPathComponent("does-not-exist.txt")
        XCTAssertThrowsError(try DocumentSecurity.openDocument(at: missing))
    }

    func testStreamingFileReaderSnapsUTF8BoundariesAcrossChunks() async throws {
        let sample = String(repeating: "Merhaba 🚀 Dünyası 😀!", count: 12)
        let data = Data(sample.utf8)
        let fileURL = tempRoot.appendingPathComponent("stream.txt")
        try data.write(to: fileURL)

        let reader = StreamingFileReader(url: fileURL, totalBytes: Int64(data.count), chunkSize: 16)
        var reconstructed = ""
        var offset: Int64 = 0

        while offset < reader.totalBytes {
            let chunk = try await reader.readChunk(atOffset: offset)
            XCTAssertFalse(chunk.hadInvalidSequences)
            XCTAssertGreaterThan(chunk.actualEnd, chunk.actualStart)
            reconstructed.append(chunk.text)
            offset = chunk.nextOffset
        }
        XCTAssertEqual(reconstructed, sample)

        // Request an offset right in the middle of the 4-byte '🚀' emoji
        let rocketOffset = Int64("Merhaba ".utf8.count)
        let midEmojiOffset = rocketOffset + 2
        let snapped = try await reader.readChunk(atOffset: midEmojiOffset)
        XCTAssertEqual(snapped.actualStart, rocketOffset)
        XCTAssertFalse(snapped.hadInvalidSequences)
        XCTAssertTrue(snapped.text.hasPrefix("🚀"))

        // Out of bounds offsets fail safely
        do {
            _ = try await reader.readChunk(atOffset: -1)
            XCTFail("Expected invalidByteOffset error")
        } catch let error as DocumentSecurityError {
            XCTAssertEqual(error, .invalidByteOffset)
        }
    }

    func testAtomicSaveStripsExecutePermissionsAndPreserves0600() throws {
        let execFile = tempRoot.appendingPathComponent("script.sh")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: execFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execFile.path)

        try DocumentSecurity.atomicSave(data: Data("updated".utf8), to: execFile)
        let attrs1 = try FileManager.default.attributesOfItem(atPath: execFile.path)
        let mode1 = (attrs1[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(mode1 & 0o111, 0)
        XCTAssertEqual(mode1 & 0o777, 0o644)

        let privateFile = tempRoot.appendingPathComponent("secret.txt")
        try Data("v1".utf8).write(to: privateFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateFile.path)

        try DocumentSecurity.atomicSave(data: Data("v2".utf8), to: privateFile)
        let attrs2 = try FileManager.default.attributesOfItem(atPath: privateFile.path)
        let mode2 = (attrs2[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(mode2 & 0o777, 0o600)
    }

    func testURLRouteValidatorAllowsOnlySafeRoutesAndNeverCreatesFiles() {
        let newDir = tempRoot.appendingPathComponent("workspace")
        let fileTarget = tempRoot.appendingPathComponent("notes.txt")

        let r1 = URLRouteValidator.validate(URL(string: "KADMOS://new-document")!)
        XCTAssertEqual(r1, .success(.newDocument(directory: nil)))

        let encodedDir = newDir.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let r2 = URLRouteValidator.validate(URL(string: "kadmos://new-document?dir=\(encodedDir)")!)
        XCTAssertEqual(r2, .success(.newDocument(directory: URL(fileURLWithPath: newDir.path))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.path))

        let encodedFile = fileTarget.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let r3 = URLRouteValidator.validate(URL(string: "kadmos://open-request?file=\(encodedFile)")!)
        XCTAssertEqual(r3, .success(.openRequest(file: URL(fileURLWithPath: fileTarget.path))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileTarget.path))

        XCTAssertEqual(
            URLRouteValidator.validate(URL(string: "https://new-document")!),
            .failure(.invalidScheme)
        )
        XCTAssertEqual(
            URLRouteValidator.validate(URL(string: "kadmos://run-script")!),
            .failure(.unknownHost)
        )
        XCTAssertEqual(
            URLRouteValidator.validate(URL(string: "kadmos://new-document/extra")!),
            .failure(.unknownHost)
        )
        XCTAssertEqual(
            URLRouteValidator.validate(URL(string: "kadmos://open-request?file=relative.txt")!),
            .failure(.invalidPath)
        )
        XCTAssertEqual(
            URLRouteValidator.validate(URL(string: "kadmos://open-request?file=/tmp/a/../../etc/passwd")!),
            .failure(.invalidPath)
        )
        XCTAssertEqual(
            URLRouteValidator.validate(URL(string: "kadmos://open-request?file=//server/share")!),
            .failure(.invalidPath)
        )
        XCTAssertEqual(
            URLRouteValidator.validate(URL(string: "kadmos://open-request?file=/tmp/a%00b")!),
            .failure(.forbiddenControlCharacters)
        )
        XCTAssertEqual(
            URLRouteValidator.validate(URL(string: "kadmos://open-request?file=/tmp/a%0Ab")!),
            .failure(.forbiddenControlCharacters)
        )
    }

    func testSessionVaultEnforcesPermissionsPrunesStaleDraftsAndClearsAll() throws {
        let vaultDir = tempRoot.appendingPathComponent("SessionVault", isDirectory: true)
        let vault = SessionVault(baseDirectory: vaultDir)

        let tab1 = UUID()
        let tab2 = UUID()
        let draft1 = try vault.saveDraft(text: "Unsaved Tab 1", forTabID: tab1)
        let draft2 = try vault.saveDraft(text: "Unsaved Tab 2", forTabID: tab2)

        // Verify directory 0700 and draft 0600 permissions
        let dirPerms = try FileManager.default.attributesOfItem(atPath: vaultDir.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((dirPerms?.intValue ?? 0) & 0o777, 0o700)

        let draft1URL = vaultDir.appendingPathComponent(draft1)
        let draft1Perms = try FileManager.default.attributesOfItem(atPath: draft1URL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((draft1Perms?.intValue ?? 0) & 0o777, 0o600)

        // Save snapshot referencing only tab1 (so draft2 should be pruned)
        let snapshot = SessionSnapshot(
            activeTabID: tab1,
            tabs: [
                SessionTabSnapshot(
                    id: tab1,
                    untitledNumber: 1,
                    encoding: .utf8,
                    lineEnding: .lf,
                    isDirty: true,
                    cursorLocation: 7,
                    zoomPercent: 120,
                    draftFilename: draft1,
                    customFilename: "deneme.yml"
                )
            ],
            savedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        try vault.saveSnapshot(snapshot)

        let sessionURL = vaultDir.appendingPathComponent("session.json")
        let sessionPerms = try FileManager.default.attributesOfItem(atPath: sessionURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((sessionPerms?.intValue ?? 0) & 0o777, 0o600)

        let loadedSnapshot = try vault.loadSnapshot()
        XCTAssertEqual(loadedSnapshot, snapshot)
        XCTAssertEqual(try vault.loadDraft(filename: draft1), "Unsaved Tab 1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultDir.appendingPathComponent(draft2).path))

        // Invalid draft filenames must be rejected
        XCTAssertThrowsError(try vault.loadDraft(filename: "../secret.txt")) { error in
            XCTAssertEqual(error as? SessionVaultError, .invalidDraftFilename)
        }
        XCTAssertThrowsError(try vault.loadDraft(filename: "draft-not-a-uuid.txt")) { error in
            XCTAssertEqual(error as? SessionVaultError, .invalidDraftFilename)
        }

        // Symlinks placed inside the vault must be rejected
        let rogueTab = UUID()
        let rogueDraftName = SessionVault.draftFilename(for: rogueTab)
        let rogueTarget = tempRoot.appendingPathComponent("outside.txt")
        try Data("rogue".utf8).write(to: rogueTarget)
        try FileManager.default.createSymbolicLink(
            at: vaultDir.appendingPathComponent(rogueDraftName),
            withDestinationURL: rogueTarget
        )
        XCTAssertThrowsError(try vault.loadDraft(filename: rogueDraftName)) { error in
            XCTAssertEqual(error as? SessionVaultError, .symlinkDetectedInVault)
        }

        try vault.clearAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: rogueTarget.path))
        XCTAssertNil(try vault.loadSnapshot())
        let remaining = try FileManager.default.contentsOfDirectory(atPath: vaultDir.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testOpenDocumentWithOverrideEncodingDecodesSinglePassSafely() throws {
        let turkishSample = "Çağdaş Türkçe metin: ğüşıöç ĞÜŞİÖÇ\r\nİkinci satır"
        let win1254Data = try TextEncodingCodec.encode(turkishSample, as: .windows1254)
        let fileURL = tempRoot.appendingPathComponent("win1254.txt")
        try win1254Data.write(to: fileURL)

        let autoPayload = try DocumentSecurity.openDocument(at: fileURL)
        XCTAssertEqual(autoPayload.decoded?.encoding, .utf8)
        XCTAssertTrue(autoPayload.decoded?.hadInvalidSequences == true)

        let overridePayload = try DocumentSecurity.openDocument(at: fileURL, overrideEncoding: .windows1254)
        XCTAssertEqual(overridePayload.decoded?.encoding, .windows1254)
        XCTAssertFalse(overridePayload.decoded?.hadInvalidSequences ?? true)
        XCTAssertEqual(overridePayload.decoded?.text, "Çağdaş Türkçe metin: ğüşıöç ĞÜŞİÖÇ\nİkinci satır")
        XCTAssertEqual(overridePayload.detectedLineEnding, .crlf)
    }
}
