import Foundation
import Combine
import WalletConnectUtils
import WalletConnectKMS


final class SessionEngine {
    var onSessionRequest: ((Request)->())?
    var onSessionResponse: ((Response)->())?
    var onSessionSettle: ((Session)->())?
    var onSessionRejected: ((String, SessionType.Reason)->())?
    var onSessionUpdateAccounts: ((String, Set<Account>)->())?
    var onSessionExpiry: ((Session) -> ())?
    var onSessionDelete: ((String, SessionType.Reason)->())?
    var onEventReceived: ((String, Session.Event)->())?
    
    private let sequencesStore: SessionSequenceStorage
    private let wcSubscriber: WCSubscribing
    private let relayer: WalletConnectRelaying
    private let kms: KeyManagementServiceProtocol
    private var metadata: AppMetadata
    private var publishers = [AnyCancellable]()
    private let logger: ConsoleLogging
    private let topicInitializer: () -> String

    init(relay: WalletConnectRelaying,
         kms: KeyManagementServiceProtocol,
         subscriber: WCSubscribing,
         sequencesStore: SessionSequenceStorage,
         metadata: AppMetadata,
         logger: ConsoleLogging,
         topicGenerator: @escaping () -> String = String.generateTopic) {
        self.relayer = relay
        self.kms = kms
        self.metadata = metadata
        self.wcSubscriber = subscriber
        self.sequencesStore = sequencesStore
        self.logger = logger
        self.topicInitializer = topicGenerator
        setUpWCRequestHandling()
        setupExpirationHandling()
        restoreSubscriptions()
        
        relayer.onResponse = { [weak self] in
            self?.handleResponse($0)
        }
    }
    
    func setSubscription(topic: String) {
        wcSubscriber.setSubscription(topic: topic)
    }
    
    func hasSession(for topic: String) -> Bool {
        return sequencesStore.hasSequence(forTopic: topic)
    }
    
    func getSettledSessions() -> [Session] {
        sequencesStore.getAll().compactMap {
            guard $0.acknowledged else { return nil }
            return $0.publicRepresentation()
        }
    }
    
    func delete(topic: String, reason: Reason) {
        logger.debug("Will delete session for reason: message: \(reason.message) code: \(reason.code)")
        sequencesStore.delete(topic: topic)
        wcSubscriber.removeSubscription(topic: topic)
        relayer.request(.wcSessionDelete(SessionType.DeleteParams(reason: reason.internalRepresentation())), onTopic: topic)
    }
    
    func ping(topic: String, completion: @escaping ((Result<Void, Error>) -> ())) {
        guard sequencesStore.hasSequence(forTopic: topic) else {
            logger.debug("Could not find session to ping for topic \(topic)")
            return
        }
        relayer.request(.wcSessionPing, onTopic: topic) { [unowned self] result in
            switch result {
            case .success(_):
                logger.debug("Did receive ping response")
                completion(.success(()))
            case .failure(let error):
                logger.debug("error: \(error)")
            }
        }
    }
     
    func updateExpiry(topic: String, by ttl: Int64) throws {
        guard var session = sequencesStore.getSequence(forTopic: topic) else {
            throw WalletConnectError.noSessionMatchingTopic(topic)
        }
        guard session.acknowledged else {
            throw WalletConnectError.sessionNotAcknowledged(topic)
        }
        guard session.selfIsController else {
            throw WalletConnectError.unauthorizedNonControllerCall
        }
        try session.updateExpiry(by: ttl)
        let newExpiry = Int64(session.expiryDate.timeIntervalSince1970 )
        sequencesStore.setSequence(session)
        relayer.request(.wcSessionUpdateExpiry(SessionType.UpdateExpiryParams(expiry: newExpiry)), onTopic: topic)
    }
    
    func request(params: Request) {
        print("will request on session topic: \(params.topic)")
        guard sequencesStore.hasSequence(forTopic: params.topic) else {
            logger.debug("Could not find session for topic \(params.topic)")
            return
        }
        let request = SessionType.RequestParams.Request(method: params.method, params: params.params)
        let sessionRequestParams = SessionType.RequestParams(request: request, chainId: params.chainId)
        let sessionRequest = WCRequest(id: params.id, method: .sessionRequest, params: .sessionRequest(sessionRequestParams))
        relayer.request(topic: params.topic, payload: sessionRequest) { [weak self] result in
            switch result {
            case .success(_):
                self?.logger.debug("Did receive session payload response")
            case .failure(let error):
                self?.logger.debug("error: \(error)")
            }
        }
    }
    
