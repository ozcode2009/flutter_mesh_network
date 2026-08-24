import Foundation
import CoreBluetooth
import Flutter

/// BLE Peripheral handler — GATT server + advertising via CoreBluetooth.
///
/// Exposes a Nordic UART Service (NUS) so that remote centrals can write
/// mesh messages to the TX characteristic and receive notifications on RX.
final class BlePeripheralHandler: NSObject {

    // MARK: - UUIDs

    private let serviceUUID = CBUUID(
        string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    )

    private let txCharUUID = CBUUID(
        string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    )

    private let rxCharUUID = CBUUID(
        string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    )

    private static let peerPrefix = "MH"

    // MARK: - Properties

    private var peripheralManager: CBPeripheralManager?
    private var methodChannel: FlutterMethodChannel?

    private var rxCharacteristic: CBMutableCharacteristic?

    private var isAdvertising = false
    private var isGattRunning = false

    private var userName = ""
    private var latitude: Double?
    private var longitude: Double?

    private var subscribedCentrals: [CBCentral] = []
    private var incomingBuffers: [UUID: Data] = [:]

    private var pendingAdvertise = false
    private var pendingGattStart = false

    // MARK: - Channel Setup

    func setMethodChannel(_ channel: FlutterMethodChannel) {
        methodChannel = channel
    }

    // MARK: - Public API

    func initialize() -> Bool {
        NSLog("MESHDBG_INITIALIZE")

        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: nil
        )

