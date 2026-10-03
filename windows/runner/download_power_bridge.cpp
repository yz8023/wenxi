#include "download_power_bridge.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <variant>

DownloadPowerBridge::DownloadPowerBridge(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.asterlink.app/native",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    using flutter::EncodableMap;
    using flutter::EncodableValue;
    if (call.method_name() == "foreground") {
      const auto* args = call.arguments()
                             ? std::get_if<EncodableMap>(call.arguments())
                             : nullptr;
      int64_t active = -1;
      if (args) {
        const auto entry = args->find(EncodableValue("active"));
        if (entry != args->end()) {
          if (const auto* value = std::get_if<int32_t>(&entry->second)) {
            active = *value;
          } else if (const auto* value64 = std::get_if<int64_t>(&entry->second)) {
            active = *value64;
          }
        }
      }
      if (active < 0 || active > 10000) {
        result->Error("arguments", "下载任务状态无效");
      } else if (!request_.SetActive(active > 0)) {
        result->Error("foreground", "无法更新下载保活状态，请重试");
      } else {
        result->Success();
      }
      return;
    }
    if (call.method_name() == "downloadProtectionStatus") {
      SYSTEM_POWER_STATUS power{};
      const bool saving = GetSystemPowerStatus(&power) && power.SystemStatusFlag == 1;
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("desktop"), EncodableValue(true)},
          {EncodableValue("batteryUnrestricted"), EncodableValue(true)},
          {EncodableValue("notificationsEnabled"), EncodableValue(true)},
          {EncodableValue("backgroundRestricted"), EncodableValue(false)},
          {EncodableValue("serviceRunning"), EncodableValue(request_.active())},
          {EncodableValue("wakeLockHeld"), EncodableValue(request_.active())},
          {EncodableValue("powerSaveMode"), EncodableValue(saving)},
      }));
      return;
    }
    result->NotImplemented();
  });
}

DownloadPowerBridge::~DownloadPowerBridge() {
  channel_->SetMethodCallHandler(nullptr);
}
