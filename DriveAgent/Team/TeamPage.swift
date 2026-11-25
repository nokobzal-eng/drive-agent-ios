import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/// The team page: the same dashboard as the Android app, shown in a web view. Its buttons call
/// `AgentBoard.<method>(…)`; each call reaches Swift synchronously through a `prompt()` bridge and
/// returns the updated board, so the page redraws at once.
struct TeamPage: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TeamWebView()
                .ignoresSafeArea(edges: .bottom)
                .background(Theme.background.ignoresSafeArea())
                .navigationTitle("הצוות")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("סגור") { dismiss() }
                    }
                }
        }
    }
}

private struct TeamWebView: UIViewRepresentable {
    func makeCoordinator() -> TeamBridge { TeamBridge() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(source: TeamBridge.shim, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(Theme.background)
        web.scrollView.backgroundColor = UIColor(Theme.background)
        web.uiDelegate = context.coordinator
        web.navigationDelegate = context.coordinator
        context.coordinator.attach(web)
        web.loadHTMLString(TeamBridge.pageHTML(), baseURL: nil)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class TeamBridge: NSObject, WKUIDelegate, WKNavigationDelegate, UIDocumentPickerDelegate {
    private static let marker = "__agent__"
    private weak var web: WKWebView?
    private var watch: AnyCancellable?
    private var store: TeamStore { TeamStore.shared }

    static let methods = [
        "board", "reviewing", "setDone", "saveEmployee", "deleteEmployee", "saveTask", "deleteTask",
        "addRecord", "deleteRecord", "requestReview", "exportExcel", "sendLink", "shareLink",
        "importing", "importChat",
    ]

    /// Defines `window.AgentBoard` before the page's own script runs.
    static var shim: String {
        let names = methods.map { "'\($0)'" }.joined(separator: ",")
        return """
        (function () {
          var o = {};
          [\(names)].forEach(function (n) {
            o[n] = function () {
              var r = prompt('\(marker)', JSON.stringify({ m: n, a: Array.prototype.slice.call(arguments) }));
              if (r === '__true__') return true;
              if (r === '__false__') return false;
              return r;
            };
          });
          window.AgentBoard = o;
        })();
        """
    }

    /// The bundled page with today's board and the assistant's name filled in.
    static func pageHTML() -> String {
        guard let url = Bundle.main.url(forResource: "team_dashboard", withExtension: "html"),
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            return "<html><body style='background:#0f1215;color:#e8eaed'>הדף לא נמצא</body></html>"
        }
        let name = SettingsStore.load().assistantName.filter { !"'\"<>\\&".contains($0) }
        let data = TeamStore.shared.pageJSON().replacingOccurrences(of: "</", with: "<\\/")
        return template
            .replacingOccurrences(of: "/*BOARD_DATA*/null", with: data)
            .replacingOccurrences(of: "__NAME__", with: name.isEmpty ? "העוזר" : name)
    }

    func attach(_ web: WKWebView) {
        self.web = web
        // Changes made elsewhere (by voice, a finished review or import) show up right away.
        watch = store.$version
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.run("window.reloadBoard && reloadBoard()") }
            }
    }

    private func run(_ js: String) {
        web?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func toast(_ text: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return }
        run("toast(\(array)[0])")
    }

