import BucketQueue
import EventBus
import Extensions
import Foundation
import Logging
import Models
import PortDeterminer
import RESTMethods
import ResultsCollector
import Swifter
import SynchronousWaiter
import WorkerAlivenessTracker

public final class QueueServer {
    private let bucketProvider: BucketProviderEndpoint
    private let bucketQueueFactory: BucketQueueFactory
    private let bucketQueue: BucketQueue
    private let bucketResultRegistrar: BucketResultRegistrar
    private let queueServerVersionHandler = QueueServerVersionEndpoint()
    private let restServer: QueueHTTPRESTServer
    private let resultsCollector = ResultsCollector()
    private let workerAlivenessTracker: WorkerAlivenessTracker
    private let workerAlivenessEndpoint: WorkerAlivenessEndpoint
    private let workerRegistrar: WorkerRegistrar
    private let stuckBucketsPoller: StuckBucketsPoller
    private let newWorkerRegistrationTimeAllowance: TimeInterval
    private let queueExhaustTimeAllowance: TimeInterval
    
    public init(
        eventBus: EventBus,
        workerConfigurations: WorkerConfigurations,
        reportAliveInterval: TimeInterval,
        numberOfRetries: UInt,
        newWorkerRegistrationTimeAllowance: TimeInterval = 60.0,
        queueExhaustTimeAllowance: TimeInterval = .infinity,
        checkAgainTimeInterval: TimeInterval,
        localPortDeterminer: LocalPortDeterminer)
    {
        self.restServer = QueueHTTPRESTServer(localPortDeterminer: localPortDeterminer)
        self.workerAlivenessTracker = WorkerAlivenessTracker(reportAliveInterval: reportAliveInterval, additionalTimeToPerformWorkerIsAliveReport: 10.0)
        self.workerAlivenessEndpoint = WorkerAlivenessEndpoint(alivenessTracker: workerAlivenessTracker)
        self.workerRegistrar = WorkerRegistrar(workerConfigurations: workerConfigurations, workerAlivenessTracker: workerAlivenessTracker)
        self.bucketQueueFactory = BucketQueueFactory(
            workerAlivenessProvider: workerAlivenessTracker,
            testHistoryTracker: TestHistoryTrackerImpl(
                numberOfRetries: numberOfRetries,
                testHistoryStorage: TestHistoryStorageImpl()
            ),
            checkAgainTimeInterval: checkAgainTimeInterval
        )
        self.bucketQueue = bucketQueueFactory.createBucketQueue()
        self.stuckBucketsPoller = StuckBucketsPoller(bucketQueue: bucketQueue)
        self.bucketProvider = BucketProviderEndpoint(bucketQueue: bucketQueue, alivenessTracker: workerAlivenessTracker)
        self.bucketResultRegistrar = BucketResultRegistrar(bucketQueue: bucketQueue, eventBus: eventBus, resultsCollector: resultsCollector, workerAlivenessTracker: workerAlivenessTracker)
        self.newWorkerRegistrationTimeAllowance = newWorkerRegistrationTimeAllowance
        self.queueExhaustTimeAllowance = queueExhaustTimeAllowance
    }
    
    public func start() throws -> Int {
        restServer.setHandler(
            registerWorkerHandler: RESTEndpointOf(actualHandler: workerRegistrar),
            dequeueBucketRequestHandler: RESTEndpointOf(actualHandler: bucketProvider),
            bucketResultHandler: RESTEndpointOf(actualHandler: bucketResultRegistrar),
            reportAliveHandler: RESTEndpointOf(actualHandler: workerAlivenessEndpoint),
            versionHandler: RESTEndpointOf(actualHandler: queueServerVersionHandler)
        )
        
        stuckBucketsPoller.startTrackingStuckBuckets()
        
        let port = try restServer.start()
        log("Started queue server on port \(port)")
        return port
    }
    
    public func add(buckets: [Bucket]) {
        bucketQueue.enqueue(buckets: buckets)
        log("Enqueued \(buckets.count) buckets:")
        for bucket in buckets {
            log("-- \(bucket) with tests:")
            for testEntries in bucket.testEntries { log("-- -- \(testEntries)") }
        }
    }
    
    public func waitForQueueToFinish() throws -> [TestingResult] {
        log("Waiting for workers to appear")
        try SynchronousWaiter.waitWhile(pollPeriod: 1, timeout: newWorkerRegistrationTimeAllowance, description: "Waiting workers to appear") {
            workerAlivenessTracker.hasAnyAliveWorker == false
        }
        
        log("Waiting for bucket queue to exhaust")
        try SynchronousWaiter.waitWhile(pollPeriod: 5, timeout: queueExhaustTimeAllowance, description: "Waiting for queue to exhaust") {
            guard workerAlivenessTracker.hasAnyAliveWorker else { throw QueueServerError.noWorkers }
            return !bucketQueue.state.isDepleted
        }
        log("Bucket queue has exhaust")
        return resultsCollector.collectedResults
    }
}
