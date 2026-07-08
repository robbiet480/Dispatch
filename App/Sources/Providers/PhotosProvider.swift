import DispatchKit
import Foundation
import Photos

/// Counts photos taken since the last report (falls back to start of today).
struct PhotosProvider: SensorProvider {
    let kind = SensorKind.photos
    let since: Date?

    func capture() async throws -> SensorPayload {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ProviderError("photo library permission denied")
        }
        let cutoff = since ?? Calendar.current.startOfDay(for: Date())
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate > %@ AND mediaType == %d",
                                        cutoff as NSDate, PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: options)
        var records: [PhotoRecord] = []
        assets.enumerateObjects { asset, _, _ in
            var record = PhotoRecord(uniqueIdentifier: asset.localIdentifier)
            record.pixelWidth = asset.pixelWidth
            record.pixelHeight = asset.pixelHeight
            record.dateTime = asset.creationDate
            record.latitude = asset.location?.coordinate.latitude
            record.longitude = asset.location?.coordinate.longitude
            records.append(record)
        }
        return .photos(count: records.count, records: records)
    }
}
