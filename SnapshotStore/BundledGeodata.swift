import Foundation

public enum BundledGeodata {
    public static func countryDatabaseURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "Country", withExtension: "mmdb", subdirectory: "Geo")
    }
}
