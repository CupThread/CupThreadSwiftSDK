import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("AttachmentFilenameSanitizationTests")
struct AttachmentFilenameSanitizationTests {
    @Test("makeFilename strips leading dots from file extension")
    func stripsLeadingDots() {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let filename = PhotoAttachmentHelper.makeFilename(fileExtension: ".png", id: id)
        #expect(filename == "screenshot_12345678-1234-1234-1234-123456789abc.png")
    }

    @Test("makeFilename sanitizes path traversal tokens in extension")
    func sanitizesPathTraversal() {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let maliciousExtensions = ["../../etc/passwd", "png/../../test", "../jpg", "png/sub", "/absolute/path"]
        for ext in maliciousExtensions {
            let filename = PhotoAttachmentHelper.makeFilename(fileExtension: ext, id: id)
            #expect(!filename.contains("/"))
            #expect(!filename.contains(".."))
            #expect(filename == "screenshot_12345678-1234-1234-1234-123456789abc.jpg")
        }
    }

    @Test("sanitizeFileExtension handles invalid and empty extensions with safe fallback")
    func sanitizesFileExtensionFallbacks() {
        #expect(PhotoAttachmentHelper.sanitizeFileExtension("") == "jpg")
        #expect(PhotoAttachmentHelper.sanitizeFileExtension("   ") == "jpg")
        #expect(PhotoAttachmentHelper.sanitizeFileExtension(".") == "jpg")
        #expect(PhotoAttachmentHelper.sanitizeFileExtension("...") == "jpg")
        #expect(PhotoAttachmentHelper.sanitizeFileExtension("tar.gz") == "jpg")
        #expect(PhotoAttachmentHelper.sanitizeFileExtension("bad#ext") == "jpg")
        #expect(PhotoAttachmentHelper.sanitizeFileExtension("jpeg ") == "jpeg")
        #expect(PhotoAttachmentHelper.sanitizeFileExtension("  .PNG  ") == "png")
        #expect(PhotoAttachmentHelper.sanitizeFileExtension("...HEIC") == "heic")
        #expect(PhotoAttachmentHelper.sanitizeFileExtension("webp") == "webp")
        #expect(PhotoAttachmentHelper.sanitizeFileExtension("gif") == "gif")
    }

    @Test("makeTempUploadFile confines created files inside temporaryDirectory")
    func confinesToTemporaryDirectory() async throws {
        let id = UUID()
        let data = Data([0x01, 0x02, 0x03])
        let url = try await PhotoAttachmentHelper.makeTempUploadFile(data, fileExtension: "../../traversal", id: id)
        defer { PhotoAttachmentHelper.removeTempUploadFile(at: url) }

        #expect(url.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
        #expect(!url.lastPathComponent.contains("/"))
        #expect(!url.lastPathComponent.contains(".."))
        #expect(url.lastPathComponent == "cupthread-upload-\(id.uuidString.lowercased()).jpg")
    }

    @Test("makeTempUploadFile strips leading dot in extension")
    func tempUploadFileStripsLeadingDot() async throws {
        let id = UUID()
        let data = Data([0x01, 0x02, 0x03])
        let url = try await PhotoAttachmentHelper.makeTempUploadFile(data, fileExtension: ".png", id: id)
        defer { PhotoAttachmentHelper.removeTempUploadFile(at: url) }

        #expect(url.lastPathComponent == "cupthread-upload-\(id.uuidString.lowercased()).png")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
