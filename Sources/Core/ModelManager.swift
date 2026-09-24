import Foundation
import Combine

/// 模型文件在磁盘上的位置，以及相关的 UserDefaults 键。
///
/// 单独拆出来而不是挂在 `ModelManager` 上：后者是 `@MainActor` 类，它的 static 成员也会
/// 跟着继承隔离，而 background URLSession 的 delegate 回调跑在后台队列上，必须能同步拿到
/// 目标路径 —— 文件搬移要在回调返回前做完，否则系统会删掉临时文件。
enum ModelStorage {
    static let installedVariantKey = "installedModelVariantID"
    static let pendingVariantKey = "pendingModelVariantID"
    static let sessionIdentifier = "io.argoodies.aero.modeldownload"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models", isDirectory: true)
    }

    static func fileURL(for variant: ModelVariant) -> URL {
        directory.appendingPathComponent(variant.fileName)
    }

    /// 剩余可用磁盘空间，用来在下载前提示空间不足。
    static var availableCapacity: Int64? {
        let values = try? directory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// 负责模型权重的下载、校验、存放和删除。
///
/// 用 background URLSession：半 GB 的下载在蜂窝网络上要好几分钟，用户切到别的 app 是常态，
/// 前台 session 一进后台就会被挂起，下到一半的进度全部白费。
@MainActor
final class ModelManager: NSObject, ObservableObject {
    enum State: Equatable {
        case missing
        case downloading(bytesWritten: Int64, bytesTotal: Int64)
        case paused(bytesWritten: Int64, bytesTotal: Int64)
        case verifying
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .missing
    @Published private(set) var installedVariant: ModelVariant?

    /// 在 app 切后台、系统完成下载后唤醒 app 时，由 AppDelegate 交回来的收尾回调。
    var backgroundCompletionHandler: (() -> Void)?

    private var session: URLSession!
    private var activeTask: URLSessionDownloadTask?
    private var resumeData: Data?

    /// 正在下载的档位。存在 UserDefaults 而不是内存里：background session 会在 app 被系统
    /// 杀掉后重新拉起进程并回调 delegate，那时任何实例变量都已经没了。
    /// UserDefaults 本身线程安全，所以 delegate 的后台队列也能直接读。
    private nonisolated var pendingVariant: ModelVariant? {
        get { UserDefaults.standard.string(forKey: ModelStorage.pendingVariantKey).flatMap(ModelCatalog.variant(withID:)) }
        set { UserDefaults.standard.set(newValue?.id, forKey: ModelStorage.pendingVariantKey) }
    }

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: ModelStorage.sessionIdentifier)
        // 模型是 app 能用的前提，不该被系统的"合适时机"策略推迟。
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        refreshInstalledState()
    }

    var installedModelURL: URL? {
        installedVariant.map(ModelStorage.fileURL(for:))
    }

    // MARK: - 状态

    /// 启动时扫描磁盘，判断已经装了哪个档位。
    func refreshInstalledState() {
        let recorded = UserDefaults.standard.string(forKey: ModelStorage.installedVariantKey)
        let candidates = [recorded.flatMap(ModelCatalog.variant(withID:))].compactMap { $0 } + ModelCatalog.all
        for variant in candidates where isFileComplete(variant) {
            installedVariant = variant
            UserDefaults.standard.set(variant.id, forKey: ModelStorage.installedVariantKey)
            state = .ready
            return
        }
        installedVariant = nil
        if case .downloading = state { return }
        state = .missing
    }

    private func isFileComplete(_ variant: ModelVariant) -> Bool {
        let url = ModelStorage.fileURL(for: variant)
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 else {
            return false
        }
        return size == variant.byteCount && hasGGUFMagic(at: url)
    }

    /// 校验文件头。下载中断或者被运营商插了错误页时，文件大小可能巧合对上，但魔数不会。
    private func hasGGUFMagic(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4) else { return false }
        return magic == Data("GGUF".utf8)
    }

    // MARK: - 下载

    func download(_ variant: ModelVariant) {
        guard activeTask == nil else { return }
        do {
            try FileManager.default.createDirectory(at: ModelStorage.directory, withIntermediateDirectories: true)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        pendingVariant = variant
        state = .downloading(bytesWritten: 0, bytesTotal: variant.byteCount)

        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
            self.resumeData = nil
        } else {
            task = session.downloadTask(with: variant.downloadURL)
        }
        activeTask = task
        task.resume()
    }

    func pause() {
        guard let task = activeTask, case .downloading(let written, let total) = state else { return }
        // 立刻交出 activeTask，否则用户手快点了"继续"会撞上 download() 的去重判断。
        activeTask = nil
        state = .paused(bytesWritten: written, bytesTotal: total)
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                self?.resumeData = data
            }
        })
    }

    func resume() {
        guard let variant = pendingVariant, case .paused = state else { return }
        download(variant)
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        resumeData = nil
        pendingVariant = nil
        refreshInstalledState()
    }

    func deleteInstalledModel() {
        guard let variant = installedVariant else { return }
        try? FileManager.default.removeItem(at: ModelStorage.fileURL(for: variant))
        UserDefaults.standard.removeObject(forKey: ModelStorage.installedVariantKey)
        installedVariant = nil
        state = .missing
    }

    // MARK: - 下载完成的收尾

    /// 从后台线程调用：把临时文件搬到最终位置并校验。
    fileprivate nonisolated func install(temporaryURL: URL, variant: ModelVariant) {
        let destination = ModelStorage.fileURL(for: variant)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: ModelStorage.directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            // 必须在 delegate 回调返回前搬走，否则系统会删掉临时文件。
            try fileManager.moveItem(at: temporaryURL, to: destination)

            // 模型可以随时重新下载，不该占用户的 iCloud 备份空间（Apple 也会因此拒审）。
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDestination = destination
            try mutableDestination.setResourceValues(resourceValues)
        } catch {
            Task { @MainActor in
                self.finishFailed(error.localizedDescription)
            }
            return
        }

        Task { @MainActor in
            self.finishInstalled(variant)
        }
    }

    private func finishInstalled(_ variant: ModelVariant) {
        state = .verifying
        activeTask = nil
        resumeData = nil
        guard isFileComplete(variant) else {
            try? FileManager.default.removeItem(at: ModelStorage.fileURL(for: variant))
            state = .failed(String(localized: "下载的文件校验未通过，请重试。"))
            return
        }
        UserDefaults.standard.set(variant.id, forKey: ModelStorage.installedVariantKey)
        installedVariant = variant
        pendingVariant = nil
        state = .ready
    }

    private func finishFailed(_ message: String) {
        activeTask = nil
        state = .failed(message)
    }

    fileprivate func updateProgress(written: Int64, total: Int64) {
        guard case .downloading = state else { return }
        // 服务端偶尔不给 Content-Length，这时用目录里记录的期望大小兜底，进度条才不会卡在 0。
        let expected = total > 0 ? total : (pendingVariant?.byteCount ?? 0)
        state = .downloading(bytesWritten: written, bytesTotal: expected)
    }

    fileprivate func handleTaskCompletion(error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled {
            // 暂停走的也是 cancel，状态已经在 pause() 里设好了，不要覆盖成失败。
            return
        }
        resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        activeTask = nil
        if let resumeData, !resumeData.isEmpty, case .downloading(let written, let total) = state {
            state = .paused(bytesWritten: written, bytesTotal: total)
        } else {
            state = .failed(error.localizedDescription)
        }
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            self.updateProgress(written: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // HuggingFace 在文件不存在时返回 404 的 HTML 页面，不拦住的话会被当成模型存起来。
        if let response = downloadTask.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            Task { @MainActor in
                self.finishFailed(String(localized: "下载失败（HTTP \(response.statusCode)）。"))
            }
            return
        }
        install(temporaryURL: location, variant: pendingVariant ?? ModelCatalog.recommended)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            self.handleTaskCompletion(error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
