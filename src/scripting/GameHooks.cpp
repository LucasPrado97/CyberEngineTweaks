#include <stdafx.h>

#include "GameHooks.h"

#include "RED4ext/GameStates.hpp"

#ifdef __APPLE__
#include "CET.h"
#include "MacShims.hpp"
#endif

static std::unique_ptr<GameMainThread> s_pGameMainThread;

void GameMainThread::RepeatedTaskQueue::AddTask(const std::function<bool()>& aFunction)
{
    std::lock_guard lock(m_mutex);
    m_tasks.emplace_back(aFunction);
}

void GameMainThread::RepeatedTaskQueue::Drain()
{
    std::lock_guard lock(m_mutex);
    for (auto taskIt = m_tasks.begin(); taskIt != m_tasks.end();)
    {
        if ((*taskIt)())
            taskIt = m_tasks.erase(taskIt);
        else
            ++taskIt;
    }
}
#if CET_IOS
GameMainThread::StateTickOverride::StateTickOverride(uint32_t, const char*)
{
}

GameMainThread::StateTickOverride::~StateTickOverride() = default;

bool GameMainThread::StateTickOverride::OnTick(RED4ext::IGameState*, RED4ext::CGameApplication*)
{
    Tasks.Drain();
    return true;
}

GameMainThread::GameMainThread()
{
    const auto* sdk = CetMac::PluginSdk();
    if (!sdk || !sdk->gameStates || !sdk->gameStates->Add)
    {
        Log::Error("RED4ext gave no game-state interface! Main thread is not hooked: no onUpdate, no deferred hooks!");
        return;
    }

    using RED4ext::EGameStateType;
    static constexpr std::pair<EGameStateType, const char*> s_cStates[] = {
        {EGameStateType::BaseInitialization, "BaseInitialization"},
        {EGameStateType::Initialization, "Initialization"},
        {EGameStateType::Running, "Running"},
        {EGameStateType::Shutdown, "Shutdown"}};
    static constexpr bool (*s_cCallbacks[])(RED4ext::CGameApplication*) = {
        [](RED4ext::CGameApplication*) { return StateCallback(EGameStateType::BaseInitialization); },
        [](RED4ext::CGameApplication*) { return StateCallback(EGameStateType::Initialization); },
        [](RED4ext::CGameApplication*) { return StateCallback(EGameStateType::Running); },
        [](RED4ext::CGameApplication*) { return StateCallback(EGameStateType::Shutdown); }};

    for (size_t i = 0; i < std::size(s_cStates); ++i)
    {
        // Running is ticked through OnUpdate every frame. The other three get one call each on enter and on update: RED4ext keeps
        // the game in an initialization state for as long as an update callback answers false, so those answer true (and RED4ext
        // then drops the callback).
        RED4ext::v1::GameState state{};
        state.OnUpdate = s_cCallbacks[i];
        if (s_cStates[i].first != EGameStateType::Running)
            state.OnEnter = s_cCallbacks[i];
        if (sdk->gameStates->Add(CetMac::PluginHandleValue(), s_cStates[i].first, &state))
            Log::Info("Main thread state {} callback registered with RED4ext!", s_cStates[i].second);
        else
            Log::Error("Could not register the {} state callback with RED4ext! Main thread is not completely hooked!", s_cStates[i].second);
    }
}

bool GameMainThread::StateCallback(RED4ext::EGameStateType aType)
{
    auto& gmt = Get();

    // hooks on targets ArchiveXL and Codeware own are chained once every plugin is loaded (macos/MacShims.hpp)
    static bool s_sharedHooksReady = false;
    if (!s_sharedHooksReady && CetMac::FlushDeferredHooks())
    {
        s_sharedHooksReady = true;
        if (CetMac::CetReady())
            CET::Get().GetVM().OnMacSharedHooksReady();
    }

    gmt.m_genericQueue.Drain();
    gmt.m_stateTickOverrides[static_cast<size_t>(aType)].Tasks.Drain();

    // RED4ext drops a callback that answers true; Running must keep coming.
    return aType != RED4ext::EGameStateType::Running;
}
#else
GameMainThread::StateTickOverride::StateTickOverride(uint32_t aHash, const char* acpRealFunctionName)
{
    const RED4ext::UniversalRelocPtr<uint8_t> func(aHash);
    Location = func.GetAddr();

    if (Location)
    {
        if (MH_CreateHook(Location, reinterpret_cast<void*>(&GameMainThread::HookStateTick), reinterpret_cast<void**>(&RealFunction)) != MH_OK || MH_EnableHook(Location) != MH_OK)
            Log::Error("Could not hook main thread function {}! Main thread is not completely hooked!", acpRealFunctionName);
        else
            Log::Info("Main thread function {} hook complete!", acpRealFunctionName);
    }
    else
        Log::Error("Could not locate {}! Main thread is not completely hooked!", acpRealFunctionName);
}

GameMainThread::StateTickOverride::~StateTickOverride()
{
    MH_DisableHook(Location);

    Location = nullptr;
    RealFunction = nullptr;
}

bool GameMainThread::StateTickOverride::OnTick(RED4ext::IGameState* apThisState, RED4ext::CGameApplication* apGameApplication)
{
    Tasks.Drain();

    return RealFunction(apThisState, apGameApplication);
}
#endif // CET_IOS

GameMainThread& GameMainThread::Get()
{
    static GameMainThread s_gameMainThread;

    return s_gameMainThread;
}

void GameMainThread::AddBaseInitializationTask(const std::function<bool()>& aFunction)
{
    constexpr auto cStateIndex = static_cast<size_t>(RED4ext::EGameStateType::BaseInitialization);
    return m_stateTickOverrides[cStateIndex].Tasks.AddTask(aFunction);
}

void GameMainThread::AddInitializationTask(const std::function<bool()>& aFunction)
{
    constexpr auto cStateIndex = static_cast<size_t>(RED4ext::EGameStateType::Initialization);
    return m_stateTickOverrides[cStateIndex].Tasks.AddTask(aFunction);
}

void GameMainThread::AddRunningTask(const std::function<bool()>& aFunction)
{
    constexpr auto cStateIndex = static_cast<size_t>(RED4ext::EGameStateType::Running);
    return m_stateTickOverrides[cStateIndex].Tasks.AddTask(aFunction);
}

void GameMainThread::AddShutdownTask(const std::function<bool()>& aFunction)
{
    constexpr auto cStateIndex = static_cast<size_t>(RED4ext::EGameStateType::Shutdown);
    return m_stateTickOverrides[cStateIndex].Tasks.AddTask(aFunction);
}

void GameMainThread::AddGenericTask(const std::function<bool()>& aFunction)
{
    m_genericQueue.AddTask(aFunction);
}

bool GameMainThread::HookStateTick(RED4ext::IGameState* apThisState, RED4ext::CGameApplication* apGameApplication)
{
    auto& gmt = Get();

#ifdef __APPLE__
    // CET macOS: hooks on targets ArchiveXL and Codeware own are chained once every plugin is loaded (macos/MacShims.hpp).
    static bool s_sharedHooksReady = false;
    if (!s_sharedHooksReady && CetMac::FlushDeferredHooks())
    {
        s_sharedHooksReady = true;
        if (CetMac::CetReady())
            CET::Get().GetVM().OnMacSharedHooksReady();
    }
#endif

    // drain generic tasks
    gmt.m_genericQueue.Drain();

    // execute specific state tasks, including original function
    const auto cStateIndex = static_cast<size_t>(apThisState->GetType());
    return gmt.m_stateTickOverrides[cStateIndex].OnTick(apThisState, apGameApplication);
}
