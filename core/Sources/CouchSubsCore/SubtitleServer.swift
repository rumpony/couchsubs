// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network

/// TV'de çevirinin oyundaki İngilizce altyazıya göre yeri.
public enum SubtitlePlacement: String, Codable, CaseIterable, Sendable {
    /// İngilizce altyazının üstüne, onu örterek.
    case cover
    /// İngilizce altyazının hemen üstünde.
    case above
    /// İngilizce altyazının hemen altında.
    case below
    /// Ekranda sabit bir yükseklikte (`bottomPercent`).
    case fixed
}

/// TV'de altyazının görünümü.
public struct SubtitleStyle: Codable, Equatable, Sendable {
    /// 36 (küçük), 46 (orta), 58 (büyük), 72 (çok büyük)
    public var fontSize: Int
    /// Sabit yerleşimde altyazının ekranın altından uzaklığı, yüzde.
    public var bottomPercent: Int
    public var placement: SubtitlePlacement
    /// Yazının arkasındaki siyah zeminin koyuluğu, yüzde (0: zemin yok).
    public var background: Int
    public var bold: Bool

    public init(fontSize: Int = 46, bottomPercent: Int = 7, placement: SubtitlePlacement = .cover, background: Int = 72, bold: Bool = false) {
        self.fontSize = fontSize
        self.bottomPercent = bottomPercent
        self.placement = placement
        self.background = background
        self.bold = bold
    }

    private enum CodingKeys: String, CodingKey { case fontSize, bottomPercent, placement, background, bold }

    /// Eski sürümün kaydettiği ayarlarda yeni alanlar yoktur; eksikler varsayılanla dolar.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SubtitleStyle()
        fontSize = try values.decodeIfPresent(Int.self, forKey: .fontSize) ?? defaults.fontSize
        bottomPercent = try values.decodeIfPresent(Int.self, forKey: .bottomPercent) ?? defaults.bottomPercent
        placement = (try? values.decodeIfPresent(SubtitlePlacement.self, forKey: .placement)) ?? defaults.placement
        background = try values.decodeIfPresent(Int.self, forKey: .background) ?? defaults.background
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? defaults.bold
    }

    /// TV'ye giden `style` olayının gövdesi.
    var json: [String: Any] {
        ["fontSize": fontSize, "bottomPercent": bottomPercent, "placement": placement.rawValue,
         "background": max(0, min(100, background)), "bold": bold]
    }
}

/// TV uygulamasının bağlandığı yerel Server-Sent Events sunucusu.
/// `GET /events` akışında `subtitle`, `clear` ve `style` olaylarını yayınlar.
public final class SubtitleServer: @unchecked Sendable {
    public enum ServerError: Error { case failedToStart(String) }

    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "couchsubs.subtitle-server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var lastStyle: SubtitleStyle?
    private var pingTimer: DispatchSourceTimer?
    /// `GET` ile verilen dosyalar: dublaj sesleri ve seslendirme modelinin ses örnekleri.
    private var files: [String: (data: Data, type: String)] = [:]
    private var speechPaths: [String] = []
    private var speechNumber = 0

    public var onClientsChanged: ((Int) -> Void)?

    public init(port: UInt16 = 8787) {
        requestedPort = port
    }

    public var connectedClients: Int {
        queue.sync { clients.count }
    }

