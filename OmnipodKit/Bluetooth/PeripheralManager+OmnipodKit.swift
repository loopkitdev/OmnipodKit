//
//  PeripheralManager+OmnipodKit.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/PeripheralManager+OmniBLE.swift
//  Created by Randall Knutson on 11/2/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import os.log

fileprivate var bleDebugEnabled = false

extension OSLog {
    func bleDebug(_ message: StaticString, _ args: CVarArg...) {
        guard bleDebugEnabled else {
            return
        }
        let type: OSLogType = .default
        switch args.count {
        case 0:
            os_log(message, log: self, type: type)
        case 1:
            os_log(message, log: self, type: type, args[0])
        case 2:
            os_log(message, log: self, type: type, args[0], args[1])
        case 3:
            os_log(message, log: self, type: type, args[0], args[1], args[2])
        case 4:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3])
        case 5:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3], args[4])
        default:
            os_log(message, log: self, type: type, args)
        }
    }
}

enum SendMessageResult {
    case sentWithAcknowledgment
    case sentWithError(Error)
    case unsentWithError(Error)
}

extension PeripheralManager {
    
    /// - Throws: PeripheralManagerError
    func sendHello(myId: UInt32) throws {
        dispatchPrecondition(condition: .onQueue(queue))

        let controllerId = Id.fromUInt32(myId).address
        guard let characteristic = peripheral.getCommandCharacteristic(profile: profile) else {
            throw PeripheralManagerError.notReady
        }

        let type: CBCharacteristicWriteType = profile.commandWriteType
        try writeValue(Data([PodCommand.HELLO.rawValue, 0x01, 0x04]) + controllerId, for: characteristic, type: type, timeout: 5)
    }
    
