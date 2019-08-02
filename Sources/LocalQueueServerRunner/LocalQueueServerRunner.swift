import AutomaticTermination
import DateProvider
import EventBus
import Foundation
import Logging
import Models
import PortDeterminer
import QueueServer
import ScheduleStrategy
import SynchronousWaiter
import UniqueIdentifierGenerator
import Version

public final class LocalQueueServerRunner {
    private let queueServer: QueueServer
    private let automaticTerminationController: AutomaticTerminationController
    private let queueServerTerminationWaiter: QueueServerTerminationWaiter
    private let queueServerTerminationPolicy: AutomaticTerminationPolicy

    public init(
        queueServer: QueueServer,
        automaticTerminationController: AutomaticTerminationController,
        queueServerTerminationWaiter: QueueServerTerminationWaiter,
        queueServerTerminationPolicy: AutomaticTerminationPolicy
    ) {
        self.queueServer = queueServer
        self.automaticTerminationController = automaticTerminationController
        self.queueServerTerminationWaiter = queueServerTerminationWaiter
        self.queueServerTerminationPolicy = queueServerTerminationPolicy
    }
    
    public func start() throws {
        _ = try queueServer.start()
        try queueServerTerminationWaiter.waitForAllJobsWillBeDone(
            queueServer: queueServer,
            automaticTerminationController: automaticTerminationController
        )
        try waitForAllJobsToBeDeleted(
            queueServer: queueServer,
            timeout: queueServerTerminationPolicy.period
        )
    }
    
    private func waitForAllJobsToBeDeleted(queueServer: QueueServer, timeout: TimeInterval) throws {
        try SynchronousWaiter.waitWhile(pollPeriod: pollPeriod, timeout: timeout, description: "Wait for all jobs to be deleted") {
            !queueServer.ongoingJobIds.isEmpty
        }
    }
    
}
