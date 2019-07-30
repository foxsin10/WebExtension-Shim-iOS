//
//  Tab.swift
//  HoloflowsKit
//
//  Created by Cirno MainasuK on 2019-6-10.
//

import Foundation
import SafariServices
import WebKit
import ConsolePrint
import SwiftyJSON
import Alamofire


// MARK: - Delegates

public protocol TabDelegate: class {
    func uiDelegate(for tab: Tab) -> WKUIDelegate?
    func navigationDelegate(for tab: Tab) -> WKNavigationDelegate?
    func scriptMessageHandlers(for tab: Tab) -> [String : WKScriptMessageHandler]
    func tab(_ tab: Tab, localStorageManagerForTab: Tab) -> LocalStorageManager

    func tab(_ tab: Tab, shouldActive: Bool)
    func tab(_ tab: Tab, pluginResourceProviderForURL url: URL) -> PluginResourceProvider?
}

extension TabDelegate {
    public func uiDelegate(for tab: Tab) -> WKUIDelegate? { return nil }
    public func navigationDelegate(for tab: Tab) -> WKNavigationDelegate? { return nil }
    public func scriptMessageHandlers(for tab: Tab) -> [String : WKScriptMessageHandler] { return [:] }

    public func tab(_ tab: Tab, shouldActive: Bool) { }
    public func tab(_ tab: Tab, pluginResourceProviderForURL url: URL) -> PluginResourceProvider? { return nil }
}

public protocol TabDownloadsDelegate: class {
    typealias Result = Swift.Result
    
    func tab(_ tab: Tab, willDownloadBlobWithOptions options: WebExtension.Browser.Downloads.Download.Options)
    func tab(_ tab: Tab, didDownloadBlobWithOptions options: WebExtension.Browser.Downloads.Download.Options, result: Result<(Data, URLResponse), Error>)
}

extension TabDownloadsDelegate {
    public func tab(_ tab: Tab, willDownloadBlobWithOptions options: WebExtension.Browser.Downloads.Download.Options) { }
    public func tab(_ tab: Tab, didDownloadBlobWithOptions options: WebExtension.Browser.Downloads.Download.Options, result: Result<(Data, URLResponse), Error>) { }
}

// MARK: - Tab
public class Tab: NSObject {

    weak var tabs: Tabs?

    let session: SessionManager = {
        let configuration = URLSessionConfiguration.ephemeral
//        configuration.httpAdditionalHeaders = ["User-Agent" : self.tabs?.userAgent as Any]
        configuration.httpAdditionalHeaders = ["User-Agent" : "Mozilla/5.0 (iPhone; CPU iPhone OS 12_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"]
        let session = Alamofire.SessionManager(configuration: configuration)
        return session
    }()

    public let id: Int
    public let webView: WKWebView
    public let isActive: Bool

    let plugin: Plugin?
    let userContentController: WKUserContentController

    var uiDelegateProxy: WebViewProxy<WKUIDelegate>?
    var navigationDelegateProxy: WebViewProxy<WKNavigationDelegate>?
    var scriptMessageHandlers: [String : WKScriptMessageHandler] = [:]

    weak var delegate: TabDelegate?
    weak var downloadsDelegate: TabDownloadsDelegate?

    public init(id: Int, plugin: Plugin?, createOptions options: WebExtension.Browser.Tabs.Create.Options? = nil, webViewConfiguration configuration: WKWebViewConfiguration, delegate: TabDelegate? = nil, downloadsDelegate: TabDownloadsDelegate? = nil) {
        self.id = id
        self.plugin = plugin
        self.userContentController = WKUserContentController()
        self.delegate = delegate
        self.downloadsDelegate = downloadsDelegate
        configuration.userContentController = userContentController
        
        let bundle = Bundle(for: Tab.self)

        // FIXME:
        if let bundleURL = bundle.resourceURL?.appendingPathComponent("WebExtensionScripts.bundle"),
        let scriptsBundle = Bundle(url: bundleURL),
        let scriptPath = scriptsBundle.path(forResource: "webextension-shim", ofType: "js"),
        var script = try? String(contentsOfFile: scriptPath) {
            let pattern = """
            const env = location.href.startsWith('holoflows-extension://') && location.href.endsWith('_generated_background_page.html');
            """
            if let patternIndex = script.range(of: pattern)?.upperBound, let plugin = plugin {
                let registerWebExtension: String = """


                    registerWebExtension(
                        '\(plugin.id)',
                        \(plugin.manifest.rawString() ?? ""),
                        \(plugin.resources.rawString() ?? "")
                    )
                """
                script.insert(contentsOf: registerWebExtension, at: patternIndex)
            }
            let hasSchemePrefix = options?.url?.hasPrefix("holoflows-extension://") ?? false
            let injectionTime: WKUserScriptInjectionTime = hasSchemePrefix ? .atDocumentStart : .atDocumentEnd
//            let injectionTime = WKUserScriptInjectionTime.atDocumentEnd
            let userScript = WKUserScript(source: script, injectionTime: injectionTime, forMainFrameOnly: false)
            userContentController.addUserScript(userScript)
        } else {
            assertionFailure()
        }

        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: configuration)
        self.isActive = options?.active ?? true

        super.init()

        uiDelegateProxy = WebViewProxy(self)
        navigationDelegateProxy = WebViewProxy(self)

        webView.setNeedsLayout()
        webView.uiDelegate = uiDelegateProxy as? WKUIDelegate
        webView.navigationDelegate = navigationDelegateProxy as? WKNavigationDelegate
        webView.allowsLinkPreview = false

