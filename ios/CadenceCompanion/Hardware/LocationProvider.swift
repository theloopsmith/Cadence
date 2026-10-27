import CoreLocation
import Foundation

public struct LocationCoordinate: Equatable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyM: Double
    public let timestamp: Date

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracyM: Double,
        timestamp: Date = Date()
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyM = horizontalAccuracyM
        self.timestamp = timestamp
    }
}

public protocol LocationProvider: AnyObject {
    var currentLocation: LocationCoordinate? { get }
    func requestFreshLocation()
}

public final class MockLocationProvider: LocationProvider {
    public var currentLocation: LocationCoordinate?

    public init(currentLocation: LocationCoordinate? = nil) {
        self.currentLocation = currentLocation
    }

    public func requestFreshLocation() {}
}

public final class LiveLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
    public static let shared = LiveLocationProvider()

    private let manager = CLLocationManager()
    public private(set) var currentLocation: LocationCoordinate?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10.0 // updates every 10 meters
    }

    public func requestAuthorization() {
        #if os(iOS)
        manager.requestWhenInUseAuthorization()
        #endif
        manager.startUpdatingLocation()
    }

    public func requestFreshLocation() {
        #if os(iOS)
        manager.requestLocation()
        #else
        manager.startUpdatingLocation()
        #endif
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        currentLocation = LocationCoordinate(
            latitude: latest.coordinate.latitude,
            longitude: latest.coordinate.longitude,
            horizontalAccuracyM: latest.horizontalAccuracy,
            timestamp: latest.timestamp
        )
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location errors (e.g. GPS unavailable indoors) shouldn't crash;
        // fall alerts proceed with nil or last-known coordinates.
    }
}