    func respondSessionRequest(topic: String, response: JsonRpcResult) {
        guard sequencesStore.hasSequence(forTopic: topic) else {
            logger.debug("Could not find session for topic \(topic)")
            return
        }
        relayer.respond(topic: topic, response: response) { [weak self] error in
            if let error = error {
                self?.logger.debug("Could not send session payload, error: \(error.localizedDescription)")
            } else {
                self?.logger.debug("Sent Session Payload Response")
            }
        }
    }
    
    func updateAccounts(topic: String, accounts: Set<Account>) throws {
        guard var session = sequencesStore.getSequence(forTopic: topic) else {
            throw WalletConnectError.noSessionMatchingTopic(topic)
        }
        guard session.acknowledged else {
            throw WalletConnectError.sessionNotAcknowledged(topic)
        }
        guard session.selfIsController else {
            throw WalletConnectError.unauthorizedNonControllerCall
        }
        session.updateAccounts(accounts)
        sequencesStore.setSequence(session)
        relayer.request(.wcSessionUpdateAccounts(SessionType.UpdateAccountsParams(accounts: accounts)), onTopic: topic)
    }
    
    func notify(topic: String, params: Session.Event, completion: ((Error?)->())?) {
        guard let session = sequencesStore.getSequence(forTopic: topic), session.acknowledged else {
            logger.debug("Could not find session for topic \(topic)")
            return
        }
        do {
            let params = SessionType.EventParams(type: params.type, data: params.data)
            try validateEvents(session: session, params: params)
            relayer.request(.wcSessionEvent(params), onTopic: topic) { result in
                switch result {
                case .success(_):
                    completion?(nil)
                case .failure(let error):
                    completion?(error)
                }
            }
        } catch let error as WalletConnectError {
            logger.error(error)
            completion?(error)
        } catch {}
    }

    //MARK: - Private
    
    private func setUpWCRequestHandling() {
        wcSubscriber.onReceivePayload = { [unowned self] subscriptionPayload in
            switch subscriptionPayload.wcRequest.params {
            case .sessionSettle(let settleParams):
                wcSessionSettle(payload: subscriptionPayload, settleParams: settleParams)
            case .sessionUpdateAccounts(let updateParams):
                wcSessionUpdate(payload: subscriptionPayload, updateParams: updateParams)
            case .sessionDelete(let deleteParams):
                wcSessionDelete(subscriptionPayload, deleteParams: deleteParams)
            case .sessionRequest(let sessionRequestParams):
                wcSessionRequest(subscriptionPayload, payloadParams: sessionRequestParams)
            case .sessionPing(_):
                wcSessionPing(subscriptionPayload)
            case .sessionUpdateExpiry(let updateExpiryParams):
                wcSessionUpdateExpiry(subscriptionPayload, updateExpiryParams: updateExpiryParams)
            case .sessionEvent(let eventParams):
                wcSessionNotification(subscriptionPayload, notificationParams: eventParams)
            default:
                logger.warn("Warning: Session Engine - Unexpected method type: \(subscriptionPayload.wcRequest.method) received from subscriber")
            }
        }
    }

    func settle(topic: String, proposal: SessionProposal, accounts: Set<Account>) {
        let agreementKeys = try! kms.getAgreementSecret(for: topic)!
        
        let selfParticipant = Participant(publicKey: agreementKeys.publicKey.hexRepresentation, metadata: metadata)
        
        let expectedExpiryTimeStamp = Date().addingTimeInterval(TimeInterval(SessionSequence.defaultTimeToLive))
        guard let relay = proposal.relays.first else {return}
        let settleParams = SessionType.SettleParams(
            relay: relay,
            accounts: accounts,
            methods: proposal.methods,
            events: proposal.events,
            controller: selfParticipant,
            expiry: Int64(expectedExpiryTimeStamp.timeIntervalSince1970))//todo - test expiration times
        let session = SessionSequence(
            topic: topic,
            selfParticipant: selfParticipant,
            peerParticipant: proposal.proposer,
            settleParams: settleParams,
            acknowledged: false)
        
        wcSubscriber.setSubscription(topic: topic)
        sequencesStore.setSequence(session)
        
        relayer.request(.wcSessionSettle(settleParams), onTopic: topic)
    }
    
