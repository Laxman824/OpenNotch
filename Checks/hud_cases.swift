// SystemMonitor pure helpers: AirPods battery parsing, device icons. Run: checks/run.sh
var failed = 0, total = 0
func check(_ name: String, _ got: String?, _ want: String?) {
    total += 1
    if got != want { failed += 1; print("FAIL \(name)\n  want \(want ?? "nil")\n  got  \(got ?? "nil")") }
}
let json = """
{"SPBluetoothDataType":[{"controller_properties":{},"device_connected":[
 {"Laxman's AirPods Pro":{"device_batteryLevelCase":"55%","device_batteryLevelLeft":"80%","device_batteryLevelRight":"79%"}},
 {"MX Master 3":{"device_batteryLevelMain":"64%"}},
 {"Beats Solo":{"device_minorType":"Headphones"}}],
 "device_not_connected":[{"Old AirPods":{"device_batteryLevelLeft":"10%","device_batteryLevelRight":"10%"}}]}]}
""".data(using: .utf8)!
check("airpods", SystemMonitor.battery(in: json, device: "Laxman's AirPods Pro"), "L 80% · R 79%")
check("main", SystemMonitor.battery(in: json, device: "MX Master 3"), "64%")
check("no battery", SystemMonitor.battery(in: json, device: "Beats Solo"), nil)
check("not connected ignored", SystemMonitor.battery(in: json, device: "Old AirPods"), nil)
check("garbage", SystemMonitor.battery(in: Data("nope".utf8), device: "x"), nil)
check("icon pro", SystemMonitor.icon(for: "Laxman's AirPods Pro", bluetooth: true, transport: 0), "airpodspro")
check("icon max", SystemMonitor.icon(for: "AirPods Max", bluetooth: true, transport: 0), "airpodsmax")
check("icon bt", SystemMonitor.icon(for: "JBL Flip", bluetooth: true, transport: 0), "headphones")
check("icon speakers", SystemMonitor.icon(for: "MacBook Pro Speakers", bluetooth: false,
                                          transport: kAudioDeviceTransportTypeBuiltIn), "laptopcomputer")
print(failed == 0 ? "hud: \(total)/\(total) pass" : "hud: \(failed) FAILED")
if failed > 0 { exit(1) }
