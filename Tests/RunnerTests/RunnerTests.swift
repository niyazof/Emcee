import EventBus
import Extensions
import Foundation
import Models
import ModelsTestHelpers
import TemporaryStuff
import ResourceLocationResolver
import Runner
import RunnerTestHelpers
import XCTest

public final class RunnerTests: XCTestCase {
    let testEntry = TestEntryFixtures.testEntry()

    let testRunnerProvider = FakeTestRunnerProvider()
    var tempFolder = try! TemporaryFolder()
    let resolver = ResourceLocationResolver()
    
    func test___running_test_without_output_to_stream___provides_test_did_not_run_results() throws {
        testRunnerProvider.predefinedFakeTestRunner.disableTestStartedTestRunnerStreamEvents()
        testRunnerProvider.predefinedFakeTestRunner.disableTestStoppedTestRunnerStreamEvents()

        let runnerResults = try runTestEntries([testEntry])
        
        XCTAssertEqual(runnerResults.testEntryResults.count, 1)

        guard runnerResults.testEntryResults.count == 1, let testResult = runnerResults.testEntryResults.first else {
            return XCTFail("Unexpected number of test results")
        }

        XCTAssertFalse(testResult.succeeded)
        XCTAssertEqual(testResult.testEntry, testEntry)
        XCTAssertEqual(testResult.testRunResults[0].exceptions[0].reason, RunnerConstants.testDidNotRun.rawValue)
    }

    func test___running_test_with_successful_result___provides_successful_results() throws {
        let runnerResults = try runTestEntries([testEntry])

        guard runnerResults.testEntryResults.count == 1, let testResult = runnerResults.testEntryResults.first else {
            return XCTFail("Unexpected number of test results")
        }

        XCTAssertTrue(testResult.succeeded)
        XCTAssertEqual(testResult.testEntry, testEntry)
    }

    func test___running_test_with_failing_result___provides_test_failed_result() throws {
        testRunnerProvider.predefinedFakeTestRunner.onExecuteTest = { _ in .failure }

        let runnerResults = try runTestEntries([testEntry])

        guard runnerResults.testEntryResults.count == 1, let testResult = runnerResults.testEntryResults.first else {
            return XCTFail("Unexpected number of test results")
        }

        XCTAssertFalse(testResult.succeeded)
        XCTAssertEqual(testResult.testEntry, testEntry)
    }

    func test___running_test_with_lost_result___provides_successful_results() throws {
        testRunnerProvider.predefinedFakeTestRunner.onExecuteTest = { _ in .lost }

        let runnerResults = try runTestEntries([testEntry])

        guard runnerResults.testEntryResults.count == 1, let testResult = runnerResults.testEntryResults.first else {
            return XCTFail("Unexpected number of test results")
        }

        XCTAssertFalse(testResult.succeeded)
        XCTAssertEqual(testResult.testEntry, testEntry)
    }

    func test___running_test_without_stop_event_output_to_stream___revives_and_attempts_to_run_it_again() throws {
        testRunnerProvider.predefinedFakeTestRunner.disableTestStoppedTestRunnerStreamEvents()

        var numberOfAttemptsToRunTest = 0
        testRunnerProvider.predefinedFakeTestRunner.onExecuteTest = { _ in
            numberOfAttemptsToRunTest += 1
            return .success
        }

        let runnerResults = try runTestEntries([testEntry])

        XCTAssertEqual(numberOfAttemptsToRunTest, 2)

        guard runnerResults.testEntryResults.count == 1, let testResult = runnerResults.testEntryResults.first else {
            return XCTFail("Unexpected number of test results")
        }

        XCTAssertFalse(testResult.succeeded)
        XCTAssertEqual(testResult.testEntry, testEntry)
        XCTAssertEqual(testResult.testRunResults[0].exceptions[0].reason, RunnerConstants.testDidNotRun.rawValue)
    }

    func test___running_test_and_reviving_after_test_stopped_event_loss___provides_back_correct_result() throws {
        var didRevive = false
        testRunnerProvider.predefinedFakeTestRunner.onExecuteTest = { _ in
            didRevive = true
            return .success
        }

        testRunnerProvider.predefinedFakeTestRunner.onTestStopped = { testStoppedEvent, testRunnerStream in
            // simulate situation when first testStoppedEvent gets lost
            if didRevive {
                let handler = FakeTestRunner.testStoppedHandlerForNormalEventStreaming()
                handler(testStoppedEvent, testRunnerStream)
            }
        }

        let runnerResults = try runTestEntries([testEntry])

        guard runnerResults.testEntryResults.count == 1, let testResult = runnerResults.testEntryResults.first else {
            return XCTFail("Unexpected number of test results")
        }

        XCTAssertTrue(testResult.succeeded)
        XCTAssertEqual(testResult.testEntry, testEntry)
    }

    private func runTestEntries(_ testEntries: [TestEntry]) throws -> RunnerRunResult {
        let runner = Runner(
            eventBus: EventBus(),
            configuration: try createRunnerConfig(),
            tempFolder: tempFolder,
            testRunnerProvider: testRunnerProvider,
            resourceLocationResolver: resolver
        )
        return try runner.run(
            entries: testEntries,
            developerDir: .current,
            simulatorInfo: SimulatorInfo(
                simulatorUuid: UUID(),
                simulatorSetPath: tempFolder.absolutePath.pathString,
                testDestination: TestDestinationFixtures.testDestination
            )
        )
    }

    private func createRunnerConfig() throws -> RunnerConfiguration {
        return RunnerConfiguration(
            testType: .logicTest,
            testRunnerTool: TestRunnerToolFixtures.fakeFbxctestTool,
            buildArtifacts: BuildArtifactsFixtures.fakeEmptyBuildArtifacts(),
            environment: [:],
            simulatorSettings: SimulatorSettingsFixtures().simulatorSettings(),
            testTimeoutConfiguration: TestTimeoutConfiguration(
                singleTestMaximumDuration: 5,
                testRunnerMaximumSilenceDuration: 0
            )
        )
    }
}