        return true
    }

    func startGattServer() -> Bool {
        NSLog("MESHDBG_START_GATT")

        guard let pm = peripheralManager else {
            NSLog("MESHDBG_GATT_PM_NIL")
            pendingGattStart = true
            return false
        }

        guard pm.state == .poweredOn else {
            NSLog("MESHDBG_GATT_DEFERRED")
            pendingGattStart = true
            return false
        }

        if isGattRunning {
            NSLog("MESHDBG_GATT_ALREADY_RUNNING")
            return true
        }

        pendingGattStart = false

        let txCharacteristic = CBMutableCharacteristic(
            type: txCharUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        let rx = CBMutableCharacteristic(
            type: rxCharUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )

        rxCharacteristic = rx

        let service = CBMutableService(
            type: serviceUUID,
            primary: true
        )

        service.characteristics = [
            txCharacteristic,
            rx
        ]

        NSLog("MESHDBG_ADDING_GATT_SERVICE")

        pm.add(service)

        // Keep old behavior for now.
        // didAdd below will tell us whether registration really succeeded.
        isGattRunning = true

        return true
    }

    func startAdvertising(
        name: String,
        lat: Double?,
        lng: Double?
    ) -> Bool {
        userName = name
        latitude = lat
        longitude = lng

        guard let pm = peripheralManager else {
            pendingAdvertise = true
            return false
        }

        if pm.state != .poweredOn {
            pendingAdvertise = true
            return false
        }

        doStartAdvertising()
        return true
    }

    func stopAdvertising() {
        peripheralManager?.stopAdvertising()
        isAdvertising = false
        NSLog("MESHDBG_ADVERTISING_STOPPED")
    }

    func updateAdvertising(
        lat: Double?,
        lng: Double?
    ) {
        latitude = lat
        longitude = lng

        if isAdvertising {
            doStartAdvertising()
        }
    }

    func notifyAllSubscribers(data: Data) -> Int {
        guard
            let rx = rxCharacteristic,
            !subscribedCentrals.isEmpty
        else {
            return 0
        }

        let sent = peripheralManager?.updateValue(
            data,
            for: rx,
            onSubscribedCentrals: nil
        ) ?? false

        return sent ? subscribedCentrals.count : 0
    }

    func getState() -> [String: Any] {
        [
            "isAdvertising": isAdvertising,
            "isGattRunning": isGattRunning,
            "connectedCount": subscribedCentrals.count,
            "subscribedCount": subscribedCentrals.count
        ]
    }

    func stop() {
        pendingAdvertise = false
        pendingGattStart = false

        stopAdvertising()

        peripheralManager?.removeAllServices()

        subscribedCentrals.removeAll()
        incomingBuffers.removeAll()

        rxCharacteristic = nil
        isGattRunning = false

        NSLog("MESHDBG_BLE_STOPPED")
    }

    // MARK: - Helpers

    private func doStartAdvertising() {
        guard let pm = peripheralManager else {
            return
        }

        if pm.isAdvertising {
            pm.stopAdvertising()
        }

        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey:
                "\(Self.peerPrefix)\(userName)",

            CBAdvertisementDataServiceUUIDsKey:
                [serviceUUID]
        ]

        NSLog("MESHDBG_STARTING_ADVERTISEMENT")

        pm.startAdvertising(advertisementData)
    }

    private func invokeFlutter(
        _ method: String,
        arguments: Any? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.methodChannel?.invokeMethod(
                method,
                arguments: arguments
            )
        }
    }

    private func isCompleteJson(_ str: String) -> Bool {
        let trimmed = str.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard
            trimmed.hasPrefix("{"),
            trimmed.hasSuffix("}")
        else {
            return false
        }

        return (
            try? JSONSerialization.jsonObject(
                with: Data(trimmed.utf8)
            )
        ) != nil
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BlePeripheralHandler: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(
        _ peripheral: CBPeripheralManager
    ) {
        switch peripheral.state {

        case .poweredOn:
            NSLog("MESHDBG_POWERED_ON")

            if pendingGattStart {
                pendingGattStart = false
                _ = startGattServer()
            }

            if pendingAdvertise {
                pendingAdvertise = false
                doStartAdvertising()
            }

        case .poweredOff:
            NSLog("MESHDBG_POWERED_OFF")
            isAdvertising = false
            isGattRunning = false

        case .unauthorized:
            NSLog("MESHDBG_UNAUTHORIZED")

        case .unsupported:
            NSLog("MESHDBG_UNSUPPORTED")

        case .resetting:
            NSLog("MESHDBG_RESETTING")

        case .unknown:
            NSLog("MESHDBG_UNKNOWN")

        @unknown default:
            NSLog("MESHDBG_UNKNOWN_FUTURE_STATE")
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        if let error = error {
            NSLog("MESHDBG_GATT_ADD_FAILED")
            NSLog(
                "MESHDBG_GATT_ADD_ERROR: %@",
                error.localizedDescription
            )

            isGattRunning = false
            return
        }

        if service.uuid == serviceUUID {
            NSLog("MESHDBG_GATT_ADD_SUCCESS")
            isGattRunning = true
        }
    }

    func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        if let error = error {
            NSLog("MESHDBG_ADVERTISING_FAILED")
            NSLog(
                "MESHDBG_ADVERTISING_ERROR: %@",
                error.localizedDescription
            )

            isAdvertising = false
        } else {
            NSLog("MESHDBG_ADVERTISING_STARTED")
            isAdvertising = true
        }

        invokeFlutter(
            "onBleAdvertisingStarted",
            arguments: isAdvertising
        )
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {

            guard
                request.characteristic.uuid == txCharUUID,
                let value = request.value
            else {
                // Preserve old behavior for now.
                peripheral.respond(
                    to: request,
                    withResult: .success
                )

                continue
            }

            let centralId = request.central.identifier

            var buffer =
                incomingBuffers[centralId] ?? Data()

            buffer.append(value)

            if
                let str = String(
                    data: buffer,
                    encoding: .utf8
                ),
                str.hasSuffix("\n\n")
                    || isCompleteJson(str)
            {
                let message = str.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

                incomingBuffers.removeValue(
                    forKey: centralId
                )

                NSLog("MESHDBG_MESSAGE_RECEIVED")

                invokeFlutter(
                    "onBleMessageReceived",
                    arguments: [
                        "deviceId": centralId.uuidString,
                        "data": message
                    ]
                )
            } else {
                incomingBuffers[centralId] = buffer
            }

            peripheral.respond(
                to: request,
                withResult: .success
            )
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == rxCharUUID else {
            return
        }

        if !subscribedCentrals.contains(
            where: {
                $0.identifier == central.identifier
            }
        ) {
            subscribedCentrals.append(central)
        }

        NSLog("MESHDBG_CENTRAL_SUBSCRIBED")
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == rxCharUUID else {
            return
        }

        subscribedCentrals.removeAll {
            $0.identifier == central.identifier
        }

        NSLog("MESHDBG_CENTRAL_UNSUBSCRIBED")
    }

    func peripheralManagerIsReady(
        toUpdateSubscribers peripheral: CBPeripheralManager
    ) {
        NSLog("MESHDBG_READY_TO_UPDATE_SUBSCRIBERS")
    }
}