    private func wcSessionSettle(payload: WCRequestSubscriptionPayload, settleParams: SessionType.SettleParams) {
        logger.debug("Did receive session settle request")
        let topic = payload.topic
        
        let agreementKeys = try! kms.getAgreementSecret(for: topic)!
        
        let selfParticipant = Participant(publicKey: agreementKeys.publicKey.hexRepresentation, metadata: metadata)
        
        let session = SessionSequence(topic: topic,
                                      selfParticipant: selfParticipant,
                                      peerParticipant: settleParams.controller,
                                      settleParams: settleParams,
                                      acknowledged: true)
        
        sequencesStore.setSequence(session)
        relayer.respondSuccess(for: payload)
        onSessionSettle?(session.publicRepresentation())
    }
    
    private func wcSessionUpdate(payload: WCRequestSubscriptionPayload, updateParams: SessionType.UpdateAccountsParams) {
        if !updateParams.isValidParam {
            relayer.respondError(for: payload, reason: .invalidUpdateAccountsRequest)
            return
        }
        let topic = payload.topic
        guard var session = sequencesStore.getSequence(forTopic: topic) else {
            relayer.respondError(for: payload, reason: .noContextWithTopic(context: .session, topic: topic))
                  return
              }
        guard session.peerIsController else {
            relayer.respondError(for: payload, reason: .unauthorizedUpdateRequest(context: .session))
            return
        }
        session.updateAccounts(updateParams.accounts)
        sequencesStore.setSequence(session)
        relayer.respondSuccess(for: payload)
        onSessionUpdateAccounts?(topic, updateParams.accounts)
    }
    
    private func wcSessionUpdateExpiry(_ payload: WCRequestSubscriptionPayload, updateExpiryParams: SessionType.UpdateExpiryParams) {
        let topic = payload.topic
        guard var session = sequencesStore.getSequence(forTopic: topic) else {
            relayer.respondError(for: payload, reason: .noContextWithTopic(context: .session, topic: topic))
            return
        }
        guard session.peerIsController else {
            relayer.respondError(for: payload, reason: .unauthorizedUpdateExpiryRequest)
            return
        }
        do {
            try session.updateExpiry(to: updateExpiryParams.expiry)
        } catch {
            relayer.respondError(for: payload, reason: .invalidUpdateExpiryRequest)
            return
        }
        sequencesStore.setSequence(session)
        relayer.respondSuccess(for: payload)
        onSessionExpiry?(session.publicRepresentation())
    }
    
    private func wcSessionDelete(_ payload: WCRequestSubscriptionPayload, deleteParams: SessionType.DeleteParams) {
        let topic = payload.topic
        guard sequencesStore.hasSequence(forTopic: topic) else {
            relayer.respondError(for: payload, reason: .noContextWithTopic(context: .session, topic: topic))
            return
        }
        sequencesStore.delete(topic: topic)
        wcSubscriber.removeSubscription(topic: topic)
        relayer.respondSuccess(for: payload)
        onSessionDelete?(topic, deleteParams.reason)
    }
    
    private func wcSessionRequest(_ payload: WCRequestSubscriptionPayload, payloadParams: SessionType.RequestParams) {
        let topic = payload.topic
        let jsonRpcRequest = JSONRPCRequest<AnyCodable>(id: payload.wcRequest.id, method: payloadParams.request.method, params: payloadParams.request.params)
        let request = Request(
            id: jsonRpcRequest.id,
            topic: topic,
            method: jsonRpcRequest.method,
            params: jsonRpcRequest.params,
            chainId: payloadParams.chainId)
        
        guard let session = sequencesStore.getSequence(forTopic: topic) else {
            relayer.respondError(for: payload, reason: .noContextWithTopic(context: .session, topic: topic))
            return
        }
        if let chainId = request.chainId {
            guard session.hasPermission(forChain: chainId) else {
                relayer.respondError(for: payload, reason: .unauthorizedTargetChain(chainId))
                return
            }
        }
        guard session.hasPermission(forMethod: request.method) else {
            relayer.respondError(for: payload, reason: .unauthorizedRPCMethod(request.method))
            return
        }
        onSessionRequest?(request)
    }
    
