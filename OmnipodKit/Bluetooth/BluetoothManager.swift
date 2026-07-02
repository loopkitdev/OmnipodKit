//
//  BluetoothManager.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/BluetoothManager.swift
//  Created by Randall Knutson on 10/10/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import LoopKit
import os.log

enum BluetoothManagerError: Error {
    case bluetoothNotAvailable(CBManagerState)
}

extension BluetoothManagerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .bluetoothNotAvailable(let state):
            switch state {
            case .poweredOff:
                return LocalizedString("Bluetooth is powered off", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.poweredOff)")
            case .resetting:
                return LocalizedString("Bluetooth is resetting", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.resetting)")
            case .unauthorized:
                return LocalizedString("Bluetooth use is unauthorized", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unauthorized)")
            case .unsupported:
                return LocalizedString("Bluetooth use unsupported on this device", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unsupported)")
            case .unknown:
                return LocalizedString("Bluetooth is unavailable for an unknown reason.", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unknown)")
            default:
                return String(format: LocalizedString("Bluetooth is unavailable: %1$@", comment: "The format string for BluetoothManagerError.bluetoothNotAvailable for unknown state (1: the unknown state)"), String(describing: state))
            }
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .bluetoothNotAvailable(let state):
            switch state {
            case .poweredOff:
                return LocalizedString("Turn bluetooth on", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.poweredOff)")
            case .resetting:
                return LocalizedString("Try again", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.resetting)")
            case .unauthorized:
                return LocalizedString("Please enable bluetooth permissions for this app in system settings", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.unauthorized)")
            case .unsupported:
                return LocalizedString("Please use a different device with bluetooth capabilities", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.unsupported)")
            default:
                return nil
            }
        }
    }
}

protocol OmniConnectionDelegate: AnyObject {

    /**
     Tells the delegate that a peripheral has been connected to

     - parameter manager: The manager for the peripheral that was connected
     */
    func omnipodPeripheralDidConnect(manager: PeripheralManager)

    /**
     Tells the delegate that a connected peripheral has been restored from session restoration

     - parameter manager: The manager for the peripheral that was connected
     */
    func omnipodPeripheralWasRestored(manager: PeripheralManager)


    /**
     Tells the delegate that a peripheral was disconnected

     - parameter peripheral: The peripheral that was disconnected
     */
    func omnipodPeripheralDidDisconnect(peripheral: CBPeripheral, error: Error?)

    /**
     Tells the delegate that a peripheral failed to connect

     - parameter peripheral: The peripheral that failed to connect
     */
    func omnipodPeripheralDidFailToConnect(peripheral: CBPeripheral, error: Error?)

}


class BluetoothManager: NSObject {

    weak var connectionDelegate: OmniConnectionDelegate?

    private let podType: PodType

    private let log = OSLog(category: "BluetoothManager")

    /// Isolated to `managerQueue`
    private var manager: CBCentralManager! = nil
    
    /// Isolated to `managerQueue`
    private var devices: [Omni] = []

    /// Last-seen DASH advertisement status word per peripheral, for connectionless alert detection.
    private var lastPodStatusWord: [String: Data] = [:]

    /// Last advertisement timestamp per peripheral, to log inter-frame cadence (the DS-beacon-rate
    /// measurement the RE asked for — is there a usable periodic wake?).
    private var lastAdvSeen: [String: Date] = [:]

    /// Isolated to `managerQueue`
    private var discoveryModeEnabled: Bool = false

    /// Isolated to `managerQueue`
    private var autoConnectIDs: Set<String> = [] {
        didSet {
            updateConnections()
        }
    }

    /// The uuidPdmId is set after pairing...
    private var uuidPdmId: UInt32? = nil

    /// The O5 changes its service advertisement uuid from using FFFFFFFE the pdmId after pairing.
    /// This func is called to set this value to be used in uuid after pairing and with a nil (or 0) to reset.
    func setUuidPdmId(_ pdmId: UInt32?) {
        managerQueue.async {
            if let pdmId = pdmId, pdmId != 0 {
                self.log.bleDebug("Setting uuidPdmId to 0x%x", pdmId)
                self.uuidPdmId = pdmId
            } else {
                self.uuidPdmId = nil
            }
        }
    }

