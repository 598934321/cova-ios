@testable import CovaCore
import Foundation
import XCTest

final class HTTPTransportTests: XCTestCase {
    private let url = URL(string: "https://covalink.cn/api/tracks/1")!

    func testTimeoutConstantMatchesContract() {
        XCTAssertEqual(URLSessionTransport.timeout, 15)
    }

    func testDefaultSessionUsesEphemeralConfigWithoutCache() {
        let session = URLSessionTransport.makeDefaultSession()
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 15)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testMakeURLRequestCarriesMethodHeadersBodyAndTimeout() throws {
        let request = HTTPRequest(
            method: .post,
            url: url,
            headers: ["Authorization": "Bearer token-1", "Content-Type": "application/json"],
            body: Data(#"{"a":1}"#.utf8)
        )
        let urlRequest = URLSessionTransport.makeURLRequest(request)
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.timeoutInterval, 15)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(urlRequest.httpBody, Data(#"{"a":1}"#.utf8))
    }

    func testMapResponseExtractsStatusCodeAndBody() throws {
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
        let mapped = try URLSessionTransport.map(data: Data("body".utf8), response: response)
        XCTAssertEqual(mapped.statusCode, 404)
        XCTAssertEqual(mapped.body, Data("body".utf8))
    }

    func testMapResponseRejectsNonHTTPResponse() {
        let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        XCTAssertThrowsError(try URLSessionTransport.map(data: Data(), response: response)) { error in
            XCTAssertEqual(error as? CovaAPIError, .invalidResponse)
        }
    }

    func testNormalizePassesThroughCovaAPIError() {
        XCTAssertEqual(CovaAPIError.normalize(CovaAPIError.timeout), .timeout)
    }

    func testNormalizeMapsCancellationError() {
        XCTAssertEqual(CovaAPIError.normalize(CancellationError()), .cancelled)
    }

    func testNormalizeMapsURLErrorsByCode() {
        XCTAssertEqual(CovaAPIError.normalize(URLError(.timedOut)), .timeout)
        XCTAssertEqual(CovaAPIError.normalize(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(CovaAPIError.normalize(URLError(.cancelled)), .cancelled)
    }

    func testNormalizeMapsUnknownErrorToTransportCode() {
        let error = NSError(domain: "probe.domain", code: 4321)
        XCTAssertEqual(CovaAPIError.normalize(error), .transport(code: 4321))
    }

    func testRequestDescriptionAndMirrorNeverExposeHeadersOrBody() {
        let token = "LEAK-REQUEST-TOKEN"
        let body = "LEAK-REQUEST-BODY"
        let request = HTTPRequest(
            method: .post,
            url: url,
            headers: ["Authorization": "Bearer \(token)", "X-Probe": body],
            body: Data(body.utf8)
        )
        let rendered = renderAllSurfaces(request)
        XCTAssertFalse(rendered.contains(token), "请求描述泄漏 header：\(rendered)")
        XCTAssertFalse(rendered.contains(body), "请求描述泄漏 body：\(rendered)")
        XCTAssertTrue(request.description.contains("POST"))
        XCTAssertTrue(request.description.contains("/api/tracks/1"))
        XCTAssertEqual(request.debugDescription, request.description)
    }

    func testResponseDescriptionAndMirrorNeverExposeBody() {
        let secret = "https://cdn.invalid/audio/x.mp3?signature=LEAK-SIGNED-URL"
        let response = HTTPResponse(statusCode: 200, body: Data(secret.utf8))
        let rendered = renderAllSurfaces(response)
        XCTAssertFalse(rendered.contains(secret), "响应描述泄漏 body：\(rendered)")
        XCTAssertEqual(response.description, "HTTPResponse(status: 200)")
    }
}
