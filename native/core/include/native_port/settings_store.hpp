#pragma once

#include <nlohmann/json.hpp>

#include <map>
#include <optional>
#include <shared_mutex>
#include <string>
#include <string_view>
#include <vector>

namespace native_port {

struct SettingUpdate final {
  std::string key;
  nlohmann::json value;
  std::optional<std::string> category_id;
};

class SettingsStore final {
 public:
  SettingsStore();

  void apply(const std::vector<SettingUpdate>& updates);
  void delete_custom_game_settings(const std::vector<std::string>& category_ids);
  void delete_custom_game_settings(const std::string& category_id, const std::vector<std::string>& keys);

  [[nodiscard]] std::optional<nlohmann::json> global(std::string_view key) const;
  [[nodiscard]] std::optional<nlohmann::json> effective(std::string_view key,
                                                        std::optional<std::string_view> category_id) const;
  [[nodiscard]] nlohmann::json snapshot() const;
  [[nodiscard]] static bool is_recovered_key(std::string_view key) noexcept;

 private:
  using SettingMap = std::map<std::string, nlohmann::json, std::less<>>;

  mutable std::shared_mutex mutex_;
  SettingMap globals_;
  std::map<std::string, SettingMap, std::less<>> per_game_;
};

}  // namespace native_port
