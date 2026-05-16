import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("RuntimeProcessTableSort")
struct RuntimeProcessTableSortTests {
    @Test("Cycles ascending descending and default order")
    func cyclesAscendingDescendingAndDefaultOrder() {
        var sortState = RuntimeProcessTableSortState()
        let rows = [
            sample(pid: 30, name: "zsh", cpu: 2),
            sample(pid: 10, name: "claude", cpu: 50),
            sample(pid: 20, name: "node", cpu: 20),
        ]

        sortState.cycle(column: .cpu)
        #expect(sortState.sorted(rows).map(\.pid) == [30, 20, 10])

        sortState.cycle(column: .cpu)
        #expect(sortState.sorted(rows).map(\.pid) == [10, 20, 30])

        sortState.cycle(column: .cpu)
        #expect(sortState.sorted(rows).map(\.pid) == [30, 10, 20])
    }

    @Test("Switching columns starts ascending")
    func switchingColumnsStartsAscending() {
        var sortState = RuntimeProcessTableSortState(column: .cpu, direction: .descending)
        let rows = [
            sample(pid: 30, name: "zsh", cpu: 2),
            sample(pid: 10, name: "claude", cpu: 50),
            sample(pid: 20, name: "node", cpu: 20),
        ]

        sortState.cycle(column: .name)

        #expect(sortState.column == .name)
        #expect(sortState.direction == .ascending)
        #expect(sortState.sorted(rows).map(\.name) == ["claude", "node", "zsh"])
    }

    private func sample(
        pid: Int32,
        name: String,
        cpu: Double,
        memory: Int64 = 0
    ) -> RuntimeProcessSample {
        RuntimeProcessSample(
            pid: pid,
            parentPID: 1,
            name: name,
            command: name,
            cpuPercent: cpu,
            residentMemoryBytes: memory
        )
    }
}
