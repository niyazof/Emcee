import AutomaticTermination
import DateProviderTestHelpers
import EventBus
import Foundation
import Models
import ModelsTestHelpers
import PortDeterminer
import QueueClient
import QueueServer
import RequestSender
import ScheduleStrategy
import UniqueIdentifierGeneratorTestHelpers
import VersionTestHelpers
import XCTest
import RequestSenderTestHelpers
import TestHelpers

final class QueueServerTests: XCTestCase {
    let eventBus = EventBus()
    let workerConfigurations = WorkerConfigurations()
    let workerId: WorkerId = "workerId"
    let jobId: JobId = "jobId"
    lazy var prioritizedJob = PrioritizedJob(jobId: jobId, priority: .medium)
    let automaticTerminationController = AutomaticTerminationControllerFactory(
        automaticTerminationPolicy: .stayAlive
    ).createAutomaticTerminationController()
    let localPortDeterminer = LocalPortDeterminer(portRange: Ports.allPrivatePorts)
    let bucketSplitInfo = BucketSplitInfoFixtures.bucketSplitInfoFixture()
    let queueVersionProvider = VersionProviderFixture().buildVersionProvider()
    let requestSignature = RequestSignature(value: "expectedRequestSignature")

    let fixedBucketId: BucketId = "fixedBucketId"
    lazy var uniqueIdentifierGenerator = FixedValueUniqueIdentifierGenerator(
        value: fixedBucketId.value
    )

    func test__queue_waits_for_new_workers_and_fails_if_they_not_appear_in_time() {
        workerConfigurations.add(workerId: workerId, configuration: WorkerConfigurationFixtures.workerConfiguration)
        
        let server = QueueServerImpl(
            automaticTerminationController: automaticTerminationController,
            dateProvider: DateProviderFixture(),
            eventBus: eventBus,
            workerConfigurations: workerConfigurations,
            reportAliveInterval: .infinity,
            checkAgainTimeInterval: .infinity, 
            localPortDeterminer: localPortDeterminer,
            workerAlivenessPolicy: .workersTerminateWhenQueueIsDepleted,
            bucketSplitInfo: bucketSplitInfo,
            queueServerLock: NeverLockableQueueServerLock(),
            queueVersionProvider: queueVersionProvider,
            requestSignature: requestSignature,
            uniqueIdentifierGenerator: uniqueIdentifierGenerator
        )
        XCTAssertThrowsError(try server.queueResults(jobId: jobId))
    }
    
    func test__queue_returns_results_after_depletion() throws {
        let testEntry = TestEntryFixtures.testEntry(className: "class", methodName: "test")
        let bucket = BucketFixtures.createBucket(
            bucketId: fixedBucketId,
            testEntries: [testEntry]
        )
        let testEntryConfigurations = TestEntryConfigurationFixtures()
            .add(testEntry: testEntry)
            .testEntryConfigurations()
        let testingResult = TestingResultFixtures()
            .with(testEntry: testEntry)
            .with(bucketId: bucket.bucketId)
            .addingLostResult()
            .testingResult()
        
        workerConfigurations.add(workerId: workerId, configuration: WorkerConfigurationFixtures.workerConfiguration)
        let terminationController = AutomaticTerminationControllerFactory(
            automaticTerminationPolicy: .after(timeInterval: 0.1)
        ).createAutomaticTerminationController()
        let server = QueueServerImpl(
            automaticTerminationController: terminationController,
            dateProvider: DateProviderFixture(),
            eventBus: EventBus(),
            workerConfigurations: workerConfigurations,
            reportAliveInterval: .infinity,
            checkAgainTimeInterval: .infinity,
            localPortDeterminer: localPortDeterminer,
            workerAlivenessPolicy: .workersTerminateWhenQueueIsDepleted,
            bucketSplitInfo: bucketSplitInfo,
            queueServerLock: NeverLockableQueueServerLock(),
            queueVersionProvider: queueVersionProvider,
            requestSignature: requestSignature,
            uniqueIdentifierGenerator: uniqueIdentifierGenerator
        )
        server.schedule(
            bucketSplitter: ScheduleStrategyType.individual.bucketSplitter(
                uniqueIdentifierGenerator: uniqueIdentifierGenerator
            ),
            testEntryConfigurations: testEntryConfigurations,
            prioritizedJob: prioritizedJob
        )
        let queueWaiter = QueueServerTerminationWaiterImpl(
            pollInterval: 0.1,
            queueServerTerminationPolicy: .stayAlive
        )
        
        let expectationForResults = expectation(description: "results became available")
        
        let port = try server.start()
        
        let requestSender = RequestSenderFixtures.localhostRequestSender(port: port)
        let client = synchronousQueueClient(port: port)
        
        let workerRegisterer = WorkerRegistererImpl(requestSender: requestSender)
        
        var actualResults = [JobResults]()
        
        let _: Void = try runSyncronously { [workerId] completion in
            try workerRegisterer.registerWithServer(workerId: workerId) { _ in
                completion(Void())
            }
        }
        
        DispatchQueue.global().async {
            do {
                actualResults.append(
                    try queueWaiter.waitForJobToFinish(
                        queueServer: server,
                        automaticTerminationController: terminationController,
                        jobId: self.jobId
                    )
                )
                expectationForResults.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        
        let fetchResult = try client.fetchBucket(
            requestId: "request",
            workerId: workerId,
            requestSignature: requestSignature
        )
        XCTAssertEqual(fetchResult, SynchronousQueueClient.BucketFetchResult.bucket(bucket))

        let resultSender = BucketResultSenderImpl(
            requestSender: RequestSenderImpl(
                urlSession: URLSession.shared,
                queueServerAddress: queueServerAddress(port: port)
            )
        )
        
        let response: Either<BucketId, RequestSenderError> = try runSyncronously { [workerId, requestSignature] completion in
            try resultSender.send(
                testingResult: testingResult,
                requestId: "request",
                workerId: workerId,
                requestSignature: requestSignature,
                completion: completion
            )
        }
        
        XCTAssertEqual(
            try? response.dematerialize(),
            testingResult.bucketId,
            "Server is expected to return a bucket id of accepted testing result"
        )
        
        wait(for: [expectationForResults], timeout: 10)

        XCTAssertEqual(
            [JobResults(jobId: jobId, testingResults: [testingResult])],
            actualResults
        )
    }
    
    private func synchronousQueueClient(port: Int) -> SynchronousQueueClient {
        return SynchronousQueueClient(queueServerAddress: queueServerAddress(port: port))
    }
    
    private func queueServerAddress(port: Int) -> SocketAddress {
        return SocketAddress(host: "localhost", port: port)
    }
}
