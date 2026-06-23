--[[
  logger.lua
  LuaFighter 统一日志模块

  支持级别：DEBUG < INFO < WARN < ERROR
  通过环境变量 LUAFIGHTER_LOG_LEVEL 控制全局级别（默认 DEBUG）
  通过环境变量 LUAFIGHTER_DEBUG_LOG 控制日志文件路径

  使用方式：
    local Logger = require("utils.logger")
    local log = Logger.new("automation")
    log:debug("调试信息")
    log:info("一般信息")
    log:warn("警告")
    log:error("错误")

  旧代码兼容：
    local log = Logger.new("module")
    log("消息")  -- 等价于 log:info("消息")
]]

local Logger = {}
Logger.__index = Logger

-- 日志级别定义（数值越大越重要）
local LEVELS = {
  DEBUG = 1,
  INFO = 2,
  WARN = 3,
  ERROR = 4,
}

local LEVEL_NAMES = { [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }

-- 从环境变量读取全局配置
local LOG_FILE = os.getenv("LUAFIGHTER_DEBUG_LOG") or "/tmp/luafighter-debug.log"
local MAX_LOG_SIZE = 2 * 1024 * 1024  -- 2MB 截断

-- 解析全局日志级别
local function parseLevel(str)
  if not str then return LEVELS.DEBUG end
  str = str:upper()
  if str == "DEBUG" then return LEVELS.DEBUG end
  if str == "INFO" then return LEVELS.INFO end
  if str == "WARN" then return LEVELS.WARN end
  if str == "ERROR" then return LEVELS.ERROR end
  -- 兼容数字
  local n = tonumber(str)
  if n and LEVEL_NAMES[n] then return n end
  return LEVELS.DEBUG
end

local GLOBAL_LEVEL = parseLevel(os.getenv("LUAFIGHTER_LOG_LEVEL"))

-- 日志文件大小检查和截断
local function checkAndRotateLog()
  local ok, size = pcall(function()
    local f = io.open(LOG_FILE, "r")
    if f then
      local s = f:seek("end", 0)
      f:close()
      return s
    end
    return 0
  end)
  if ok and size and size > MAX_LOG_SIZE then
    pcall(function()
      local f = io.open(LOG_FILE, "w")
      if f then f:close() end
    end)
  end
end

-- 构造函数
function Logger.new(name, level)
  local obj = {
    name = name or "unknown",
    level = level or GLOBAL_LEVEL,
  }
  setmetatable(obj, Logger)
  return obj
end

-- 核心日志输出
function Logger:log(level, msg)
  if level < self.level then return end
  local levelName = LEVEL_NAMES[level] or "UNKNOWN"
  local line = string.format("[%s] [%s] [%s] %s\n",
    os.date("%H:%M:%S"), levelName, self.name, tostring(msg))

  checkAndRotateLog()

  local ok, fd = pcall(function() return io.open(LOG_FILE, "a") end)
  if ok and fd then
    fd:write(line)
    fd:flush()
    fd:close()
  end

  -- ERROR 级别同时输出到 stdout，方便 MAME 子进程捕获
  if level >= LEVELS.ERROR then
    print("[ERROR] " .. line)
  end
end

-- 快捷方法
function Logger:debug(msg) self:log(LEVELS.DEBUG, msg) end
function Logger:info(msg) self:log(LEVELS.INFO, msg) end
function Logger:warn(msg) self:log(LEVELS.WARN, msg) end
function Logger:error(msg) self:log(LEVELS.ERROR, msg) end

-- 元方法：直接调用 logger(msg) 等价于 info
function Logger.__call(self, msg)
  self:info(msg)
end

-- 便捷方法：创建子 logger（继承模块名前缀）
function Logger:child(suffix)
  return Logger.new(self.name .. "/" .. suffix, self.level)
end

-- 暴露 LEVELS 常量，供外部使用
Logger.LEVELS = LEVELS
Logger.LEVEL_NAMES = LEVEL_NAMES

return Logger