    func enableNotifications() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let cmdChar = peripheral.getCommandCharacteristic(profile: profile) else {
            throw PeripheralManagerError.notReady
        }
        guard let dataChar = peripheral.getDataCharacteristic(profile: profile) else {
            throw PeripheralManagerError.notReady
        }
        try setNotifyValue(true, for: cmdChar, timeout: .seconds(2))
        try setNotifyValue(true, for: dataChar, timeout: .seconds(2))
    }
        
    func sendMessagePacket(_ message: MessagePacket, _ forEncryption: Bool = false) -> SendMessageResult {
        dispatchPrecondition(condition: .onQueue(queue))

        var didSend = false

        do {
            if podType.isDash {
                log.bleDebug("[sendMessagePacket] Sending RTS...")
                try requestToSend()
                log.bleDebug("[sendMessagePacket] Waiting for CTS...")
                try waitForCommand(PodCommand.CTS, timeout: 5)
                log.bleDebug("[sendMessagePacket] Got CTS")
            } else {
                log.bleDebug("[sendMessagePacket] Skipping RTS/CTS, writing data directly. peripheral state=%{public}@",
                             String(describing: peripheral.state))
            }

            let splitter = PayloadSplitter(payload: message.asData(forEncryption: forEncryption), layout: profile.packetLayout)
            let packets = splitter.splitInPackets()
            log.bleDebug("[sendMessagePacket] Split payload into %{public}d packet(s), total payload %{public}d bytes", packets.count, message.payload.count)

            for (index, packet) in packets.enumerated() {
                // Consider starting the last packet send as the point at which the message may be received by the pod.
                // A failure after data is actually sent, but before the sendData() returns can still be received.
                if index == packets.count - 1 {
                    didSend = true
                }
                let packetData = packet.toData(layout: profile.packetLayout)
                log.bleDebug("[sendMessagePacket] Writing data packet %{public}d/%{public}d (%{public}d bytes)... peripheral state=%{public}@",
                            index + 1, packets.count, packetData.count, String(describing: peripheral.state))
                try sendData(packetData, timeout: 5)
                log.bleDebug("[sendMessagePacket] Data packet %{public}d/%{public}d written. Peeking for NACK...", index + 1, packets.count)
                try self.peekForNack()
            }

            log.bleDebug("[sendMessagePacket] All packets written. Waiting for SUCCESS... peripheral state=%{public}@",
                         String(describing: peripheral.state))
            try waitForCommand(PodCommand.SUCCESS, timeout: 5)
            log.bleDebug("[sendMessagePacket] SUCCESS received. peripheral state=%{public}@",
                         String(describing: peripheral.state))
        } catch {
            log.error("[sendMessagePacket] Error (didSend=%{public}@): %{public}@. peripheral state=%{public}@",
                      String(describing: didSend), String(describing: error), String(describing: peripheral.state))
            if didSend {
                return .sentWithError(error)
            } else {
                return .unsentWithError(error)
            }
        }
        return .sentWithAcknowledgment
    }
    
    /// - Throws: PeripheralManagerError
    func readMessagePacket(disconnectOnUnresponsivePod: Bool = true) throws -> MessagePacket? {
        dispatchPrecondition(condition: .onQueue(queue))

        var packet: MessagePacket?

        do {
            if podType.isDash {
                log.bleDebug("[readMessagePacket] Waiting for RTS from pod...")
                try waitForCommand(PodCommand.RTS)
                log.bleDebug("[readMessagePacket] Got RTS, sending CTS...")
                try sendCommandType(PodCommand.CTS)
                log.bleDebug("[readMessagePacket] CTS sent")
            } else {
                log.bleDebug("[readMessagePacket] Skipping RTS/CTS, waiting for data. peripheral state=%{public}@",
                             String(describing: peripheral.state))
            }

            var expected: UInt8 = 0

            log.bleDebug("[readMessagePacket] Waiting for first data packet (seq 0)... peripheral state=%{public}@",
                         String(describing: peripheral.state))
            let firstPacket = try waitForData(sequence: expected, timeout: 5)
            log.bleDebug("[readMessagePacket] First data packet received (%{public}d bytes)", firstPacket.count)

            let joiner = try PayloadJoiner(firstPacket: firstPacket, layout: profile.packetLayout)
            let totalFragments = joiner.fullFragments + (joiner.oneExtraPacket ? 1 : 0)
            log.bleDebug("[readMessagePacket] Expecting %{public}d more fragment(s) (fullFragments=%{public}d, oneExtra=%{public}@)",
                        totalFragments, joiner.fullFragments, String(describing: joiner.oneExtraPacket))

            if joiner.fullFragments > 0 {
                for i in 1...joiner.fullFragments {
                    expected += 1
                    log.bleDebug("[readMessagePacket] Waiting for fragment %{public}d (seq %{public}d)... peripheral state=%{public}@",
                                i, expected, String(describing: peripheral.state))
                    let packet = try waitForData(sequence: expected, timeout: 5)
                    log.bleDebug("[readMessagePacket] Fragment %{public}d received (%{public}d bytes)", i, packet.count)
                    try joiner.accumulate(packet: packet)
                }
            }
            if joiner.oneExtraPacket {
                expected += 1
                log.bleDebug("[readMessagePacket] Waiting for extra fragment (seq %{public}d)... peripheral state=%{public}@",
                            expected, String(describing: peripheral.state))
                let packet = try waitForData(sequence: expected, timeout: 5)
                log.bleDebug("[readMessagePacket] Extra fragment received (%{public}d bytes)", packet.count)
                try joiner.accumulate(packet: packet)
            }
            let fullPayload = try joiner.finalize()
            log.bleDebug("[readMessagePacket] All fragments received, total payload %{public}d bytes. Sending SUCCESS...", fullPayload.count)
            try  sendCommandType(PodCommand.SUCCESS)
            log.bleDebug("[readMessagePacket] SUCCESS sent. Parsing message...")
            packet = try MessagePacket.parse(payload: fullPayload)
            log.bleDebug("[readMessagePacket] Message parsed successfully. peripheral state=%{public}@",
                         String(describing: peripheral.state))
        } catch {
            log.error("[readMessagePacket] Error reading message: %{public}@. peripheral state=%{public}@",
                      String(describing: error),
                      String(describing: peripheral.state))
            if let error = error as? PeripheralManagerError, error.isSymptomaticOfUnresponsivePod {
                if disconnectOnUnresponsivePod, peripheral.state == .connected {
                    log.error("[readMessagePacket] Disconnecting due to unresponsive pod error while reading")
                    central?.cancelPeripheralConnection(peripheral)
                } else {
                    log.error("[readMessagePacket] Pod already not connected (state=%{public}@), skipping disconnect",
                              String(describing: peripheral.state))
                }
            } else {
                log.error("[readMessagePacket] Non-unresponsive error, sending NACK")
                try? sendCommandType(PodCommand.NACK)
            }
            throw PeripheralManagerError.incorrectResponse
        }

        return packet
    }

    /// - Throws: PeripheralManagerError
    func peekForNack() throws -> Void {
        dispatchPrecondition(condition: .onQueue(queue))

        // Lock to protect cmdQueue
        queueLock.lock()
        defer {
            queueLock.unlock()
        }

        if cmdQueue.contains(where: { cmd in
            return cmd[0] == PodCommand.NACK.rawValue
        }) {
            throw PeripheralManagerError.nack
        }
    }

    func requestToSend() throws {
        clearCommsQueues()
        try sendCommandType(.RTS, timeout: 5)
    }
    
    /// - Throws: PeripheralManagerError
    func sendCommandType(_ command: PodCommand, timeout: TimeInterval = 5) throws  {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let characteristic = peripheral.getCommandCharacteristic(profile: profile) else {
            throw PeripheralManagerError.notReady
        }

        let type: CBCharacteristicWriteType = profile.commandWriteType
        try writeValue(Data([command.rawValue]), for: characteristic, type: type, timeout: timeout)
    }

    /// - Throws: PeripheralManagerError
    func waitForCommand(_ command: PodCommand, timeout: TimeInterval = 5) throws {
        dispatchPrecondition(condition: .onQueue(queue))

        let deadline = Date().addingTimeInterval(timeout)

        while true {
            // Wait for data to be read.
            queueLock.lock()
            if cmdQueue.count == 0 {
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 {
                    queueLock.wait(until: deadline)
                }
            }
            queueLock.unlock()

            commandLock.lock()

            // Lock to protect cmdQueue
            queueLock.lock()

            if cmdQueue.count > 0 {
                let value = cmdQueue.remove(at: 0)

                if command.rawValue == value[0] {
                    log.bleDebug("waitForCommand: got expected 0x%{public}02x, full data=%{public}@ (%{public}d bytes)",
                                command.rawValue, value.hexadecimalString, value.count)
                    queueLock.unlock()
                    commandLock.unlock()
                    return // Got expected command
                }

                // During O5 pairing, pod sends intermediate PAIR_STATUS (0x08) commands
                // before SUCCESS. Log and continue waiting for the expected command.
                if value[0] == PodCommand.PAIR_STATUS.rawValue {
                    log.bleDebug("waitForCommand: skipping intermediate PAIR_STATUS (0x08), data=%{public}@, waiting for 0x%{public}02x",
                               value.hexadecimalString, command.rawValue)
                    queueLock.unlock()
                    commandLock.unlock()
                    // Check if we still have time left before looping
                    if Date() >= deadline {
                        throw PeripheralManagerError.emptyValue
                    }
                    continue // Loop and wait for next command
                }

                // Unexpected command that isn't PAIR_STATUS
                log.error("waitForCommand failed. rawValue != value[0] (%d != %d); data=%@", command.rawValue, value[0], value.hexadecimalString)
                queueLock.unlock()
                commandLock.unlock()
                throw PeripheralManagerError.incorrectResponse
            }

            queueLock.unlock()
            commandLock.unlock()

            // No data in queue and deadline reached
            if Date() >= deadline {
                throw PeripheralManagerError.emptyValue
            }
        }
    }

    /// - Throws: PeripheralManagerError
    func sendData(_ value: Data, timeout: TimeInterval) throws {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let characteristic = peripheral.getDataCharacteristic(profile: profile) else {
            log.error("Unable to get characteristic... peripheral status: %{PUBLIC}@",
                      String(describing: peripheral.state))
            throw PeripheralManagerError.notReady
        }

        let type: CBCharacteristicWriteType = profile.commandWriteType
        try writeValue(value, for: characteristic, type: type, timeout: timeout)
    }

    /// - Throws: PeripheralManagerError
    func waitForData(sequence: UInt8, timeout: TimeInterval) throws -> Data {
        dispatchPrecondition(condition: .onQueue(queue))

        // Wait for data to be read.
        queueLock.lock()
        if (dataQueue.count == 0) {
            queueLock.wait(until: Date().addingTimeInterval(timeout))
        }
        queueLock.unlock()

        commandLock.lock()
        defer {
            commandLock.unlock()
        }

        // Lock to protect dataQueue
        queueLock.lock()
        defer {
            queueLock.unlock()
        }

        if (dataQueue.count > 0) {
            let data = dataQueue.remove(at: 0)
            
            if (data[0] != sequence) {
                log.error("waitForData failed data[0] != sequence (%d != %d).", data[0], sequence)
                throw PeripheralManagerError.incorrectResponse
            }
            return data
        }
        
        throw PeripheralManagerError.emptyValue
    }
}


