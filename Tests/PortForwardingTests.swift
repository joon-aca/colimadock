import Darwin
import XCTest
@testable import ColimaDock

@MainActor
final class PortForwardingTests: XCTestCase {
    func testPublishedTCPPortsComeFromDockerPsPortsColumn() {
        XCTAssertEqual(PublishedPorts.tcp("0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp"), [5432])
        XCTAssertEqual(PublishedPorts.tcp("127.0.0.1:18081->80/tcp, :::18080->80/tcp"), [18080, 18081])
        XCTAssertEqual(PublishedPorts.tcp("0.0.0.0:8000-8002->8000-8002/tcp"), [8000, 8001, 8002])
        XCTAssertEqual(PublishedPorts.tcp("6379/tcp, 0.0.0.0:53->53/udp"), [], "unpublished and UDP ports are skipped")
        XCTAssertEqual(PublishedPorts.tcp("0.0.0.0:1000-1999->1000-1999/tcp"), [], "a huge range is skipped")
        XCTAssertEqual(PublishedPorts.tcp(""), [])
        XCTAssertEqual(PublishedPorts.tcp("0.0.0.0:0->80/tcp, garbage, 0.0.0.0:9-8->80/tcp"), [])
    }

    func testOnlyRunningContainersPublish() {
        let containers = ColimaRuntime.parseContainers("""
            {"ID":"a1","Names":"postgres","State":"running","Ports":"0.0.0.0:5432->5432/tcp"}
            {"ID":"b2","Names":"old-web","State":"exited","Ports":""}
            {"ID":"c3","Names":"web","State":"running","Ports":"0.0.0.0:8080->80/tcp, [::]:8080->80/tcp"}
            """)
        XCTAssertEqual(RemoteColima.publishedPorts(containers), [5432: "postgres", 8080: "web"])
    }

    func testPublishedPortsUseTheSameLocalPortAndConfiguredForwardsWin() throws {
        let configured = try XCTUnwrap(LocalForward.parse("29120:19120, 5432:15432"))
        let plan = RemoteTunnel.plan(configured: configured, published: [8080: "web", 5432: "postgres"])
        XCTAssertEqual(plan.map(\.label), ["29120:19120", "5432:15432", "8080:8080"])
    }

    func testDetectsALocalPortAlreadyInUse() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        XCTAssertTrue(bound)
        let port = UInt16(bigEndian: address.sin_port)
        XCTAssertTrue(RemoteTunnel.localPortInUse(port))
        close(fd)
        XCTAssertFalse(RemoteTunnel.localPortInUse(port))
    }
}