    // MARK: The bridge

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        guard prompt == Self.marker, frame.isMainFrame,
              let data = defaultText?.data(using: .utf8),
              let call = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let method = call["m"] as? String else {
            return nil
        }
        return handle(method, call["a"] as? [Any] ?? [])
    }

    private func handle(_ method: String, _ args: [Any]) -> String? {
        func s(_ i: Int) -> String { i < args.count ? (args[i] as? String ?? "") : "" }
        func flag(_ b: Bool) -> String { b ? "__true__" : "__false__" }

        switch method {
        case "board":
            break
        case "reviewing":
            return flag(store.reviewing.contains(s(0)))
        case "importing":
            return flag(store.importing)
        case "setDone":
            store.setDone(s(0), args.count > 1 ? (args[1] as? Bool ?? false) : false)
        case "saveEmployee":
            if let e = Self.employee(from: s(0)), !e.name.isEmpty {
                store.saveEmployee(e, originalName: s(1), replace: true)
            }
        case "deleteEmployee":
            store.deleteEmployee(s(0))
        case "saveTask":
            if let t = Self.task(from: s(0)), !t.title.isEmpty { store.saveTask(t) }
        case "deleteTask":
            store.deleteTask(s(0))
        case "addRecord":
            store.addRecord(name: s(0), type: s(1), text: s(2))
        case "deleteRecord":
            store.deleteRecord(name: s(0), id: s(1))
        case "requestReview":
            let name = s(0)
            Task { await store.review(name) }
            return nil
        case "exportExcel":
            share(store.exportCSV())
            return nil
        case "sendLink":
            sendSchedule(to: s(0))
            return nil
        case "shareLink":
            if let text = store.scheduleMessage(for: s(0)) { share([text]) }
            return nil
        case "importChat":
            pickChat()
            return nil
        default:
            return nil
        }
        return store.pageJSON()
    }

    private static func object(_ text: String) -> JSON? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSON
    }

    private static func employee(from text: String) -> Employee? {
        guard let o = object(text) else { return nil }
        func f(_ k: String) -> String { (o[k] as? String ?? "").trimmingCharacters(in: .whitespaces) }
        let days = o["schedule"] as? JSON ?? [:]
        var schedule: [String: String] = [:]
        for d in weekDays { schedule[d] = (days[d] as? String ?? "").trimmingCharacters(in: .whitespaces) }
        return Employee(name: f("name"), area: f("area"), role: f("role"), phone: f("phone"), notes: f("notes"), schedule: schedule)
    }

    private static func task(from text: String) -> TeamTask? {
        guard let o = object(text) else { return nil }
        func f(_ k: String) -> String { (o[k] as? String ?? "").trimmingCharacters(in: .whitespaces) }
        return TeamTask(
            id: f("id"), kind: f("kind"), date: f("date"), title: f("title"), location: f("location"),
            assignee: f("assignee"), details: f("details"), formName: f("formName")
        )
    }

    // MARK: Actions

    /// Opens the employee's WhatsApp chat with their week typed; the owner taps send.
    private func sendSchedule(to name: String) {
        guard let e = store.board.employees.first(where: { $0.name == name }),
              let text = store.scheduleMessage(for: name) else { return }
        guard let number = Opener.internationalNumber(e.phone), let url = Opener.whatsAppURL(number: number, text: text) else {
            share([text])
            return
        }
        Task {
            if !(await UIApplication.shared.open(url)) { toast("וואטסאפ לא נפתח") }
        }
    }

    private func share(_ items: [Any]) {
        guard !items.isEmpty, let top = Self.topController() else { return }
        top.present(UIActivityViewController(activityItems: items, applicationActivities: nil), animated: true)
    }

    private func pickChat() {
        guard !store.importing, let top = Self.topController() else { return }
        let types: [UTType] = [.zip, .plainText, .text]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        guard let chat = ZipText.read(url), !chat.isEmpty else {
            toast("לא מצאתי צ'אט בקובץ הזה")
            return
        }
        let group = TeamStore.groupName(fromFile: url.lastPathComponent)
        toast("קורא את הקבוצה… זה יכול לקחת כמה דקות")
        Task {
            let summary = await store.importChat(chat, group: group)
            toast(summary.map { $0.isEmpty ? "הייבוא הסתיים" : $0 } ?? "הייבוא לא הצליח. נסה שוב.")
        }
    }

    // MARK: Page dialogs and links

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        _ = await ask(message, cancel: nil)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await ask(message, cancel: "ביטול")
    }

    /// A native dialog for the page's alert() / confirm(). True when the user taps "אישור".
    private func ask(_ message: String, cancel: String?) async -> Bool {
        guard let top = Self.topController() else { return false }
        return await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            if let cancel {
                alert.addAction(UIAlertAction(title: cancel, style: .cancel) { _ in waiter.resume(returning: false) })
            }
            alert.addAction(UIAlertAction(title: "אישור", style: cancel == nil ? .default : .destructive) { _ in
                waiter.resume(returning: true)
            })
            top.present(alert, animated: true)
        }
    }

    /// The page stays on itself. Phone, WhatsApp and Waze links open those apps; nothing else loads.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == "about" { return .allow }
        let external = url.scheme == "tel" ||
            (url.scheme == "https" && ["wa.me", "api.whatsapp.com", "waze.com", "www.waze.com"].contains(url.host ?? ""))
        if external { _ = await UIApplication.shared.open(url) }
        return .cancel
    }

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