        for event in ScriptEvent.allCases {
            userContentController.add(self, name: event.rawValue)
        }
        scriptMessageHandlers = delegate?.scriptMessageHandlers(for: self) ?? [:]
        for (name, handler) in scriptMessageHandlers where !ScriptEvent.allCases.contains(where: { $0.rawValue == name }) {
            userContentController.add(handler, name: name)
        }

        if let url = options?.url, let URL = URL(string: url) {
            webView.load(URLRequest(url: URL))
        } else {
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <title>URL not invalid</title>
            </head>
            <body>

            </body>
            </html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    public func resignMessageHandler() {
        for event in ScriptEvent.allCases {
            userContentController.removeScriptMessageHandler(forName: event.rawValue)
        }

        for (name, handler) in scriptMessageHandlers where !ScriptEvent.allCases.contains(where: { $0.rawValue == name }) {
            userContentController.add(handler, name: name)
        }
    }

    deinit {
        webView.removeFromSuperview()
        consolePrint("deinit")
    }

}

extension Tab {

    public func completionHandler(file: String = #file, method: String = #function, line: Int = #line) -> HoloflowsRPC.CompletionHandler {
        return HoloflowsRPC.CompletionHandler(tabMeta: meta, file: file, method: method, line: line)
    }

}


// MARK: - WKScriptMessageHandler
extension Tab: WKScriptMessageHandler {

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let eventType = ScriptEvent(rawValue: message.name) else {
            assertionFailure()
            return
        }
        let messageBody = JSON(rawValue: message.body)?.rawString() ?? ""
        consolePrint("[\(eventType.rawValue)]: \(messageBody.prefix(300))")

        guard let (method, id) = try? HoloflowsRPC.parseRPCMeta(messageBody: messageBody) else {
            //assertionFailure()
            consolePrint(messageBody)
            return
        }

        guard let api = WebExtension.API(method: method) else {
            let result: Result<HoloflowsRPC.Response<WebExtension._Echo>, RPC.Error> = .failure(RPCError.invalidRequest)
            HoloflowsRPC.dispatchResponse(webView: webView, id: id, result: result, completionHandler: completionHandler())
            consolePrint("invalid request")
            return
        }

        switch api {
        case ._echo:                                echo(id: id, messageBody: messageBody)
        case .sendMessage:                          sendMessage(id: id, messageBody: messageBody)
        case .fetch:                                fetch(id: id, messageBody: messageBody)
        case .urlCreateObjectURL:                   URLCreateObjectURL(id: id, messageBody: messageBody)
        case .browserDownloadsDownload:             browserDownloadsDownload(id: id, messageBody: messageBody)
        case .browserRuntimeGetURL:                 browserRuntimeGetURL(id: id, messageBody: messageBody)
        case .browserTabsExecuteScript:             browserTabsExecuteScript(id: id, messageBody: messageBody)
        case .browserTabsCreate:                    browserTabsCreate(id: id, messageBody: messageBody)
        case .browserTabsRemove:                    browserTabsRemove(id: id, messageBody: messageBody)
        case .browserTabsQuery:                     browserTabsQuery(id: id, messageBody: messageBody)
        case .browserTabsUpdate:                    browserTabsUpdate(id: id, messageBody: messageBody)
        case .browserStorageLocalGet:               browserStorageLocalGet(id: id, messageBody: messageBody)
        case .browserStorageLocalSet:               browserStorageLocalSet(id: id, messageBody: messageBody)
        case .browserStorageLocalRemove:            browserStorageLocalRemove(id: id, messageBody: messageBody)
        case .browserStorageLocalClear:             browserStorageLocalClear(id: id, messageBody: messageBody)
        case .websocketCreate:                      websocketCreate(id: id, messageBody: messageBody)
        case .websocketClose:                       websocketClose(id: id, messageBody: messageBody)
        case .websocketSend:                        websocketSend(id: id, messageBody: messageBody)
        }          
    }   // end func userContentController

}

// MARK: - WKUIDelegate
extension Tab: WKUIDelegate {

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, let scheme = url.scheme, scheme.hasPrefix("http") {
            let safariViewController = SFSafariViewController(url: url)
            UIApplication.shared.keyWindow?.rootViewController?.present(safariViewController, animated: true, completion: nil)
        }
        return nil
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        // do nothing
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        // do nothing
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        // do nothing
    }

    public func webViewDidClose(_ webView: WKWebView) {
        consolePrint(webView)
    }

    // Disable link preview

}

// MARK: - WKNavigationDelegate
extension Tab: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        consolePrint(webView.url)

        typealias OnCommitted = WebExtension.Browser.WebNavigation.OnCommitted

        let rpcID = UUID().uuidString
        let onCommitted =  OnCommitted(tab: .init(tabId: id, url: webView.url?.absoluteString ?? ""))
        let request = HoloflowsRPC.ServerRequest(params: onCommitted, id: rpcID)

        HoloflowsRPC.dispathRequest(webView: webView, id: rpcID, request: request, completionHandler: completionHandler())
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // do nothing
    }

    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        // do nothing
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // do nothing
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // do nothing
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // do nothing
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // do nothing
    }

}

// MARK: - Encodable
extension Tab {

    public var meta: Meta {
        return Meta(id: id, url: webView.url?.absoluteString ?? "")
    }

    public struct Meta: Codable {
        let id: Int
        let url: String

        public init(id: Int, url: String) {
            self.id = id
            self.url = url
        }
    }

}
