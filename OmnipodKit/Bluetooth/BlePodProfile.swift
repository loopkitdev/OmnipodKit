//
//  BlePodProfile.swift
//  OmnipodKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CoreBluetooth

struct BlePacketLayout {
    let maxPayloadSize: Int
    let maxFragments: Int

    let firstPacketHeaderSizeWithoutMiddlePackets: Int
    let firstPacketHeaderSizeWithMiddlePackets: Int
    let lastPacketHeaderSize: Int

    var firstPacketCapacityWithoutMiddlePackets: Int {
        maxPayloadSize - firstPacketHeaderSizeWithoutMiddlePackets
    }

    var firstPacketCapacityWithMiddlePackets: Int {
        maxPayloadSize - firstPacketHeaderSizeWithMiddlePackets
    }

    var firstPacketCapacityWithOptionalPlusOnePacket: Int {
        firstPacketCapacityWithMiddlePackets
    }

    var middlePacketCapacity: Int {
        maxPayloadSize - 1
    }

    var lastPacketCapacity: Int {
        maxPayloadSize - lastPacketHeaderSize
    }
}

struct BlePodProfile {
    let podType: PodType
    let advertisementServiceUUID: CBUUID
    let serviceUUID: CBUUID
    let commandCharacteristicUUID: CBUUID
    let dataCharacteristicUUID: CBUUID
    let heartbeatServiceUUID: CBUUID?
    let heartbeatCharacteristicUUID: CBUUID?
    let commandWriteType: CBCharacteristicWriteType
    let packetLayout: BlePacketLayout

    func makePeripheralConfiguration() -> PeripheralManager.Configuration {
        var serviceCharacteristics: [CBUUID: [CBUUID]] = [
            serviceUUID: [commandCharacteristicUUID, dataCharacteristicUUID]
        ]

        if let heartbeatServiceUUID = heartbeatServiceUUID,
           let heartbeatCharacteristicUUID = heartbeatCharacteristicUUID {
            serviceCharacteristics[heartbeatServiceUUID] = [heartbeatCharacteristicUUID]
        }

        var notifyingCharacteristics: [CBUUID: [CBUUID]] = [
            serviceUUID: []
        ]
        if let heartbeatServiceUUID = heartbeatServiceUUID,
           let heartbeatCharacteristicUUID = heartbeatCharacteristicUUID {
            notifyingCharacteristics[heartbeatServiceUUID] = [heartbeatCharacteristicUUID]
        }

        var valueUpdateMacros: [CBUUID: (_ manager: PeripheralManager) -> Void] = [
            commandCharacteristicUUID: { (manager: PeripheralManager) in
                guard let characteristic = manager.peripheral.getCommandCharacteristic(profile: manager.profile) else { return }
                guard let value = characteristic.value else { return }

                manager.log.bleDebug("[BLE RAW] CMD RECV: %{public}@", value.hexadecimalString)
                manager.queueLock.lock()
                manager.cmdQueue.append(value)
                manager.queueLock.signal()
                manager.queueLock.unlock()
                manager.noteInboundValueForUnsolicitedListener(characteristicUUID: characteristic.uuid, value: value)
            },
            dataCharacteristicUUID: { (manager: PeripheralManager) in
                guard let characteristic = manager.peripheral.getDataCharacteristic(profile: manager.profile) else { return }
                guard let value = characteristic.value else { return }

                manager.log.bleDebug("[BLE RAW] DATA RECV: %{public}@", value.hexadecimalString)
                manager.queueLock.lock()
                manager.dataQueue.append(value)
                manager.queueLock.signal()
                manager.queueLock.unlock()
                manager.noteInboundValueForUnsolicitedListener(characteristicUUID: characteristic.uuid, value: value)
            }
        ]

        if let heartbeatCharacteristicUUID = heartbeatCharacteristicUUID {
            valueUpdateMacros[heartbeatCharacteristicUUID] = { (manager: PeripheralManager) in
                manager.handleHeartbeat()
            }
        }

        return PeripheralManager.Configuration(
            serviceCharacteristics: serviceCharacteristics,
            notifyingCharacteristics: notifyingCharacteristics,
            valueUpdateMacros: valueUpdateMacros
        )
    }
}

extension BlePodProfile {
    static let omnipodDash = BlePodProfile(
        podType: dashType,
        advertisementServiceUUID: dashOmnipodServiceUUID.advertisement.cbUUID,
        serviceUUID: dashOmnipodServiceUUID.service.cbUUID,
        commandCharacteristicUUID: dashOmnipodCharacteristicUUID.command.cbUUID,
        dataCharacteristicUUID: dashOmnipodCharacteristicUUID.data.cbUUID,
        heartbeatServiceUUID: nil,
        heartbeatCharacteristicUUID: nil,
        commandWriteType: .withResponse,
        packetLayout: BlePacketLayout(
            maxPayloadSize: 20,
            maxFragments: 15,
            firstPacketHeaderSizeWithoutMiddlePackets: 7,
            firstPacketHeaderSizeWithMiddlePackets: 2,
            lastPacketHeaderSize: 6
        )
    )

    static let omnipod5 = BlePodProfile(
        podType: omnipod5Type,
        advertisementServiceUUID: o5OmnipodServiceUUID.advertisement.cbUUID,
        serviceUUID: o5OmnipodServiceUUID.service.cbUUID,
        commandCharacteristicUUID: o5OmnipodCharacteristicUUID.command.cbUUID,
        dataCharacteristicUUID: o5OmnipodCharacteristicUUID.data.cbUUID,
        heartbeatServiceUUID: o5Omnipod5HeartbeatServiceUUID.service.cbUUID,
        heartbeatCharacteristicUUID: o5Omnipod5HeartbeatCharacteristicUUID.heartbeat.cbUUID,
        commandWriteType: .withoutResponse,
        packetLayout: BlePacketLayout(
            maxPayloadSize: 244,
            maxFragments: 15,
            firstPacketHeaderSizeWithoutMiddlePackets: 7,
            firstPacketHeaderSizeWithMiddlePackets: 2,
            lastPacketHeaderSize: 6
        )
    )
}

extension PodType {
    var blePodProfile: BlePodProfile { isO5 ? .omnipod5 : .omnipodDash }
}
