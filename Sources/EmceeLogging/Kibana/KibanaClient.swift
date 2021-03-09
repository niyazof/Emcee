import DateProvider
import Foundation
import SocketModels

public protocol KibanaClient {
    func send(level: String, message: String, metadata: [String: String], completion: @escaping (Error?) -> ()) throws
}

public struct KibanaHttpEndpoint {
    public enum Scheme: String {
        case http
        case https
    }
    
    public let scheme: Scheme
    public let socketAddress: SocketAddress
    
    public static func from(url: URL) throws -> Self {
        struct UnsupportedUrlError: Error, CustomStringConvertible {
            let url: URL
            var description: String { "URL \(url) cannot be used as a HTTP Kibana endpoint" }
        }
        
        let scheme: Scheme
        var port: SocketModels.Port
        switch url.scheme {
        case "http":
            scheme = .http
            port = 80
        case "https":
            scheme = .https
            port = 443
        default:
            throw UnsupportedUrlError(url: url)
        }
        guard let host = url.host else { throw UnsupportedUrlError(url: url) }
        if let specificPort = url.port {
            port = SocketModels.Port(value: specificPort)
        }
        
        return Self(scheme: scheme, socketAddress: SocketAddress(host: host, port: port))
    }
    
    public static func http(_ socketAddress: SocketAddress) -> Self {
        KibanaHttpEndpoint(scheme: .http, socketAddress: socketAddress)
    }
    
    public static func https(_ socketAddress: SocketAddress) -> Self {
        KibanaHttpEndpoint(scheme: .https, socketAddress: socketAddress)
    }
    
    public func singleEventUrl(indexPattern: String, date: Date) throws -> URL {
        struct FailedToBuildUrlError: Error, CustomStringConvertible {
            let scheme: Scheme
            let socketAddress: SocketAddress
            let path: String
            var description: String { "Cannot build URL with scheme \(scheme), address \(socketAddress), path \(path)" }
        }
        
        let path = "/\(indexPattern)/_doc"
        
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = socketAddress.host
        components.port = socketAddress.port.value
        components.path = path
        guard let url = components.url else {
            throw FailedToBuildUrlError(scheme: scheme, socketAddress: socketAddress, path: path)
        }
        return url
    }
}

public final class HttpKibanaClient: KibanaClient {
    private let dateProvider: DateProvider
    private let endpoints: [KibanaHttpEndpoint]
    private let indexPattern: String
    private let urlSession: URLSession
    private let jsonEncoder = JSONEncoder()
    
    private let timestampDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    
    public init(
        dateProvider: DateProvider,
        endpoints: [KibanaHttpEndpoint],
        indexPattern: String,
        urlSession: URLSession
    ) throws {
        guard !endpoints.isEmpty else { throw KibanaClientEndpointError() }
        
        self.dateProvider = dateProvider
        self.endpoints = endpoints
        self.indexPattern = indexPattern
        self.urlSession = urlSession
    }
    
    public struct KibanaClientEndpointError: Error, CustomStringConvertible {
        public var description: String {
            "No endpoint provided for kibana client. At least a single endpoint must be provided."
        }
    }
    
    public func send(
        level: String,
        message: String,
        metadata: [String : String],
        completion: @escaping (Error?) -> ()
    ) throws {
        let timestamp = dateProvider.currentDate()
        
        var params: [String: String] = [
            "@timestamp": timestampDateFormatter.string(from: timestamp),
            "level": level,
            "message": message,
        ]
        
        params.merge(metadata) { current, _ in current }
        
        guard let endpoint = endpoints.randomElement() else { throw KibanaClientEndpointError() }
        
        var request = URLRequest(
            url: try endpoint.singleEventUrl(
                indexPattern: indexPattern,
                date: timestamp
            )
        )
        request.httpMethod = "POST"
        request.httpBody = try jsonEncoder.encode(params)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let task = urlSession.dataTask(with: request) { _, _, error in
            completion(error)
        }
        task.resume()
    }
}
