#!/usr/bin/env swift
import AppKit
import Foundation
import WebKit

private struct AuthRequest {
  let requestId: String
  let command: String
  let args: [String]
  let workingDir: String
  let contextDigest: String
  let expiresAtMs: Int64
  let widgetDir: String
}

private struct AuthDecision {
  let status: String
  let reasonCode: String
  let requestId: String
  let contextDigest: String
  let source: String
}

private final class DecisionBridge: NSObject, WKScriptMessageHandler {
  var onDecision: ((String) -> Void)?

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.name != "runSafeCommandDecision" {
      return
    }
    if let body = message.body as? [String: Any], let decision = body["decision"] as? String {
      onDecision?(decision)
    }
  }
}

private final class AuthWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
  private let request: AuthRequest
  private let bridge = DecisionBridge()
  private let webView: WKWebView
  private let maxInjectAttempts = 20
  private var injectAttempts = 0
  private var window: NSWindow?
  private var decided = false
  private var decision: AuthDecision?

  init(request: AuthRequest) {
    self.request = request
    let contentController = WKUserContentController()
    let config = WKWebViewConfiguration()
    config.userContentController = contentController
    webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 520), configuration: config)
    super.init()

    bridge.onDecision = { [weak self] raw in
      self?.handleDecision(raw)
    }
    contentController.add(bridge, name: "runSafeCommandDecision")
    webView.navigationDelegate = self
  }

  func start() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "run_safe_command Authorization"
    window.center()
    window.contentView = webView
    window.delegate = self
    self.window = window

    injectBridgeScripts()
    loadWidget()

    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let delayMs = max(0, request.expiresAtMs - nowMs)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) { [weak self] in
      self?.handleDecision("expired")
    }

    app.run()
  }

  func windowWillClose(_ notification: Notification) {
    handleDecision("denied")
  }

  func getDecision() -> AuthDecision {
    if let decision {
      return decision
    }
    return AuthDecision(
      status: "error",
      reasonCode: "AUTH_PROMPT_RUNTIME_ERROR",
      requestId: request.requestId,
      contextDigest: request.contextDigest,
      source: "wkwebview"
    )
  }

  private func injectBridgeScripts() {
    let bridgeScript = """
    (function(){
      window.runSafeCommandExecute = function(payload){
        window.webkit.messageHandlers.runSafeCommandDecision.postMessage({decision: 'approved', payload: payload});
        return Promise.resolve({ok:true});
      };
      document.addEventListener('DOMContentLoaded', function(){
        var denyBtn = document.getElementById('deny-btn');
        if (denyBtn) {
          denyBtn.addEventListener('click', function(){
            window.webkit.messageHandlers.runSafeCommandDecision.postMessage({decision: 'denied'});
          }, true);
        }
        window.addEventListener('keydown', function(event){
          if (event.key === 'Escape') {
            window.webkit.messageHandlers.runSafeCommandDecision.postMessage({decision: 'denied'});
          }
        }, true);
      });
    })();
    """
    let script = WKUserScript(source: bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    webView.configuration.userContentController.addUserScript(script)
  }

  private func loadWidget() {
    let fileManager = FileManager.default
    let widgetDir = URL(fileURLWithPath: request.widgetDir).resolvingSymlinksInPath()
    let htmlURL = widgetDir.appendingPathComponent("index.html")

    guard fileManager.fileExists(atPath: htmlURL.path) else {
      handleDecision("error")
      return
    }

    webView.loadFileURL(htmlURL, allowingReadAccessTo: widgetDir)
  }

  private func injectRequestPayloadWithRetry() {
    if decided {
      return
    }

    injectAttempts += 1

    let requestPayload: [String: Any] = [
      "request_id": request.requestId,
      "command": request.command,
      "args": request.args,
      "working_dir": request.workingDir,
      "context_digest": request.contextDigest,
      "expires_at_ms": request.expiresAtMs,
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: requestPayload),
          let json = String(data: data, encoding: .utf8) else {
      handleDecision("error")
      return
    }

    let js = "(function(){ if (window.runSafeCommandAuthWidget && typeof window.runSafeCommandAuthWidget.setRequest === 'function') { window.runSafeCommandAuthWidget.setRequest(\(json)); return true; } return false; })();"
    webView.evaluateJavaScript(js) { [weak self] result, _ in
      guard let self else {
        return
      }
      if let ready = result as? Bool, ready {
        return
      }
      if self.injectAttempts < self.maxInjectAttempts {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
          self.injectRequestPayloadWithRetry()
        }
        return
      }
      self.handleDecision("error")
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    injectRequestPayloadWithRetry()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    handleDecision("error")
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    handleDecision("error")
  }

  private func handleDecision(_ raw: String) {
    if decided {
      return
    }
    decided = true

    let normalized = raw.lowercased()
    switch normalized {
    case "approved":
      decision = AuthDecision(status: "approved", reasonCode: "AUTH_PROMPT_APPROVED", requestId: request.requestId, contextDigest: request.contextDigest, source: "wkwebview")
    case "expired", "timeout":
      decision = AuthDecision(status: "expired", reasonCode: "AUTH_PROMPT_TIMEOUT", requestId: request.requestId, contextDigest: request.contextDigest, source: "wkwebview")
    case "denied":
      decision = AuthDecision(status: "denied", reasonCode: "AUTH_PROMPT_DENIED", requestId: request.requestId, contextDigest: request.contextDigest, source: "wkwebview")
    default:
      decision = AuthDecision(status: "error", reasonCode: "AUTH_PROMPT_RUNTIME_ERROR", requestId: request.requestId, contextDigest: request.contextDigest, source: "wkwebview")
    }

    NSApplication.shared.stop(nil)
    window?.orderOut(nil)
  }
}

private func parseRequest() -> AuthRequest? {
  if CommandLine.arguments.count != 8 {
    return nil
  }
  let requestId = CommandLine.arguments[1]
  let command = CommandLine.arguments[2]
  let argsJson = CommandLine.arguments[3]
  let workingDir = CommandLine.arguments[4]
  let contextDigest = CommandLine.arguments[5]
  let expiresAt = Int64(CommandLine.arguments[6]) ?? 0
  let widgetDir = CommandLine.arguments[7]

  guard let data = argsJson.data(using: .utf8),
        let args = try? JSONSerialization.jsonObject(with: data) as? [String] else {
    return nil
  }

  return AuthRequest(
    requestId: requestId,
    command: command,
    args: args,
    workingDir: workingDir,
    contextDigest: contextDigest,
    expiresAtMs: expiresAt,
    widgetDir: widgetDir
  )
}

private func emit(_ decision: AuthDecision, code: Int32) -> Never {
  let payload: [String: Any] = [
    "status": decision.status,
    "reason_code": decision.reasonCode,
    "request_id": decision.requestId,
    "context_digest": decision.contextDigest,
    "source": decision.source,
  ]
  if let data = try? JSONSerialization.data(withJSONObject: payload),
     let json = String(data: data, encoding: .utf8) {
    print(json)
  }
  exit(code)
}

private func run() -> Never {
  guard let request = parseRequest() else {
    exit(12)
  }

  let controller = AuthWindowController(request: request)
  controller.start()
  let decision = controller.getDecision()

  switch decision.status {
  case "approved": emit(decision, code: 0)
  case "denied": emit(decision, code: 10)
  case "expired": emit(decision, code: 11)
  default: emit(decision, code: 12)
  }
}

run()
