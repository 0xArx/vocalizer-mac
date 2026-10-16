// Supreme mode's model (MelBand RoFormer, about 410 MB) is not bundled: the app downloads it once from the
// GitHub release "models-v1" into ~/Library/Application Support/Vocalizer/Supreme, when the user picks Supreme.

import Foundation

public enum SupremeModel {
    public static let downloadURL = URL(string: "https://github.com/0xArx/vocalizer-mac/releases/download/models-v1/MelRoformerVocals.zip")!
    public static let name = "MelRoformerVocals"

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vocalizer/Supreme")
    }

    /// The installed model (downloaded, or bundled in development builds), if any.
    public static func files(bundle: Bundle = .main) -> (model: URL, info: URL)? {
        let fm = FileManager.default
        for dir in [directory, bundle.resourceURL].compactMap({ $0 }) {
            let info = dir.appendingPathComponent("\(name).json")
            for ext in ["mlmodelc", "mlpackage"] {
                let model = dir.appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: model.path) && fm.fileExists(atPath: info.path) { return (model, info) }
            }
        }
        return nil
    }

    /// Downloads and unpacks the model. `progress` is called on the main queue with 0...1.
    public static func download(progress: @escaping (Double) -> Void, done: @escaping (Error?) -> Void) {
        let delegate = DownloadDelegate(progress: progress) { location, error in
            if let error { DispatchQueue.main.async { done(error) }; return }
            do {
                guard let location else { throw NSError(domain: "Supreme", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty download"]) }
                let fm = FileManager.default
                let tmp = directory.deletingLastPathComponent().appendingPathComponent("supreme-unpack")
                try? fm.removeItem(at: tmp)
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", location.path, tmp.path]
                try unzip.run(); unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else { throw NSError(domain: "Supreme", code: 2, userInfo: [NSLocalizedDescriptionKey: "could not unzip the model"]) }
                try? fm.removeItem(at: directory)
                try fm.moveItem(at: tmp, to: directory)
                guard files() != nil else { throw NSError(domain: "Supreme", code: 3, userInfo: [NSLocalizedDescriptionKey: "model files missing after download"]) }
                DispatchQueue.main.async { done(nil) }
            } catch {
                DispatchQueue.main.async { done(error) }
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: downloadURL).resume()
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let progress: (Double) -> Void
        let finish: (URL?, Error?) -> Void
        private var finished = false
        init(progress: @escaping (Double) -> Void, finish: @escaping (URL?, Error?) -> Void) { self.progress = progress; self.finish = finish }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async { self.progress(p) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file is deleted when this returns: unpack synchronously.
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                finished = true
                finish(nil, NSError(domain: "Supreme", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "download failed (HTTP \(http.statusCode))"]))
                return
            }
            finished = true
            finish(location, nil)
            session.finishTasksAndInvalidate()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, !finished { finished = true; finish(nil, error) }
        }
    }
}