    private func wcSessionPing(_ payload: WCRequestSubscriptionPayload) {
        relayer.respondSuccess(for: payload)
    }
    
    private func wcSessionNotification(_ payload: WCRequestSubscriptionPayload, notificationParams: SessionType.EventParams) {
        let topic = payload.topic
        guard let session = sequencesStore.getSequence(forTopic: topic) else {
            relayer.respondError(for: payload, reason: .noContextWithTopic(context: .session, topic: payload.topic))
            return
        }
        if session.selfIsController {
            guard session.hasPermission(forEvents: notificationParams.type) else {
                relayer.respondError(for: payload, reason: .unauthorizedEventType(notificationParams.type))
                return
            }
        }
        let notification = Session.Event(type: notificationParams.type, data: notificationParams.data)
        relayer.respondSuccess(for: payload)
        onEventReceived?(topic, notification)
    }
    
    private func validateEvents(session: SessionSequence, params: SessionType.EventParams) throws {
        if session.selfIsController {
            return
        } else {
            guard session.events.contains(params.type) else {
                throw WalletConnectError.invalidNotificationType
            }
        }
    }
    
    private func setupExpirationHandling() {
        sequencesStore.onSequenceExpiration = { [weak self] session in
            self?.kms.deletePrivateKey(for: session.participants.`self`.publicKey)
            self?.kms.deleteAgreementSecret(for: session.topic)
        }
    }
    
    private func restoreSubscriptions() {
        relayer.transportConnectionPublisher
            .sink { [unowned self] (_) in
                let topics = sequencesStore.getAll().map{$0.topic}
                topics.forEach{self.wcSubscriber.setSubscription(topic: $0)}
            }.store(in: &publishers)
    }
    
    private func handleResponse(_ response: WCResponse) {
        switch response.requestParams {
        case .sessionSettle:
            handleSessionSettleResponse(topic: response.topic, result: response.result)
        case .sessionUpdateAccounts:
            handleUpdateAccountsResponse(topic: response.topic, result: response.result)
        case .sessionRequest:
            let response = Response(topic: response.topic, chainId: response.chainId, result: response.result)
            onSessionResponse?(response)
        default:
            break
        }
    }
    
    func handleSessionSettleResponse(topic: String, result: JsonRpcResult) {
        guard let session = sequencesStore.getSequence(forTopic: topic) else {return}
        switch result {
        case .response:
            guard var session = sequencesStore.getSequence(forTopic: topic) else {return}
            session.acknowledge()
            sequencesStore.setSequence(session)            
            onSessionSettle?(session.publicRepresentation())
        case .error(let error):
            logger.error("Error - session rejected, Reason: \(error)")
            wcSubscriber.removeSubscription(topic: topic)
            sequencesStore.delete(topic: topic)
            kms.deleteAgreementSecret(for: topic)
            kms.deletePrivateKey(for: session.publicKey!)
        }
    }
    
    private func handleUpdateAccountsResponse(topic: String, result: JsonRpcResult) {
        guard let session = sequencesStore.getSequence(forTopic: topic) else {
            return
        }
        let accounts = session.accounts
        switch result {
        case .response:
            onSessionUpdateAccounts?(topic, accounts)
        case .error:
            logger.error("Peer failed to update state.")
        }
    }
    
//    private func validatePermissions(_ permissions: SessionPermissions) -> Bool {
////        for chainId in permissions.blockchain.chains {
////            if !String.conformsToCAIP2(chainId) {
////                return false
////            }
////        }
//        for method in permissions.jsonrpc.methods {
//            if method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//                return false
//            }
//        }
//        if let notificationTypes = permissions.notifications?.types {
//            for notification in notificationTypes {
//                if notification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//                    return false
//                }
//            }
//        }
//        return true
//    }
}
