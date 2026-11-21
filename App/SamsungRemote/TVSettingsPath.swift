/// Where settings live in the TV's own menus. The app's copy names these in several places, so they are
/// defined once. "Older" paths are for pre-2022 models.
enum TVSettingsPath {
    static let deviceList = "Settings → All Settings → Connection → External Device Manager → Device Connect Manager → Device List"
    static let deviceListOlder = "Settings → General → External Device Manager → Device Connect Manager → Device List"
    static let powerOnWithMobile = "Settings → All Settings → Connection → Network → Expert Settings → Power On with Mobile"
    static let powerOnWithMobileOlder = "Settings → General → Network → Expert Settings → Power On with Mobile"
    static let airPlay = "Settings → All Settings → Connection → Apple AirPlay Settings"
    static let ipAddress = "Settings → All Settings → Connection → Network → Network Status → IP Settings"
}
