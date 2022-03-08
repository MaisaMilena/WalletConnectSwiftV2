enum WCMethod {
    case wcPairingPing
    case wcPairingExtend(PairingType.ExtendParams)
    case wcSessionPropose(SessionType.ProposeParams)
    case wcSessionSettle(SessionType.SettleParams)
    case wcSessionUpdate(SessionType.UpdateParams)
    case wcSessionUpgrade(SessionType.UpgradeParams)
    case wcSessionDelete(SessionType.DeleteParams)
    case wcSessionPayload(SessionType.PayloadParams)
    case wcSessionPing
    case wcSessionExtend(SessionType.ExtendParams)
    case wcSessionNotification(SessionType.NotificationParams)
    
    func asRequest() -> WCRequest {
        switch self {
        case .wcPairingPing:
            return WCRequest(method: .pairingPing, params: .pairingPing(PairingType.PingParams()))
        case .wcPairingExtend(let extendParams):
            return WCRequest(method: .pairingExtend, params: .pairingExtend(extendParams))
        case .wcSessionPropose(let proposalParams):
            return WCRequest(method: .sessionPropose, params: .sessionPropose(proposalParams))
        case .wcSessionSettle(let settleParams):
            return WCRequest(method: .sessionSettle, params: .sessionSettle(settleParams))
        case .wcSessionUpdate(let updateParams):
            return WCRequest(method: .sessionUpdate, params: .sessionUpdate(updateParams))
        case .wcSessionUpgrade(let upgradeParams):
            return WCRequest(method: .sessionUpgrade, params: .sessionUpgrade(upgradeParams))
        case .wcSessionDelete(let deleteParams):
            return WCRequest(method: .sessionDelete, params: .sessionDelete(deleteParams))
        case .wcSessionPayload(let payloadParams):
            return WCRequest(method: .sessionPayload, params: .sessionPayload(payloadParams))
        case .wcSessionPing:
            return WCRequest(method: .sessionPing, params: .sessionPing(SessionType.PingParams()))
        case .wcSessionNotification(let notificationParams):
            return WCRequest(method: .sessionNotification, params: .sessionNotification(notificationParams))
        case .wcSessionExtend(let extendParams):
            return WCRequest(method: .sessionExtend, params: .sessionExtend(extendParams))
        }
    }
}
