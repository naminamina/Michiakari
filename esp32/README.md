# ESP32 BLE Servo

This sketch listens for BLE writes and drives a servo to the requested angle.

## Wiring
- Servo signal: GPIO 21
- Servo power: 5.5 V (external)
- Common ground between ESP32 and servo power

## BLE
- Device name: NAV_LANTERN
- Service UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
- Characteristic UUID: 6E400002-B5A3-F393-E0A9-E50E24DCCA9E
- Payload: signed angle string (-180 to 180) with optional newline

## Dependencies
- Arduino ESP32 core
- ESP32Servo library
