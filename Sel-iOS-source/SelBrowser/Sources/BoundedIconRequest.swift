import Foundation

// Cancel oversized favicon responses before buffering them into the app's memory.
final class BoundedIconRequest: NSObject, URLSessionDataDelegate {
    private var session: URLSession!
    private var task: URLSessionDataTask!
    private var bytes = Data()
    private var completion: ((Data?) -> Void)?
    private let limit = 256 * 1024
    static func start(_ request: URLRequest, isPrivate: Bool, completion: @escaping (Data?) -> Void) -> URLSessionDataTask {
        let loader = BoundedIconRequest()
        loader.completion = completion
        let configuration = isPrivate ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 2
        loader.session = URLSession(configuration: configuration, delegate: loader, delegateQueue: .main)
        loader.task = loader.session.dataTask(with: request)
        return loader.task
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(nil); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= limit else { task.cancel(); finish(nil); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error == nil && !bytes.isEmpty ? bytes : nil) }
    private func finish(_ data: Data?) {
        guard let callback = completion else { return }
        completion = nil; callback(data); bytes.removeAll(); session.invalidateAndCancel()
    }
}
