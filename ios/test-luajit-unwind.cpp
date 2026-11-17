// Checks the iOS LuaJIT build (ios/build-luajit.sh) the way CET uses it: C++ exceptions thrown by a C function cross Lua frames and
// are caught by the C++ caller or turned into a Lua error by pcall, Lua errors unwind C++ frames (destructors run), and the JIT
// compiler is absent. Run on the iOS simulator by ios/test-luajit-unwind.sh. Exit code 0 = all passed.
#include <lua.hpp>

#include <cstdio>
#include <cstring>
#include <stdexcept>

static int g_destroyed = 0;
struct Guard
{
    ~Guard() { ++g_destroyed; }
};

static int Throws(lua_State*)
{
    throw std::runtime_error("from C++");
}

static int CallsLuaWithGuard(lua_State* L)
{
    Guard guard;
    lua_pushvalue(L, 1);
    lua_call(L, 0, 0); // the Lua function raises an error: it must unwind this frame and run ~Guard
    return 0;
}

static int g_failed = 0;
static void Check(const char* aName, bool aOk)
{
    std::printf("%s %s\n", aOk ? "PASS" : "FAIL", aName);
    if (!aOk)
        ++g_failed;
}

int main()
{
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    lua_pushcfunction(L, Throws);
    lua_setglobal(L, "throws");
    lua_pushcfunction(L, CallsLuaWithGuard);
    lua_setglobal(L, "guarded");

    // 1. a C++ exception through Lua frames, caught in C++ by type
    bool caught = false;
    try
    {
        luaL_loadstring(L, "local function f() throws() end f()");
        lua_call(L, 0, 0);
    }
    catch (const std::runtime_error& e)
    {
        caught = std::strcmp(e.what(), "from C++") == 0;
    }
    Check("C++ exception crosses Lua frames and is caught by the C++ caller", caught);
    lua_settop(L, 0);

    // 2. the same exception stopped by pcall
    luaL_loadstring(L, "return pcall(throws)");
    const int rc = lua_pcall(L, 0, 2, 0);
    Check("pcall turns a C++ exception into a Lua error", rc == 0 && lua_toboolean(L, 1) == 0);
    lua_settop(L, 0);

    // 3. a Lua error through a C++ frame runs its destructors
    luaL_loadstring(L, "return pcall(guarded, function() error('lua error') end)");
    const int rc3 = lua_pcall(L, 0, 2, 0);
    Check("a Lua error unwinds a C++ frame (destructor ran)", rc3 == 0 && lua_toboolean(L, 1) == 0 && g_destroyed == 1);
    lua_settop(L, 0);

    // 4. interpreter only
    luaL_loadstring(L, "return jit.status()");
    lua_pcall(L, 0, 1, 0);
    Check("the JIT compiler is off", lua_toboolean(L, -1) == 0);
    lua_settop(L, 0);

    // 5. a hot loop and 64-bit integers (FFI cdata) work in the interpreter
    luaL_loadstring(L, "local s = 0 for i = 1, 2000000 do s = s + i % 7 end return s == 5999997 and tostring(2LL^40 + 1LL) == '1099511627777LL'");
    const int rc5 = lua_pcall(L, 0, 1, 0);
    Check("interpreter runs a hot loop and 64-bit integer arithmetic", rc5 == 0 && lua_toboolean(L, -1) != 0);

    lua_close(L);
    return g_failed;
}