// Marks certain errors are the kinds we see from NXP pods that occasionally become unresponsive
extension PeripheralManagerError {
    var isSymptomaticOfUnresponsivePod: Bool {
        switch self {
        case .emptyValue, .incorrectResponse:
            return true
        default:
            return false
        }
    }
}

// MARK: - Unsolicited (pod-initiated) fault listener (opt-in diagnostic; default OFF)
//
// While CONNECTED, a pod can initiate a transfer (e.g. a fault/alert) without us having
// sent a command. Those notifications are normally buffered and then flushed
// (clearCommsQueues) before the next command. This listener detects a pod-initiated transfer
// while idle, drives the EXISTING receive path to assemble the encrypted MessagePacket, and
// hands it to the delegate to decrypt + log (keeping the session nonce in sync). It does NOT
// route alerts — production fault detection is the connectionless C00A advertisement scan.
// This is a BLE-protocol diagnostic for characterizing unsolicited pod pushes from field logs.
extension PeripheralManager {

    /// Opt-in diagnostic (default OFF): a listener that logs pod-initiated (unsolicited) frames pushed
    /// over an active connection (keeping the session nonce in sync). It does NOT route alerts —
    /// production fault detection is the connectionless C00A advertisement scan, not this. Ships off;
    /// enable via the UserDefaults key for BLE protocol diagnostics.
    static var unsolicitedFaultListenerEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.unsolicitedFaultListenerEnabled") as? Bool ?? false
    }

    /// Called from the cmd/data value-update macros (BLE callback thread) AFTER the raw
    /// value is buffered. Must be cheap and non-blocking. Detects the start of a
    /// pod-initiated transfer while idle and schedules a serialized receive.
    func noteInboundValueForUnsolicitedListener(characteristicUUID: CBUUID, value: Data) {
        guard PeripheralManager.unsolicitedFaultListenerEnabled else { return }
        guard unsolicitedListenerArmed else { return }       // only after an encrypted session is established
        guard isIdleForUnsolicitedListener else { return }   // a response we're awaiting — not unsolicited
        guard peripheral.state == .connected else { return }

        // Transfer-start signal differs by pod type:
        //  - Dash: a SINGLE-byte RTS (0x00) on the command characteristic. Multi-byte values
        //    whose first byte is 0x00 are session-negotiation handshakes (e.g. 00000100f4),
        //    NOT an RTS — exclude them.
        //  - O5:   the first data packet (seq 0) on the data characteristic (no RTS/CTS).
        let isDashStart = podType.isDash
            && characteristicUUID == profile.commandCharacteristicUUID
            && value.count == 1
            && value.first == PodCommand.RTS.rawValue
        let isO5Start = podType.isO5
            && characteristicUUID == profile.dataCharacteristicUUID
            && value.first == 0
        guard isDashStart || isO5Start else { return }

        log.default("[unsolicited] candidate pod-initiated transfer while idle: char=%{public}@ first=0x%{public}02x len=%{public}d raw=%{public}@",
                    characteristicUUID.uuidString, value.first ?? 0, value.count, value.hexadecimalString)

        runSession(withName: "UnsolicitedReceive") { [weak self] in
            guard let self = self else { return }
            // A real command may have been scheduled and flushed the queues before this
            // serialized op ran.
            guard PeripheralManager.unsolicitedFaultListenerEnabled, self.peripheral.state == .connected else { return }
            do {
                // NEVER disconnect from the observer path — a timeout here must be silent.
                guard let packet = try self.readMessagePacket(disconnectOnUnresponsivePod: false) else {
                    self.log.default("[unsolicited] no packet assembled (likely flushed by an intervening command)")
                    return
                }
                self.log.default("[unsolicited] assembled packet: type=%{public}@ seq=%{public}d encPayloadLen=%{public}d encPayload=%{public}@",
                                 String(describing: packet.type), packet.sequenceNumber, packet.payload.count, packet.payload.hexadecimalString)
                self.delegate?.peripheralManager(self, didReceiveUnsolicitedMessagePacket: packet)
            } catch {
                self.log.error("[unsolicited] receive/assemble failed: %{public}@ (peripheral state=%{public}@)",
                               String(describing: error), String(describing: self.peripheral.state))
            }
        }
    }
}