    /// Sunucuyu başlatır ve dinlenen portu döner (`port: 0` ise rastgele seçilen port).
    public func start() async throws -> UInt16 {
        let port: NWEndpoint.Port = requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort)!
        // Sessizce kaybolan TV'ler (fişten çekme, Wi-Fi kopması) TCP canlılık denetimiyle fark edilir.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        return try await withCheckedThrowingContinuation { continuation in
            // Durum değişiklikleri seri kuyrukta gelir; devamı yalnız bir kez çağırmak için saklanır.
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let continuation = self.startContinuation else { return }
                switch state {
                case .ready:
                    self.startContinuation = nil
                    self.startPing()
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    // .waiting: port ya da ağ şu an kullanılamıyor; beklemek yerine hata ver ki çağıran başka port denesin.
                    self.startContinuation = nil
                    listener.cancel()
                    continuation.resume(throwing: ServerError.failedToStart(error.localizedDescription))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private var startContinuation: CheckedContinuation<UInt16, Error>?

    public func stop() {
        queue.sync {
            pingTimer?.cancel()
            pingTimer = nil
            listener?.cancel()
            listener = nil
            clients.values.forEach { $0.cancel() }
            clients.removeAll()
        }
    }

    /// `box`: oyundaki İngilizce altyazının ekrandaki yeri (kenarlara oranla); TV çeviriyi buna göre yerleştirir.
    public func sendSubtitle(_ text: String, durationMs: Int = 15000, box: TextBox? = nil) {
        let at = Int(Date().timeIntervalSince1970 * 1000)
        var json: [String: Any] = ["text": text, "duration": durationMs, "at": at]
        if let box { json["box"] = Self.json(box) }
        broadcast(event: "subtitle", json: json)
    }

    /// Dört basamağa yuvarlanır; Decimal, JSON'da 0.80000000000000004 yerine 0.8 yazılsın diye.
    static func json(_ box: TextBox) -> [String: Decimal] {
        let round = { (value: Double) in Decimal(Int((max(0, min(1, value)) * 10000).rounded())) / 10000 }
        return ["left": round(box.left), "top": round(box.top), "right": round(box.right), "bottom": round(box.bottom)]
    }

    /// Shows a trophy card on the TV for a few seconds; it does not touch the subtitle.
    public func sendTrophy(_ trophy: EarnedTrophy, durationMs: Int = 6000) {
        var json: [String: Any] = ["name": trophy.name, "grade": trophy.grade.rawValue, "game": trophy.game, "duration": durationMs]
        if let icon = trophy.iconURL?.absoluteString { json["icon"] = icon }
        broadcast(event: "trophy", json: json)
    }

    public func clear() {
        broadcast(event: "clear", json: [:])
    }

    /// "Ekranı çevir" sonuçları: `screen` olayı her çeviriyi yazının yeri (`box`), tipik satır yüksekliği (`line`,
    /// ekrana oranla) ve çok parçalıysa `paragraphs` ile taşır. TV öncekinin yerine bunları koyar.
    public func sendScreen(_ items: [ScreenTranslation.Item], durationMs: Int) {
        let round = { (value: Double) in Decimal(Int((max(0, min(1, value)) * 10000).rounded())) / 10000 }
        let list: [[String: Any]] = items.map { item in
            var json: [String: Any] = ["box": Self.json(item.box), "line": round(item.lineHeight), "text": item.translation]
            if item.paragraphs { json["paragraphs"] = true }
            return json
        }
        broadcast(event: "screen", json: ["duration": durationMs, "items": list])
    }

    /// TV'deki "ekranı çevir" çevirilerini kaldırır (altyazıya dokunmaz).
    public func clearScreen() {
        broadcast(event: "screen-clear", json: [:])
    }

    /// Dosyayı `path` adresinden verir ("/voices/male_1.wav").
    public func publish(_ data: Data, at path: String, type: String = "audio/wav") {
        queue.async { self.files[path] = (data, type) }
    }

    /// Dublaj sesini TV'ye gönderir: ses `/speech/<n>.wav` adresinden verilir, `speech` olayı adresi bildirir.
    /// Son 16 ses tutulur; TV kopup bağlanınca eskisini istemez.
    public func sendSpeech(_ wav: Data, durationMs: Int) {
        queue.async {
            self.speechNumber += 1
            let path = "/speech/\(self.speechNumber).wav"
            self.files[path] = (wav, "audio/wav")
            self.speechPaths.append(path)
            while self.speechPaths.count > 16 { self.files[self.speechPaths.removeFirst()] = nil }
            self.sendToAll(Data(Self.frame(event: "speech", json: ["url": path, "duration": durationMs]).utf8))
        }
    }

    /// TV'de çalan dublajı durdurur (yeni sahne, oturum sonu).
    public func stopSpeech() {
        broadcast(event: "speech-stop", json: [:])
    }

    public func sendStyle(_ style: SubtitleStyle) {
        queue.async { self.lastStyle = style }
        broadcast(event: "style", json: style.json)
    }

    // MARK: - Bağlantılar

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.route(connection, requestLine: head.components(separatedBy: "\r\n").first ?? "")
            } else if isComplete || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func route(_ connection: NWConnection, requestLine: String) {
        let parts = requestLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]).components(separatedBy: "?")[0] : ""
        let method = parts.first.map(String.init) ?? ""

        if method == "OPTIONS" {
            respondAndClose(connection, status: "204 No Content")
        } else if method == "GET" && path == "/events" {
            openStream(connection)
        } else if method == "GET" && path == "/hello" {
            // TV uygulaması ağdaki bilgisayarı bu yanıtla tanır.
            respondAndClose(connection, status: "200 OK", body: #"{"app":"couchsubs"}"#)
        } else if method == "GET", let file = files[path] {
            respondAndClose(connection, status: "200 OK", data: file.data, type: file.type)
        } else {
            respondAndClose(connection, status: "404 Not Found")
        }
    }

    private func respondAndClose(_ connection: NWConnection, status: String, body: String = "") {
        respondAndClose(connection, status: status, data: Data(body.utf8), type: nil)
    }

    private func respondAndClose(_ connection: NWConnection, status: String, data: Data, type: String?) {
        var head = "HTTP/1.1 \(status)\r\nAccess-Control-Allow-Origin: *\r\n"
        if let type { head += "Content-Type: \(type)\r\nCache-Control: no-cache\r\n" }
        head += "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func openStream(_ connection: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream; charset=utf-8\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: keep-alive\r\n"
        head += "Access-Control-Allow-Origin: *\r\n\r\n"
        head += "retry: 2000\n\n"
        if let style = lastStyle {
            head += Self.frame(event: "style", json: style.json)
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        let id = ObjectIdentifier(connection)
        clients[id] = connection
        notifyClientsChanged()
        watchForClose(connection, id: id)
    }

    /// İstemci bağlantıyı kapattığında listeden çıkarır.
    private func watchForClose(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                connection.cancel()
                if self.clients.removeValue(forKey: id) != nil { self.notifyClientsChanged() }
            } else {
                self.watchForClose(connection, id: id)
            }
        }
    }

    private func notifyClientsChanged() {
        let count = clients.count
        if let handler = onClientsChanged { DispatchQueue.main.async { handler(count) } }
    }

    private func broadcast(event: String, json: [String: Any]) {
        let data = Data(Self.frame(event: event, json: json).utf8)
        queue.async { self.sendToAll(data) }
    }

    /// Gönderim hatası alan bağlantı kopmuş sayılır ve listeden çıkarılır.
    private func sendToAll(_ data: Data) {
        for (id, connection) in clients {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, error != nil else { return }
                connection.cancel()
                if self.clients.removeValue(forKey: id) != nil { self.notifyClientsChanged() }
            })
        }
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.sendToAll(Data(": ping\n\n".utf8)) }
        timer.resume()
        pingTimer = timer
    }

    private static func frame(event: String, json: [String: Any]) -> String {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "event: \(event)\ndata: \(body)\n\n"
    }
}
