import Foundation

// MARK: - BackendLifecycleClient

/// Async REST client for the LFG-98 backend lifecycle Phoenix endpoint.
///
/// Posts typed `devdrive.lifecycle.*` events to APM at `http://localhost:3032/api/notify`.
/// When the endpoint is unreachable (connection refused or 5xx), events are appended to
/// `~/.config/lfg/apm-outbox.jsonl` for replay on next successful connectivity (US-A-005 AC-4).
///
/// This class is `Sendable` — all mutation goes through `URLSession.shared` (Sendable) and
/// the outbox append, which is append-only on a stable file path. The `static let shared`
/// singleton is safe for concurrent callers.
///
/// Usage:
/// ```swift
/// await BackendLifecycleClient.shared.transition(
///     backendId: "901DEVLIB",
///     from: "BackendRebuilt",
///     to: "Reclaimed",
///     evidence: ["rsync_rc": "0", "diff_rc": "0"]
/// )
/// ```
public final class BackendLifecycleClient: Sendable {

    // MARK: Singleton

    public static let shared = BackendLifecycleClient()

    // MARK: Configuration

    private let apmBaseURL: URL
    private let outboxURL: URL

    // MARK: Init

    public init(
        apmBaseURL: URL = URL(string: "http://localhost:3032")!
    ) {
        self.apmBaseURL = apmBaseURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.outboxURL = home.appendingPathComponent(".config/lfg/apm-outbox.jsonl")
    }

    // MARK: - Public API

    /// Posts a state-machine transition event to APM.
    ///
    /// Event name: `devdrive.lifecycle.<toState>` (lowercased).
    ///
    /// On network failure or 5xx response, the event is written to
    /// `~/.config/lfg/apm-outbox.jsonl` (one JSON object per line) for later
    /// replay by `APMOutbox`.
    ///
    /// - Parameters:
    ///   - backendId: The volume backend id (e.g. `"901DEVLIB"`).
    ///   - fromState: The `BackendState` name the transition originated from.
    ///   - toState: The `BackendState` name the transition is moving to.
    ///   - evidence: Arbitrary key-value pairs (rsync exit codes, stderr excerpts, etc.).
    public func transition(
        backendId: String,
        from fromState: String,
        to toState: String,
        evidence: [String: String] = [:]
    ) async {
        let eventName = "devdrive.lifecycle.\(toState.lowercased())"
        let payload: [String: Any] = [
            "event": eventName,
            "volume_id": backendId,
            "from_state": fromState,
            "to_state": toState,
            "evidence": evidence,
            "producer_pipeline": "LFGApp.MountOrchestrator",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        let notifyURL = apmBaseURL.appendingPathComponent("api/notify")
        do {
            var request = URLRequest(url: notifyURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 3.0

            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
                appendToOutbox(payload)
            }
        } catch {
            appendToOutbox(payload)
        }
    }

    /// Posts a corruption-class event when a backend fails to attach.
    ///
    /// Convenience wrapper that builds a typed `devdrive.lifecycle.degraded` event
    /// carrying the full `CorruptionSignature` encoded as evidence.
    ///
    /// - Parameters:
    ///   - backendId: The backend whose attach failed.
    ///   - corruptionClass: The classifier verdict.
    ///   - signature: The raw 3-tuple that produced the verdict.
    public func reportCorruption(
        backendId: String,
        corruptionClass: CorruptionClass,
        signature: CorruptionSignature
    ) async {
        var evidence: [String: String] = [
            "corruption_class": corruptionClass.rawValue,
            "corruption_display": corruptionClass.displayName,
            "container_visible": String(signature.containerVisible)
        ]
        if let errno = signature.hdiutilErrno {
            evidence["hdiutil_errno"] = String(errno)
        }

        await transition(
            backendId: backendId,
            from: "Healthy",
            to: "Degraded",
            evidence: evidence
        )
    }

    /// Returns the current lifecycle state for a backend from the APM store.
    ///
    /// Returns `nil` when the APM server is unreachable or the backend has no record.
    public func getState(backendId: String) async -> String? {
        let url = apmBaseURL
            .appendingPathComponent("api/lifecycle/\(backendId)")
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? String
        else { return nil }
        return state
    }

    // MARK: - Outbox

    /// Appends a failed event to the JSONL outbox for later replay.
    ///
    /// Each line is a self-contained JSON object. The file is created if absent.
    /// Appends are not atomic at the OS level but are append-only, so concurrent
    /// writers produce interleaved lines that are individually valid JSON (since
    /// each line ends with `\n`).
    private func appendToOutbox(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8)
        else { return }

        // Ensure the directory exists.
        let dir = outboxURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let lineWithNewline = line + "\n"
        guard let lineData = lineWithNewline.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: outboxURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(lineData)
        } else {
            // File does not exist yet — create it.
            try? lineData.write(to: outboxURL, options: .atomic)
        }
    }
}
