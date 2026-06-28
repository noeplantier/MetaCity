import XCTest
@testable import MetaCity

/// Measures real scene-construction cost for each of the 5 bundled districts — how long it takes
/// to turn a `District`'s JSON-decoded buildings/roads/green-zones into actual `SCNNode`s, and how
/// many of each a district produces. This sidesteps needing a live Simulator/device run (and the
/// auth UI in front of every screen) to get genuine, reproducible numbers for "is this district
/// scene expensive to build" — `XCTest.measure` gives real wall-clock timing with proper sampling,
/// not a guess from eyeballing an Instruments trace once.
final class DistrictScenePerformanceTests: XCTestCase {
    private let districtNames = ["KotaTua", "Menteng", "SudirmanThamrin", "Kemang", "Ancol"]

    func test_sceneConstructionCost_perDistrict() throws {
        for name in districtNames {
            guard let district = District.load(named: name) else {
                XCTFail("Could not load district '\(name)' — check it's bundled in MetaCityTests' test target too")
                continue
            }

            var buildingNodeCount = 0
            var roadNodeCount = 0
            var greenZoneNodeCount = 0
            let lodSwitchDistance = CGFloat(district.extent) * 0.09

            let elapsed = ContinuousClock().measure {
                for building in district.buildings {
                    if SharedCityGeometry.makeDistrictBuildingNode(building, lodSwitchDistance: lodSwitchDistance) != nil {
                        buildingNodeCount += 1
                    }
                }
                for road in district.roads {
                    roadNodeCount += SharedCityGeometry.makeDistrictRoadNodes(road).count
                }
                for zone in district.greenZones {
                    if SharedCityGeometry.makeDistrictGreenZoneNode(zone) != nil {
                        greenZoneNodeCount += 1
                    }
                }
            }

            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            print(String(format: "[DistrictScenePerformance] %@: %d building nodes, %d road-segment nodes, %d green-zone nodes — built in %.2fms",
                         name, buildingNodeCount, roadNodeCount, greenZoneNodeCount, milliseconds))

            // A generous ceiling, not a tuned target: this exists to catch a future change that
            // makes scene construction pathologically slow (e.g. an accidental O(n^2) pass over
            // buildings), not to enforce a specific performance budget.
            XCTAssertLessThan(elapsed, .seconds(2), "\(name) scene construction took unexpectedly long: \(milliseconds)ms")
        }
    }

    /// Real per-district complexity, independent of how fast this machine happens to build nodes —
    /// useful on its own as the actual content-density numbers behind the Profile screen's stats.
    func test_realContentCounts_perDistrict() throws {
        var totalBuildings = 0
        var totalRoads = 0
        for name in districtNames {
            guard let district = District.load(named: name) else {
                XCTFail("Could not load district '\(name)'")
                continue
            }
            print("[DistrictContent] \(name): \(district.buildings.count) buildings, \(district.roads.count) roads, \(district.greenZones.count) green zones, extent \(Int(district.extent))m")
            totalBuildings += district.buildings.count
            totalRoads += district.roads.count
        }
        XCTAssertEqual(totalBuildings, District.totalRealBuildingCount)
        XCTAssertEqual(totalRoads, District.totalRealRoadCount)
    }
}
