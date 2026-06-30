#include <BLEDevice.h>
#include <ESP32Servo.h>

static const char *kDeviceName = "NAV_LANTERN";
static const char *kServiceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
static const char *kCharUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";

static const int kServoPin = 21;

Servo gServo;

class ServerCallbacks : public BLEServerCallbacks {
  void onDisconnect(BLEServer *server) override {
    delay(100);
    BLEDevice::startAdvertising();
  }
};

class AngleCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    String value = characteristic->getValue();
    if (value.length() == 0) {
      return;
    }

    int angle = atoi(value.c_str());
    if (angle < -180) {
      angle = -180;
    }
    if (angle > 180) {
      angle = 180;
    }

    const int servoAngle = map(angle, -180, 180, 180, 0);
    gServo.write(servoAngle);
  }
};

void setup() {
  gServo.setPeriodHertz(50);
  gServo.attach(kServoPin);
  gServo.write(90);

  BLEDevice::init(kDeviceName);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService *service = server->createService(kServiceUuid);
  BLECharacteristic *characteristic = service->createCharacteristic(
      kCharUuid,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  characteristic->setCallbacks(new AngleCallbacks());
  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->setScanResponse(true);
  advertising->start();
}

void loop() {
  delay(50);
}
