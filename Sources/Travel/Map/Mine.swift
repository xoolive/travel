import AppKit
import MapKit

extension GlobeView.Coordinator {
    // MARK: The user's own aircraft

    static let centerlineTitle = "centerline"
    static let routeTitle = "route"

    func syncMine(_ id: String?, route: [LatLon], note: String?, centerline: [LatLon], on map: MKMapView) {
        mineID = id
        mineNote = note
        let centerSignature = centerline.flatMap { [($0.latitude * 1e4).rounded(), ($0.longitude * 1e4).rounded()] }
        if centerSignature != centerlineSignature {
            centerlineSignature = centerSignature
            if let line = centerlineLine { map.removeOverlay(line) }
            centerlineLine = nil
            if centerline.count >= 2 {
                let coordinates = centerline.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let line = MKGeodesicPolyline(coordinates: coordinates, count: coordinates.count)
                line.title = Self.centerlineTitle
                map.addOverlay(line, level: .aboveLabels)
                centerlineLine = line
            }
        }
        if id == nil, let card = mineCard {
            card.removeFromSuperview()
            mineCard = nil
        } else if id != nil, mineCard == nil {
            let card = HoverCard()
            map.addSubview(card)
            mineCard = card
        }
        // Redrawn when the aircraft has moved by about a kilometre.
        let signature = route.flatMap { [($0.latitude * 100).rounded(), ($0.longitude * 100).rounded()] }
        guard signature != routeSignature else { return }
        routeSignature = signature
        if let line = routeLine { map.removeOverlay(line) }
        routeLine = nil
        guard route.count >= 2 else { return }
        let coordinates = route.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let line = MKGeodesicPolyline(coordinates: coordinates, count: coordinates.count)
        line.title = Self.routeTitle
        map.addOverlay(line, level: .aboveLabels)
        routeLine = line
    }
}
