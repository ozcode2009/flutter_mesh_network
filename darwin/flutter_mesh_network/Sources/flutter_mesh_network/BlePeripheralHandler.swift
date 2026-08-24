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

    /// Central writes here.
    private let txCharUUID = CBUUID(
        string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    )

    /// Peripheral notifies here.
    private let rxCharUUID = CBUUID(
        string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    )

    // TEMP: changed from MSH_ so we can prove this source is actually
    // making it into the TestFlight build.
    private static let peerPrefix = "MH_"

    // MARK: - Properties

    private var peripheralManager: CBPeripheralManager?
    private weak var methodChannel: FlutterMethodChannel?

    private var rxCharacteristic: CBMutableCharacteristic?

    private var isAdvertising = false
    private var isGattRunning = false
    private var isGattStarting = false

    private var userName = ""
    private var latitude: Double?
    private var longitude: Double?

    /// Centrals currently subscribed to the RX notify characteristic.
    private var subscribedCentrals: [CBCentral] = []

    /// Chunked incoming data buffer keyed by central identifier.
    private var incomingBuffers: [UUID: Data] = [:]

    /// Advertising was requested before CoreBluetooth/GATT was ready.
    private var pendingAdvertise = false

    /// GATT startup was requested before CBPeripheralManager was powered on.
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
        NSLog("MESHDBG_START_GATT_ENTER")

        guard let pm = peripheralManager else {
            NSLog("MESHDBG_GATT_PM_NIL")
            pendingGattStart = true
            return false
        }

        guard pm.state == .poweredOn else {
            NSLog("MESHDBG_GATT_PM_NOT_POWERED_ON")
            pendingGattStart = true
            return false
        }

        if isGattRunning {
            NSLog("MESHDBG_GATT_ALREADY_RUNNING")
            return true
        }

        if isGattStarting {
            NSLog("MESHDBG_GATT_ALREADY_STARTING")
            return true
        }

        pendingGattStart = false
        isGattStarting = true

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

        NSLog("MESHDBG_CALLING_PM_ADD")

        // This is asynchronous.
        // isGattRunning is set only in didAdd(service:error:).
        pm.add(service)

        return true
    }

    func startAdvertising(
        name: String,
        lat: Double?,
        lng: Double?
    ) -> Bool {
        NSLog("MESHDBG_START_ADVERTISING_ENTER")

        userName = name
        latitude = lat
        longitude = lng

        guard let pm = peripheralManager else {
            NSLog("MESHDBG_ADVERTISE_PM_NIL")
            pendingAdvertise = true
            return false
        }

        guard pm.state == .poweredOn else {
            NSLog("MESHDBG_ADVERTISE_PM_NOT_POWERED_ON")
            pendingAdvertise = true
            return false
        }

        // Do not advertise a service UUID before that service actually
        // exists in the local GATT database.
        guard isGattRunning else {
            NSLog("MESHDBG_ADVERTISE_WAITING_FOR_GATT")
            pendingAdvertise = true
            return false
        }

        pendingAdvertise = false
        doStartAdvertising()

        return true
    }

    func stopAdvertising() {
        pendingAdvertise = false

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
        guard let rx = rxCharacteristic else {
            NSLog("MESHDBG_NOTIFY_NO_RX_CHARACTERISTIC")
            return 0
        }

        guard !subscribedCentrals.isEmpty else {
            NSLog("MESHDBG_NOTIFY_NO_SUBSCRIBERS")
            return 0
        }

        let sent = peripheralManager?.updateValue(
            data,
            for: rx,
            onSubscribedCentrals: nil
        ) ?? false

        if sent {
            NSLog("MESHDBG_NOTIFY_SUCCESS")
            return subscribedCentrals.count
        }

        // CoreBluetooth's transmit queue is full.
        // peripheralManagerIsReady(toUpdateSubscribers:) will fire later.
        NSLog("MESHDBG_NOTIFY_BACKPRESSURE")
        return 0
    }

    func getState() -> [String: Any] {
        return [
            "isAdvertising": isAdvertising,
            "isGattRunning": isGattRunning,
            "connectedCount": subscribedCentrals.count,
            "subscribedCount": subscribedCentrals.count
        ]
    }

    func stop() {
        NSLog("MESHDBG_STOP")

        pendingAdvertise = false
        pendingGattStart = false

        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()

        subscribedCentrals.removeAll()
        incomingBuffers.removeAll()

        rxCharacteristic = nil

        isAdvertising = false
        isGattRunning = false
        isGattStarting = false

        NSLog("MESHDBG_STOP_COMPLETE")
    }

    // MARK: - Helpers

    private func doStartAdvertising() {
        guard let pm = peripheralManager else {
            NSLog("MESHDBG_DO_ADVERTISE_PM_NIL")
            return
        }

        guard pm.state == .poweredOn else {
            NSLog("MESHDBG_DO_ADVERTISE_NOT_POWERED_ON")
            pendingAdvertise = true
            return
        }

        guard isGattRunning else {
            NSLog("MESHDBG_DO_ADVERTISE_GATT_NOT_READY")
            pendingAdvertise = true
            return
        }

        if pm.isAdvertising {
            NSLog("MESHDBG_RESTARTING_ADVERTISEMENT")
            pm.stopAdvertising()
        }

        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey:
                "\(Self.peerPrefix)\(userName)",

            CBAdvertisementDataServiceUUIDsKey:
                [serviceUUID]
        ]

        NSLog("MESHDBG_CALLING_START_ADVERTISING")

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

    // MARK: State changes

    func peripheralManagerDidUpdateState(
        _ peripheral: CBPeripheralManager
    ) {
        switch peripheral.state {

        case .poweredOn:
            NSLog("MESHDBG_POWERED_ON")

            if pendingGattStart {
                NSLog("MESHDBG_RETRYING_PENDING_GATT")

                pendingGattStart = false
                _ = startGattServer()
            }

            // We only advertise here if GATT is already registered.
            // Otherwise didAdd(service:) will start advertising later.
            if pendingAdvertise && isGattRunning {
                NSLog("MESHDBG_RETRYING_PENDING_ADVERTISEMENT")

                pendingAdvertise = false
                doStartAdvertising()
            }

        case .poweredOff:
            NSLog("MESHDBG_POWERED_OFF")

            isAdvertising = false
            isGattRunning = false
            isGattStarting = false

        case .unauthorized:
            NSLog("MESHDBG_UNAUTHORIZED")

            isAdvertising = false
            isGattRunning = false
            isGattStarting = false

        case .unsupported:
            NSLog("MESHDBG_UNSUPPORTED")

            isAdvertising = false
            isGattRunning = false
            isGattStarting = false

        case .resetting:
            NSLog("MESHDBG_RESETTING")

            isAdvertising = false
            isGattRunning = false
            isGattStarting = false

        case .unknown:
            NSLog("MESHDBG_UNKNOWN_STATE")

        @unknown default:
            NSLog("MESHDBG_UNKNOWN_FUTURE_STATE")
        }
    }

    // MARK: GATT service registration

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        isGattStarting = false

        if error != nil {
            NSLog("MESHDBG_GATT_ADD_FAILED")
            isGattRunning = false
            return
        }

        guard service.uuid == serviceUUID else {
            NSLog("MESHDBG_UNEXPECTED_SERVICE_ADDED")
            return
        }

        NSLog("MESHDBG_GATT_ADD_SUCCESS")

        isGattRunning = true

        // This is the important ordering:
        //
        //     add GATT service
        //          ↓
        //     didAdd succeeds
        //          ↓
        //     advertise service
        //
        // This prevents advertising 6E400001 while it isn't actually
        // present in the GATT database.
        if pendingAdvertise {
            NSLog("MESHDBG_STARTING_DEFERRED_ADVERTISEMENT")

            pendingAdvertise = false
            doStartAdvertising()
        }
    }

    // MARK: Advertising

    func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        if error != nil {
            NSLog("MESHDBG_ADVERTISING_FAILED")
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

    // MARK: Writes from centrals

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        NSLog("MESHDBG_RECEIVED_WRITE_CALLBACK")

        for request in requests {

            guard request.characteristic.uuid == txCharUUID else {
                NSLog("MESHDBG_WRITE_WRONG_CHARACTERISTIC")

                peripheral.respond(
                    to: request,
                    withResult: .requestNotSupported
                )

                continue
            }

            guard let value = request.value else {
                NSLog("MESHDBG_WRITE_EMPTY_VALUE")

                peripheral.respond(
                    to: request,
                    withResult: .invalidAttributeValueLength
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

                NSLog("MESHDBG_COMPLETE_MESSAGE_RECEIVED")

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

    // MARK: Subscriptions

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

    // MARK: Notification backpressure

    func peripheralManagerIsReady(
        toUpdateSubscribers peripheral: CBPeripheralManager
    ) {
        NSLog("MESHDBG_READY_TO_UPDATE_SUBSCRIBERS")
    }
}