    /// Isolated to `managerQueue`
    private var hasDiscoveredAllAutoConnectDevices: Bool {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        return autoConnectIDs.isSubset(of: devices.map { $0.manager.peripheral.identifier.uuidString })
    }

    // MARK: - Synchronization
    private let managerQueue = DispatchQueue(label: "com.OmnipodKit.bluetoothManagerQueue", qos: .unspecified)

    /// Per-instance ID so multiple centrals under the shared "com.OmnipodKit" restore identifier
    /// can be told apart in the log. INIT/DEINIT + the central callbacks are all tagged with it:
    /// N distinct INITs with no matching DEINITs = leaked centrals (the suspected pairing-bug root).
    let instanceID = String(UUID().uuidString.prefix(8))

    /// Field-test flag: keep scanning continuously (allowDuplicates) and log every pod advertisement,
    /// to test the "stay scanning, connect on demand, faults signalled via advertisement" model.
    static var advertisementMonitorEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.advertisementMonitorEnabled") as? Bool ?? true
    }

    /// Field-test flag: "normally disconnected" model. When on, the auto-reconnect machinery is
    /// suppressed (the pod is NOT held connected); PeripheralManager connects on demand for each
    /// session and disconnects when idle, and we scan (advertisementMonitor) while disconnected.
    /// This changes how Loop stays in touch with the pump — every command pays a connect first.
    static var connectOnDemandEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.connectOnDemandEnabled") as? Bool ?? true
    }

    /// §5 beacon-capture: scan withServices:nil (foreground, allowDuplicates) so we catch the pod's
    /// alarm/beacon advertisement even if it advertises a service UUID we don't yet filter on (e.g.
    /// the CE1F923D-… alarm beacon). Logs full raw fields for any pod-adjacent or CE1F923D frame so a
    /// normal↔triggered-alert diff pins the alarm-code offsets + the stable background-filter UUID.
    /// Heavy (wildcard foreground scan) — field-test only; revert before merge.
    static var beaconCaptureEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.beaconCaptureEnabled") as? Bool ?? true
    }

    /// Prefix of the DASH alarm/beacon 128-bit service UUID (per RE spec §3).
    static let beaconUUIDPrefix = "CE1F923D-C539-48EA-7300-0A"

    /// Low-power fault-watch (option 3): scan filtered on the DASH ALARM service UUID(s) with
    /// allowDuplicates OFF, so iOS only wakes us when the pod enters an alarm state (2nd service
    /// UUID flips to an alarm value) — zero wakes during normal operation, and it survives into the
    /// background via State Preservation/Restoration. Takes precedence over the monitor/beacon scans.
    /// Trade-off: only catches the enumerated alarm UUIDs below (currently just the one confirmed
    /// alert value); the clear transition isn't caught here (confirm on the next connect). See
    /// DASH_BEACON_FINDINGS.md. Add more alarm UUID values as they're discovered.
    /// NOTE: default flipped to FALSE to run the reconciliation experiment — a clean wildcard idle
    /// capture to confirm whether this pod EVER emits a 128-bit CE1F923D beacon (RE binary model) or
    /// only the 16-bit C005 alarm signal we've observed. Re-enable once the true alarm UUID is confirmed.
    static var lowPowerMonitorEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.lowPowerMonitorEnabled") as? Bool ?? false
    }

    /// Candidate DASH alarm-state service UUIDs to filter on in low-power mode.
    /// - `C005`: CONFIRMED 16-bit alarm 2nd-UUID on this pod (expiration reminder). Extend as more
    ///   alert/alarm types are captured.
    /// - The 128-bit AS/AST are the RE binary model `CE1F923D-C539-48EA-7300-0A<deviceId><TT>` with
    ///   deviceId GUESSED = pod address 179F0CF1 (TT 02=AS, 03=AST). UNCONFIRMED — no CE1F923D frame
    ///   has appeared in field capture; harmless if wrong (just won't match). Fix deviceId/byte-order
    ///   from a real [BEACON] capture before relying on these.
    static let alarmServiceUUIDs: [CBUUID] = [
        CBUUID(string: "C005"),
        CBUUID(string: "CE1F923D-C539-48EA-7300-0A179F0CF102"),
        CBUUID(string: "CE1F923D-C539-48EA-7300-0A179F0CF103"),
    ]

    /// Connect-request timestamps (by peripheral UUID) for measuring connect latency in didConnect.
    private var connectRequestedAt: [String: Date] = [:]

    /// Stamp the connect time and issue the connect, so didConnect can report the latency.
    private func timedConnect(_ peripheral: CBPeripheral) {
        if connectRequestedAt[peripheral.identifier.uuidString] == nil {
            connectRequestedAt[peripheral.identifier.uuidString] = Date()
        }
        let cm: CBCentralManager = manager
        cm.connect(peripheral, options: nil)
    }

    /// The keep-connected auto-reconnect. Suppressed in connect-on-demand mode, where the pod is
    /// left disconnected between commands (and observable via advertisements) and connected on
    /// demand by PeripheralManager. Explicit connects (pairing, retrieveAndConnectKnownPod, the
    /// on-demand connect) do NOT route through here and are unaffected.
    private func autoReconnect(_ peripheral: CBPeripheral) {
        if BluetoothManager.connectOnDemandEnabled {
            log.debug("[connectOnDemand] suppressing auto-reconnect to %{public}@", peripheral.identifier.uuidString)
            return
        }
        timedConnect(peripheral)
    }

    init(podType: PodType) {
        self.podType = podType
        super.init()

        log.default("BluetoothManager #%{public}@ INIT (podType=%{public}@). Created from:\n%{public}@",
                    instanceID, String(describing: podType),
                    Thread.callStackSymbols.dropFirst().prefix(12).joined(separator: "\n"))

        managerQueue.sync {
            self.manager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.OmnipodKit"])
        }
    }

    deinit {
        log.default("BluetoothManager #%{public}@ DEINIT", instanceID)
    }

    @discardableResult
    private func addPeripheral(_ peripheral: CBPeripheral, podAdvertisement: PodAdvertisement?) -> Omni {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        var device: Omni! = devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier })

        if let device = device {
            log.default("Matched peripheral %{public}@ to existing device: %{public}@", peripheral, String(describing: device))
            device.manager.peripheral = peripheral
            if let podAdvertisement = podAdvertisement {
                device.advertisement = podAdvertisement
            }
        } else {
            device = Omni(peripheralManager: PeripheralManager(peripheral: peripheral, podType: podType, centralManager: manager), advertisement: podAdvertisement)
            devices.append(device)
            log.info("Created device")
        }
        return device
    }
    
    // MARK: - Actions
    
    func discoverPods(completion: @escaping (BluetoothManagerError?) -> Void) {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            self.discoverPods(completion)
        }
    }
    
    func endPodDiscovery() {
        managerQueue.sync {
            self.discoveryModeEnabled = false
            self.manager.stopScan()
            
            // Disconnect from all devices not in our connection list
            for device in devices {
                let peripheral = device.manager.peripheral
                if !autoConnectIDs.contains(peripheral.identifier.uuidString) &&
                   (peripheral.state == .connected || peripheral.state == .connecting)
                {
                    log.default("Disconnecting from peripheral: %{public}@", peripheral)
                    manager.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }
    
    func connectToDevice(uuidString: String) {
        managerQueue.async {
            self.autoConnectIDs.insert(uuidString)
            // If powered on and peripheral not yet in devices, retrieve it now.
            // This handles the user-terminated app restart where willRestoreState wasn't called.
            if self.manager.state == .poweredOn,
               !self.devices.contains(where: { $0.manager.peripheral.identifier.uuidString == uuidString }),
               let uuid = UUID(uuidString: uuidString),
               let peripheral = self.manager.retrievePeripherals(withIdentifiers: [uuid]).first
            {
                self.log.default("connectToDevice: retrieved peripheral %{public}@ via retrievePeripherals", uuidString)
                self.addPeripheral(peripheral, podAdvertisement: nil)
                self.autoReconnect(peripheral)
            }
        }
    }

    /// Retrieve a known peripheral by UUID (without scanning), add it to devices, and initiate connection.
    /// Returns the Omni device synchronously; the actual BLE connection completes asynchronously.
    func retrieveAndConnectKnownPod(uuidString: String) -> Omni? {
        var result: Omni?
        managerQueue.sync {
            guard manager.state == .poweredOn, let uuid = UUID(uuidString: uuidString) else { return }
            let peripherals = manager.retrievePeripherals(withIdentifiers: [uuid])
            guard let peripheral = peripherals.first else {
                log.error("retrieveAndConnectKnownPod: no peripheral found for UUID %{public}@", uuidString)
                return
            }
            let device = addPeripheral(peripheral, podAdvertisement: nil)
            autoConnectIDs.insert(uuidString)
            autoReconnect(peripheral)
            log.default("retrieveAndConnectKnownPod: initiating connection to %{public}@", peripheral)
            result = device
        }
        return result
    }
    
    func disconnectFromDevice(uuidString: String) {
        managerQueue.async {
            self.autoConnectIDs.remove(uuidString)
        }
    }
    
    private func updateConnections() {
        guard manager.state == .poweredOn else {
            log.debug("Skipping updateConnections until state is poweredOn")
            return
        }
        
        for device in devices {
            let peripheral = device.manager.peripheral
            if autoConnectIDs.contains(peripheral.identifier.uuidString) {
                if peripheral.state == .disconnected || peripheral.state == .disconnecting {
                    log.info("updateConnections: Connecting to peripheral: %{public}@", peripheral)
                    autoReconnect(peripheral)
                }
            } else {
                if peripheral.state == .connected || peripheral.state == .connecting {
                    log.info("updateConnections: Disconnecting from peripheral: %{public}@", peripheral)
                    manager.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }

    private func discoverPods(_ completion: @escaping (BluetoothManagerError?) -> Void) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("discoverPods()")

        guard manager.state == .poweredOn else {
            completion(.bluetoothNotAvailable(manager.state))
            return
        }

        // We will attempt to connect to all pairable devices when in discovery mode
        discoveryModeEnabled = true
        for device in devices {
            let peripheral = device.manager.peripheral
            if peripheral.state == .disconnected || peripheral.state == .disconnecting {
                log.info("discoverPods: Connecting to peripheral: %{public}@", peripheral)
                timedConnect(peripheral)  // pairing/discovery — an explicit connect, not auto-reconnect
            }
        }
        startScanning()

        completion(nil)
    }

    private func startScanning() {
        let serviceUUID: CBUUID
        if podType.isO5, let pdmId = uuidPdmId {
            // The O5 service advertisement UUID is now using the pdmId
            serviceUUID = o5ServiceAdvertisementUUID(pdmId)
        } else {
            serviceUUID = podType.blePodProfile.advertisementServiceUUID
        }
        let services: [CBUUID]?
        let options: [String: Any]
        if BluetoothManager.lowPowerMonitorEnabled {
            // Option 3: wake only on an alarm-state advertisement. Filter on the alarm UUID(s), no
            // allowDuplicates. Takes precedence over the monitor/beacon scans.
            services = BluetoothManager.alarmServiceUUIDs
            options = [:]
        } else if BluetoothManager.beaconCaptureEnabled {
            // §5: scan withServices:nil (wildcard) + allowDuplicates so we catch a beacon advertising
            // a UUID we don't yet filter on. Foreground-only (the point of §5 is to find the filter UUID).
            services = nil
            options = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        } else {
            // Monitor mode: filter on the pod's main service; allowDuplicates to see the advert cadence.
            services = [serviceUUID]
            options = BluetoothManager.advertisementMonitorEnabled ? [CBCentralManagerScanOptionAllowDuplicatesKey: true] : [:]
        }
        log.default("Start scanning (filter=%{public}@, lowPowerMonitor=%{public}@, beaconCapture=%{public}@, allowDuplicates=%{public}@)",
                    services == nil ? "nil (wildcard)" : services!.map { $0.uuidString }.joined(separator: ","),
                    String(describing: BluetoothManager.lowPowerMonitorEnabled),
                    String(describing: BluetoothManager.beaconCaptureEnabled),
                    String(describing: options[CBCentralManagerScanOptionAllowDuplicatesKey] != nil))
        manager.scanForPeripherals(withServices: services, options: options)
    }

    private func stopScanning() {
        log.default("Stop scanning")
        manager.stopScan()
    }

    /// Resume the monitor/beacon scan after a connect attempt ends (connect-on-demand stops the scan
    /// during the connect because an active allowDuplicates scan starves connection completion).
    /// Only when nothing is connected, so we never scan while a command is using the link.
    private func resumeScanIfNeeded() {
        guard BluetoothManager.advertisementMonitorEnabled || BluetoothManager.beaconCaptureEnabled || BluetoothManager.lowPowerMonitorEnabled else { return }
        guard manager?.state == .poweredOn, !manager.isScanning else { return }
        guard !devices.contains(where: { $0.manager.peripheral.state == .connected || $0.manager.peripheral.state == .connecting }) else { return }
        log.default("[connectOnDemand] resuming scan after connect attempt")
        startScanning()
    }

    // MARK: - Accessors

    func getConnectedDevices() -> [Omni] {
        var connected: [Omni] = []
        managerQueue.sync {
            connected = self.devices.filter { $0.manager.peripheral.state == .connected }
        }
        return connected
    }

    /// The PeripheralManager for a known device by peripheral UUID — connected OR NOT. Connect-on-demand
    /// uses this to obtain the pod's manager while disconnected (BlePodComms.manager is otherwise only
    /// set in omnipodPeripheralDidConnect, so it's nil on a fresh launch when auto-reconnect is off).
    func peripheralManager(forIdentifier uuidString: String) -> PeripheralManager? {
        var result: PeripheralManager?
        managerQueue.sync {
            result = self.devices.first(where: { $0.manager.peripheral.identifier.uuidString == uuidString })?.manager
        }
        return result
    }

    override var debugDescription: String {
        
        var report = [
            "## BluetoothManager",
            "central: \(manager!)"
        ]

        for device in devices {
            report.append(String(reflecting: device))
            report.append("")
        }

        return report.joined(separator: "\n\n")
    }
}


extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("[#%{public}@] %{public}@: %{public}@", instanceID, #function, String(describing: central.state.rawValue))

        if case .poweredOn = central.state {
            // bluetooth may have reset; update peripheral references
            for device in devices {
                if let newPeripheral = central.retrievePeripherals(withIdentifiers: [device.manager.peripheral.identifier]).first {
                    log.debug("Re-connecting to known peripheral %{public}@", newPeripheral.identifier.uuidString)
                    device.manager.peripheral = newPeripheral
                    autoReconnect(newPeripheral)
                }
            }

            // Recover peripherals from autoConnectIDs that aren't yet in devices.
            // This handles the user-terminated app restart where willRestoreState wasn't called.
            let knownDeviceIDs = Set(devices.map { $0.manager.peripheral.identifier.uuidString })
            for uuidString in autoConnectIDs where !knownDeviceIDs.contains(uuidString) {
                if let uuid = UUID(uuidString: uuidString),
                   let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
                {
                    log.default("[#%{public}@] Recovered peripheral from autoConnectIDs: %{public}@", instanceID, uuidString)
                    addPeripheral(peripheral, podAdvertisement: nil)
                    autoReconnect(peripheral)
                }
            }

            updateConnections()
            
            if BluetoothManager.advertisementMonitorEnabled {
                // Monitor mode: keep scanning continuously so we observe pod advertisements,
                // regardless of whether all autoConnect devices are known/connected.
                if !manager.isScanning { startScanning() }
            } else if (discoveryModeEnabled || !hasDiscoveredAllAutoConnectDevices) && !manager.isScanning {
                startScanning()
            } else if !discoveryModeEnabled && manager.isScanning {
                stopScanning()
            }
        }

        for device in devices {
            device.manager.assertConfiguration()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        log.info("Omni %{public}@: %{public}@", #function, dict)

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                let device = addPeripheral(peripheral, podAdvertisement: nil)
                
                if autoConnectIDs.contains(peripheral.identifier.uuidString) {
                    if peripheral.state == .connected {
                        connectionDelegate?.omnipodPeripheralWasRestored(manager: device.manager)
                    }
                } else if peripheral.state == .connected || peripheral.state == .connecting {
                    // Don't disconnect — autoConnectIDs may not be populated yet due to init ordering.
                    // updateConnections() will clean up any truly unwanted peripherals after autoConnectIDs is set.
                    log.info("Restored peripheral %{public}@ not yet in autoConnectIDs, deferring cleanup to updateConnections", peripheral.identifier.uuidString)
                }
            }
        }
    }

    /// The DASH "clear / no alert" status word (see DASH_BEACON_FINDINGS.md). Any other value while
    /// the pod is otherwise healthy indicates an active alert/alarm.
    private static let podStatusClear = Data([0x00, 0x02, 0x00, 0x00])

    /// Extract the 4-byte DASH status word from the manufacturer data: it sits immediately before the
    /// 3-byte address+trailer tail (…000a‹STATUS›f10cbc). End-anchored so it's robust to the fixed
    /// pod-id prefix. Returns nil if the mfg data isn't the expected DASH shape.
    private func podStatusWord(from advertisementData: [String: Any]) -> Data? {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 8 else { return nil }
        return mfg.subdata(in: (mfg.count - 7)..<(mfg.count - 3))
    }

    /// PROTOTYPE connectionless alert detection (§5 finding): read the pod's alert state straight from
    /// its advertisement — no connection needed. Logs the status word and flags clear↔alert transitions.
    /// TODO(stage 2): route a confirmed alert transition to the pump manager (raise/clear a pod alert)
    /// once the per-alert bit mapping is confirmed across more alert types, to avoid false positives.
    private func detectPodAlertStatus(peripheral: CBPeripheral, advertisementData: [String: Any]) {
        guard let status = podStatusWord(from: advertisementData) else { return }
        let id = peripheral.identifier.uuidString
        guard lastPodStatusWord[id] != status else { return }   // only on change
        let wasAlert = lastPodStatusWord[id].map { $0 != BluetoothManager.podStatusClear }
        let isAlert = status != BluetoothManager.podStatusClear
        lastPodStatusWord[id] = status
        log.default("[POD-STATUS] %{public}@ status=%{public}@ (%{public}@) — connectionless detect",
                    id, status.hexadecimalString, isAlert ? "non-clear/ALERT" : "clear")
        if wasAlert != isAlert {
            log.default("[POD-ALERT] %{public}@ → %{public}@ (from advertisement, no connect)",
                        id, isAlert ? "ALERT ACTIVE" : "CLEARED")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.debug("%{public}@: %{public}@, %{public}@", #function, peripheral, advertisementData)

        // Full advertisement dump for pod-adjacent frames — the raw material for §5 (normal↔alarm
        // diff) and the "faults via advertisement" model. Captures every field, every time.
        let advSvcUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isBeaconFrame = advSvcUUIDs.contains { $0.uuidString.uppercased().hasPrefix(BluetoothManager.beaconUUIDPrefix) }
        let isPodFrame = autoConnectIDs.contains(peripheral.identifier.uuidString) || PodAdvertisement(advertisementData, podType: podType) != nil
        if (BluetoothManager.advertisementMonitorEnabled || BluetoothManager.beaconCaptureEnabled), isPodFrame || isBeaconFrame {
            let svcUUIDs = advSvcUUIDs.map { $0.uuidString }.joined(separator: ",")
            let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexadecimalString ?? "-"
            let svcData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?
                .map { "\($0.key.uuidString):\($0.value.hexadecimalString)" }.joined(separator: ",") ?? "-"
            let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "-"
            // Tag beacon frames distinctly so the §5 diff is trivial to grep.
            let tag = isBeaconFrame ? "[BEACON]" : "[ADV]"
            // Inter-frame delta = the advertising cadence (RE's DS-beacon-rate question).
            let now = Date()
            let dt = lastAdvSeen[peripheral.identifier.uuidString].map { String(format: "%.2f", now.timeIntervalSince($0)) } ?? "-"
            lastAdvSeen[peripheral.identifier.uuidString] = now
            log.default("%{public}@ %{public}@ dt=%{public}@s rssi=%{public}@ state=%{public}@ connectable=%{public}@ name=%{public}@ svcUUIDs=[%{public}@] mfg=%{public}@ svcData=%{public}@",
                        tag, peripheral.identifier.uuidString, dt, RSSI, String(describing: peripheral.state.rawValue),
                        String(describing: connectable), name.isEmpty ? "-" : name, svcUUIDs.isEmpty ? "-" : svcUUIDs, mfg, svcData)
        } else if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                  BluetoothManager.advertisementMonitorEnabled, !BluetoothManager.beaconCaptureEnabled {
            // Suppressed in beacon-capture (wildcard) mode — this fired for every nearby BLE device.
            log.default("[SCAN] ManufacturerData: %{public}@ (%{public}d bytes)", mfgData.hexadecimalString, mfgData.count)
        }

        if isPodFrame {
            detectPodAlertStatus(peripheral: peripheral, advertisementData: advertisementData)
        }

        if let podAdvertisement = PodAdvertisement(advertisementData, podType: podType) {
            addPeripheral(peripheral, podAdvertisement: podAdvertisement)
            
            if discoveryModeEnabled && peripheral.state == .disconnected && podAdvertisement.pairable {
                // Connect to any pairable device, during discovery
                log.default("Connecting to pairable device %{public} in discovery mode", peripheral)
                timedConnect(peripheral)  // pairing — an explicit connect, not auto-reconnect
            } else if autoConnectIDs.contains(peripheral.identifier.uuidString) && peripheral.state == .disconnected {
                log.debug("Reonnecting to autoconnect device")
                autoReconnect(peripheral)
            } else {
                log.info("Ignoring paired or unconnectable peripheral: %{public}@", peripheral)
            }
        } else {
            log.info("Ignoring peripheral with unexpected advertisement data: %{public}@", advertisementData)
        }
        
        if !BluetoothManager.advertisementMonitorEnabled && !discoveryModeEnabled && central.isScanning && hasDiscoveredAllAutoConnectDevices {
            log.debug("All peripherals discovered")
            stopScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        // Connected — stop the connect-helper scan (connectOnDemand started a light scan to speed the
        // connect). We don't scan while connected; the monitor scan is restored on the next disconnect.
        if manager.isScanning {
            manager.stopScan()
        }

        if let requestedAt = connectRequestedAt.removeValue(forKey: peripheral.identifier.uuidString) {
            let latency = String(format: "%.3f", Date().timeIntervalSince(requestedAt))
            log.default("[#%{public}@] CONNECTED: %{public}@ — connect latency %{public}@s (known device: %{public}@)",
                        instanceID, peripheral, latency,
                        String(describing: devices.contains { $0.manager.peripheral.identifier == peripheral.identifier }))
        } else {
            log.default("[#%{public}@] CONNECTED: %{public}@ — connect latency unknown (no request stamp) (known device: %{public}@)",
                        instanceID, peripheral, String(describing: devices.contains { $0.manager.peripheral.identifier == peripheral.identifier }))
        }

        // Proxy connection events to peripheral manager
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.manager.centralManager(central, didConnect: peripheral)
            connectionDelegate?.omnipodPeripheralDidConnect(manager: device.manager)

            // Get an RSSI reading for logging
            peripheral.readRSSI()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("[#%{public}@] DISCONNECTED: %{public}@ error=%{public}@ willReconnect=%{public}@", instanceID, peripheral,
                    String(describing: error), String(describing: autoConnectIDs.contains(peripheral.identifier.uuidString)))

        // Proxy disconnection events to peripheral manager
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.manager.centralManager(central, didDisconnect: peripheral, error: error)
        }

        connectionDelegate?.omnipodPeripheralDidDisconnect(peripheral: peripheral, error: error)

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            log.debug("Reconnecting disconnected autoconnect peripheral")
            autoReconnect(peripheral)
        }
        resumeScanIfNeeded()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.error("[#%{public}@] FAILED TO CONNECT: %{public}@ error=%{public}@", instanceID, peripheral, String(describing: error))

        connectionDelegate?.omnipodPeripheralDidFailToConnect(peripheral: peripheral, error: error)

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            autoReconnect(peripheral)
        }
        resumeScanIfNeeded()
    }
}
