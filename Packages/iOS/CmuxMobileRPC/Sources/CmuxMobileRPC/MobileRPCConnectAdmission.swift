enum MobileRPCConnectAdmission: Sendable, Equatable {
    case granted(MobileRPCConnectAttemptLease)
    case rejected
    case busy
    case cleanupBlocked
}
