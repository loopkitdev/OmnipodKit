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
        // Monitor mode: allowDuplicates so we see the advertisement cadence (foreground only —
        // iOS coalesces duplicates in the background).
        let options: [String: Any] = BluetoothManager.advertisementMonitorEnabled
            ? [CBCentralManagerScanOptionAllowDuplicatesKey: true] : [:]
        log.default("Start scanning for %{public}@ (advertisementMonitor=%{public}@, allowDuplicates=%{public}@)",
                    serviceUUID.uuidString, String(describing: BluetoothManager.advertisementMonitorEnabled),
                    String(describing: options[CBCentralManagerScanOptionAllowDuplicatesKey] != nil))
        manager.scanForPeripherals(withServices: [serviceUUID], options: options)
    }

    private func stopScanning() {
        log.default("Stop scanning")
        manager.stopScan()
    }

    // MARK: - Accessors

    func getConnectedDevices() -> [Omni] {
        var connected: [Omni] = []
        managerQueue.sync {
            connected = self.devices.filter { $0.manager.peripheral.state == .connected }
        }
        return connected
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

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.debug("%{public}@: %{public}@, %{public}@", #function, peripheral, advertisementData)

        // Full advertisement dump for pod-identified peripherals — to test the "faults via
        // advertisement" model: capture every field (esp. the service-UUID list, which changed
        // between scans early on) + RSSI + connectable + peripheral state, every time.
        if BluetoothManager.advertisementMonitorEnabled,
           autoConnectIDs.contains(peripheral.identifier.uuidString) || PodAdvertisement(advertisementData, podType: podType) != nil {
            let svcUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString }.joined(separator: ",") ?? "-"
            let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexadecimalString ?? "-"
            let svcData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?
                .map { "\($0.key.uuidString):\($0.value.hexadecimalString)" }.joined(separator: ",") ?? "-"
            let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "-"
            log.default("[ADV] %{public}@ rssi=%{public}@ state=%{public}@ connectable=%{public}@ name=%{public}@ svcUUIDs=[%{public}@] mfg=%{public}@ svcData=%{public}@",
                        peripheral.identifier.uuidString, RSSI, String(describing: peripheral.state.rawValue),
                        String(describing: connectable), name, svcUUIDs, mfg, svcData)
        } else if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            log.default("[SCAN] ManufacturerData: %{public}@ (%{public}d bytes)", mfgData.hexadecimalString, mfgData.count)
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
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.error("[#%{public}@] FAILED TO CONNECT: %{public}@ error=%{public}@", instanceID, peripheral, String(describing: error))

        connectionDelegate?.omnipodPeripheralDidFailToConnect(peripheral: peripheral, error: error)

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            autoReconnect(peripheral)
        }
    }
}
