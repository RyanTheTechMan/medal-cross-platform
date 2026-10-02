#include "audio_process_registry.hpp"
#include "audio_device_registry.hpp"
#include <cassert>
#include <iostream>

int main() {
  using namespace native_port;
  std::vector<MacApplicationIdentity> apps{
    {100, "test.game", "/Games/Game.app", "Game", "Game"},
    {200, "test.chat", "/Applications/Chat.app", "Chat", "Chat"},
    {201, "test.chat.helper", "/Applications/Chat.app/Contents/Helper.app", "Helper", "Helper"},
    {300, "test.other", "/Applications/Other.app", "Other", "Other"}};
  std::vector<MacAudioProcess> audio(5);
  audio[0].pid = 101; audio[0].executable_path = "/Games/Game.app/Contents/MacOS/GameAudio";
  audio[1].pid = 201; audio[1].executable_path = "/Applications/Chat.app/Contents/Helper.app/Contents/MacOS/Helper";
  audio[2].pid = 202; audio[2].executable_path = "/outside/chat-worker"; audio[2].ancestors = {200, 1};
  audio[3].pid = 301; audio[3].executable_path = "/Applications/Chat.app.evil/Contents/MacOS/Chat"; audio[3].ancestors = {300};
  audio[4].pid = 102; audio[4].executable_path = "/outside/game-audio"; audio[4].ancestors = {100};
  resolve_audio_process_owners(audio, apps);
  assert(audio[1].owner_pid == 200); // Outer app, not helper Dock identity.
  assert(audio[3].owner_pid == 300); // Component-boundary rejection.
  assert((resolve_audio_family(audio, "Chat") == std::vector<std::int64_t>{201, 202}));
  const std::vector<MacAudioOutputDevice> devices{
    {1, "uid-main", "Main", true, {2}}, {2, "uid-extra", "Extra", false, {1, 2}},
    {3, "uid-duplicate-1", "Duplicate", false, {2}}, {4, "uid-duplicate-2", "Duplicate", false, {2}},
    {5, "uid-wide", "Wide", false, {6}}, {6, "uid-invalid", "Invalid", false, {0}}};
  const auto routes = resolve_audio_output_routes(devices, {"Auto", "Main", "uid-main", "Extra"});
  assert(routes.size() == 3 && routes[0].device_uid == "uid-main" && routes[2].stream_index == 1);
  assert(routes[1].logical_id() != routes[2].logical_id());
  assert(resolve_audio_output_routes(devices, {}).empty());
  for (const auto& name : {"Disconnected", "Duplicate", "Wide", "Invalid"}) {
    bool rejected = false;
    try { (void)resolve_audio_output_routes(devices, {name}); } catch (const std::invalid_argument&) { rejected = true; }
    assert(rejected);
  }
  assert((resolve_audio_family(audio, "Chat.exe") == std::vector<std::int64_t>{201, 202}));
  assert((resolve_audio_family(audio, "test.chat") == std::vector<std::int64_t>{201, 202}));
  assert((resolve_audio_family(audio, "game-audio", 100) == std::vector<std::int64_t>{101, 102}));
  assert(resolve_audio_family(audio, "game-audio", 999).empty());
  assert(resolve_audio_family(audio, "Missing").empty());
  assert(resolve_audio_family(audio, "MedalEncoder.exe").empty());
  assert(resolve_audio_family(audio, "").empty());
  audio.push_back(audio[1]); // Duplicate HAL entries never duplicate one PID.
  assert((resolve_audio_family(audio, "Chat") == std::vector<std::int64_t>{201, 202}));
  apps.push_back({110, "test.game", "/Games/Game.app", "Game", "Game"});
  audio[0].ancestors = {100};
  MacAudioProcess other_instance;
  other_instance.pid = 111; other_instance.executable_path = "/Games/Game.app/Contents/MacOS/GameAudio";
  other_instance.ancestors = {110}; audio.push_back(other_instance);
  resolve_audio_process_owners(audio, apps);
  assert(audio.back().owner_pid == 110);
  assert((resolve_audio_family(audio, "game-audio", 100) == std::vector<std::int64_t>{101, 102}));
  std::cout << "Audio family identity regressions passed (injected model, no capture)\n";
}
