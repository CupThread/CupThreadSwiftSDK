import Foundation

extension PhotoAttachmentHelper {
    /// Spools upload-ready bytes to a uniquely named file in the temporary
    /// directory, so the upload transport can stream them off disk
    /// (`upload(for:fromFile:)`) instead of buffering the whole attachment
    /// in memory for the network round-trip.
    ///
    /// The write runs off the caller's actor (the function is nonisolated
    /// async), keeping potentially large disk I/O off the main thread.
    ///
    /// - Parameters:
    ///   - data: The bytes to spool.
    ///   - fileExtension: File extension without a leading dot.
    ///   - id: Unique id making the file name collision-free per upload.
    /// - Returns: The URL of the spooled file. Remove it with
    ///   ``removeTempUploadFile(at:)`` when the upload finishes.
    /// - Throws: Propagates `FileManager` write errors.
    static func makeTempUploadFile(
        _ data: Data,
        fileExtension: String,
        id: UUID
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cupthread-upload-\(id.uuidString.lowercased()).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Best-effort removal of a file spooled by ``makeTempUploadFile(fileExtension:id:)``;
    /// tolerates an already-removed or never-created file.
    static func removeTempUploadFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
