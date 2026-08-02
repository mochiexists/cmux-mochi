public import Foundation

/// How a client should react to the outcome of a connection attempt.
public enum ReconnectDecision: Sendable, Equatable {
    /// Try again after this delay.
    case retry(after: TimeInterval)
    /// Stop. The endpoint cryptographically refuted itself, or this device is
    /// no longer authorized — retrying cannot help, and pretending otherwise
    /// spins forever against a wall.
    case stopAndRequirePairing
}

/// Why an attempt ended.
public enum ConnectionAttemptOutcome: Sendable, Equatable {
    /// A round trip completed. Under TLS 1.3 the client's handshake finishes
    /// *before* the server validates the client certificate, so a `.ready`
    /// socket is not proof of admission — only a completed request/response is
    /// (proven in the Phase 0b spike).
    case admitted
    /// The peer presented a key that is not the stored pin.
    case serverPinMismatch
    /// The channel opened but the peer refused this device's certificate or
    /// dropped it immediately — the shape of "revoked or never enrolled".
    case rejectedByPeer
    /// Nothing answered: host down, wrong port, network away.
    case unreachable
}

/// Backoff and give-up rules for reconnecting to a paired Mac.
///
/// Jitter matters here because a fleet (several phones, several Macs) tends to
/// wake at the same instant — after a network change or a Mac restart — and an
/// un-jittered ladder turns that into a synchronized stampede.
public struct ReconnectPolicy: Sendable {
    /// Delay for the first retry.
    public var baseDelay: TimeInterval
    /// Ceiling for exponential growth.
    public var maximumDelay: TimeInterval
    /// Fraction of the delay applied as random jitter (0.0 – 1.0).
    public var jitterFraction: Double
    /// A connection healthy for at least this long resets the ladder.
    public var healthyResetInterval: TimeInterval

    public init(
        baseDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 16,
        jitterFraction: Double = 0.25,
        healthyResetInterval: TimeInterval = 30
    ) {
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.jitterFraction = jitterFraction
        self.healthyResetInterval = healthyResetInterval
    }

    public static let `default` = ReconnectPolicy()

    /// Decides what to do after an attempt.
    ///
    /// - Parameters:
    ///   - outcome: How the attempt ended.
    ///   - attempt: 1-based count of consecutive failures.
    ///   - randomFraction: Injected for deterministic tests; defaults to a
    ///     fresh random value.
    /// - Returns: Retry with a delay, or stop and demand re-pairing.
    public func decision(
        after outcome: ConnectionAttemptOutcome,
        attempt: Int,
        randomFraction: Double = Double.random(in: 0 ... 1)
    ) -> ReconnectDecision {
        switch outcome {
        case .admitted:
            return .retry(after: 0)
        case .serverPinMismatch, .rejectedByPeer:
            // Definitive: the keys disagree. No amount of waiting fixes that,
            // and an automatic retry loop against an impostor is exactly the
            // behavior a squatter would like us to have.
            return .stopAndRequirePairing
        case .unreachable:
            return .retry(after: delay(forAttempt: attempt, randomFraction: randomFraction))
        }
    }

    /// The jittered delay for a given consecutive-failure count.
    public func delay(forAttempt attempt: Int, randomFraction: Double = Double.random(in: 0 ... 1)) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let uncapped = baseDelay * pow(2, Double(min(exponent, 16)))
        let capped = min(uncapped, maximumDelay)
        let clampedFraction = min(max(randomFraction, 0), 1)
        let jitter = capped * jitterFraction * clampedFraction
        return capped + jitter
    }

    /// Whether returning to the foreground should skip the remaining backoff.
    ///
    /// It always should: the user is looking at the app right now, and making
    /// them watch a backoff timer they cannot see is the difference between
    /// "instant" and "flaky" in how the product feels.
    public func shouldBypassBackoffOnForeground() -> Bool { true }
}
