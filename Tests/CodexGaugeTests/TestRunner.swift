import Darwin
import Foundation

@main
struct TestRunner {
    static func main() async {
        let failures = await run(allTests())
        guard failures == 0 else {
            exit(EXIT_FAILURE)
        }
    }

    private static func allTests() -> [TestCase] {
        scaffoldTests() + quotaDomainTests()
    }

    private static func run(_ tests: [TestCase]) async -> Int32 {
        var failureCount: Int32 = 0
        for test in tests {
            failureCount += await run(test)
        }
        return failureCount
    }

    private static func run(_ test: TestCase) async -> Int32 {
        do {
            try await test.body()
            print("PASS \(test.name)")
            return 0
        } catch {
            print("FAIL \(test.name): \(error)")
            return 1
        }
    }
}
