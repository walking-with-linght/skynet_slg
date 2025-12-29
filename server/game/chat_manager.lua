--[[
聊天管理服务
功能：
1. 支持多频道（世界聊天、联盟聊天等）
2. 玩家进入/退出频道管理
3. 聊天历史缓存（可配置最大数量）
4. 广播聊天消息到所有在线玩家
]]

local skynet = require "skynet"
local base = require "base"
require "skynet.manager"

local CMD = base.CMD
local PUBLIC = base.PUBLIC
local DATA = base.DATA

local ld = base.LocalData("chat_manager")
local lf = base.LocalFunc("chat_manager")

-- 配置
local CONFIG = {
    -- 每个频道的最大缓存消息数量
    MAX_HISTORY_COUNT = 20,
}

-- 频道类型定义
local CHANNEL_TYPE = {
    WORLD = "world",      -- 世界聊天
    GUILD = "guild",      -- 联盟/公会聊天
    PRIVATE = "private",  -- 私聊
    SYSTEM = "system",    -- 系统消息
}

-- 数据结构：
-- channels[channel_id] = {
--     history = {},  -- 聊天历史列表
--     players = {},  -- 当前在线的玩家 {rid = agent_addr}
-- }
ld.channels = ld.channels or {}

-- 玩家所在频道映射：players_channels[rid] = {channel_id1, channel_id2, ...}
ld.players_channels = ld.players_channels or {}

--[[
初始化频道
]]
local function init_channel(channel_id)
    if not ld.channels[channel_id] then
        ld.channels[channel_id] = {
            history = {},
            players = {},
        }
        print("init_channel", channel_id)
    end
end

--[[
添加消息到历史记录，并限制最大数量
]]
local function add_history(channel_id, message)
    local channel = ld.channels[channel_id]
    if not channel then
        init_channel(channel_id)
        channel = ld.channels[channel_id]
    end
    
    table.insert(channel.history, message)
    
    -- 如果超过最大数量，删除最旧的消息
    if #channel.history > CONFIG.MAX_HISTORY_COUNT then
        table.remove(channel.history, 1)
    end
end

--[[
玩家进入频道
参数：
    rid: 玩家角色ID
    channel_id: 频道ID（如 "world", "guild_123" 等）
    agent_addr: 玩家的agent服务地址
]]
function CMD.join_channel(rid, channel_id, agent_addr)
    rid = assert(tonumber(rid))
    channel_id = assert(tostring(channel_id))
    agent_addr = assert(tonumber(agent_addr))
    
    -- 初始化频道
    init_channel(channel_id)
    local channel = ld.channels[channel_id]
    
    -- 添加到频道玩家列表
    if not channel.players[rid] then
        channel.players[rid] = agent_addr
    end
    
    -- 记录玩家所在的频道
    if not ld.players_channels[rid] then
        ld.players_channels[rid] = {}
    end
    local player_channels = ld.players_channels[rid]
    local found = false
    for i, cid in ipairs(player_channels) do
        if cid == channel_id then
            found = true
            break
        end
    end
    if not found then
        table.insert(player_channels, channel_id)
    end
    
    return true
end

--[[
玩家退出频道
参数：
    rid: 玩家角色ID
    channel_id: 频道ID（可选，如果不传则退出所有频道）
]]
function CMD.leave_channel(rid, channel_id)
    rid = assert(tonumber(rid))
    
    if channel_id then
        -- 退出指定频道
        channel_id = tostring(channel_id)
        local channel = ld.channels[channel_id]
        if channel then
            channel.players[rid] = nil
        end
        
        -- 从玩家频道列表中移除
        if ld.players_channels[rid] then
            local player_channels = ld.players_channels[rid]
            for i, cid in ipairs(player_channels) do
                if cid == channel_id then
                    table.remove(player_channels, i)
                    break
                end
            end
            if #player_channels == 0 then
                ld.players_channels[rid] = nil
            end
        end
    else
        -- 退出所有频道
        if ld.players_channels[rid] then
            local player_channels = ld.players_channels[rid]
            for _, cid in ipairs(player_channels) do
                local channel = ld.channels[cid]
                if channel then
                    channel.players[rid] = nil
                end
            end
            ld.players_channels[rid] = nil
        end
    end
    
    return true
end

--[[
更新玩家agent地址（当玩家重新连接时）
参数：
    rid: 玩家角色ID
    agent_addr: 新的agent服务地址
]]
function CMD.update_agent_addr(rid, agent_addr)
    rid = assert(tonumber(rid))
    agent_addr = assert(tonumber(agent_addr))
    
    -- 更新所有频道中该玩家的agent地址
    if ld.players_channels[rid] then
        local player_channels = ld.players_channels[rid]
        for _, channel_id in ipairs(player_channels) do
            local channel = ld.channels[channel_id]
            if channel and channel.players[rid] then
                channel.players[rid] = agent_addr
            end
        end
    end
    
    return true
end

--[[
发送聊天消息
参数：
    rid: 发送者角色ID
    channel_id: 频道ID
    message: 消息内容 {content, nickname, headId, ...}
返回值：
    success: 是否成功
    error_msg: 错误信息（如果失败）
]]
function CMD.send_message(rid, channel_id, message)
    rid = assert(tonumber(rid))
    channel_id = assert(tostring(channel_id))
    
    -- 检查频道是否存在
    local channel = ld.channels[channel_id]
    if not channel then
        print("频道不存在", channel_id)
        return false, "频道不存在"
    end
    
    -- 检查发送者是否在频道中
    if not channel.players[rid] then
        return false, "玩家不在该频道中"
    end
    
    -- 构造完整消息
    -- local full_message = {
    --     rid = rid,
    --     channel_id = channel_id,
    --     content = message.content,
    --     nickname = message.nickname,
    --     headId = message.headId,
    --     time = os.time(),
    --     -- 可以添加其他字段
    -- }
    
    -- 添加到历史记录
    add_history(channel_id, message)
    
    -- 广播给所有在线玩家（使用非阻塞方式）
    local player_count = 0
    for player_rid, agent_addr in pairs(channel.players) do
        player_count = player_count + 1
        -- 使用skynet.send非阻塞发送，不等待响应
        skynet.send(agent_addr, "lua", "chat_callback", message)
    end
    
    return true, {
        player_count = player_count,
    }
end

--[[
获取聊天历史
参数：
    channel_id: 频道ID
    count: 获取数量（可选，默认返回全部）
返回值：
    history: 聊天历史列表
]]
function CMD.get_history(channel_id, count)
    channel_id = assert(tostring(channel_id))
    
    local channel = ld.channels[channel_id]
    if not channel then
        return {}
    end
    
    local history = channel.history
    if count and count > 0 then
        -- 返回最近count条消息
        local start_idx = math.max(1, #history - count + 1)
        local result = {}
        for i = start_idx, #history do
            table.insert(result, history[i])
        end
        return result
    else
        -- 返回全部历史
        return history
    end
end

--[[
获取频道在线玩家数量
参数：
    channel_id: 频道ID
返回值：
    count: 在线玩家数量
]]
function CMD.get_channel_player_count(channel_id)
    channel_id = assert(tostring(channel_id))
    
    local channel = ld.channels[channel_id]
    if not channel then
        return 0
    end
    
    local count = 0
    for _ in pairs(channel.players) do
        count = count + 1
    end
    
    return count
end

--[[
获取玩家所在的所有频道
参数：
    rid: 玩家角色ID
返回值：
    channels: 频道ID列表
]]
function CMD.get_player_channels(rid)
    rid = assert(tonumber(rid))
    
    if ld.players_channels[rid] then
        return ld.players_channels[rid]
    else
        return {}
    end
end

--[[
设置配置
参数：
    config: 配置表 {MAX_HISTORY_COUNT = 100}
]]
function CMD.set_config(config)
    if config.MAX_HISTORY_COUNT then
        CONFIG.MAX_HISTORY_COUNT = tonumber(config.MAX_HISTORY_COUNT) or 100
    end
    return true
end

--[[
获取配置
]]
function CMD.get_config()
    return {
        MAX_HISTORY_COUNT = CONFIG.MAX_HISTORY_COUNT,
    }
end

--[[
检查玩家是否在频道中
参数：
    rid: 玩家角色ID
    channel_id: 频道ID
返回值：
    is_in_channel: 是否在频道中
]]
function CMD.is_in_channel(rid, channel_id)
    rid = assert(tonumber(rid))
    channel_id = assert(tostring(channel_id))
    
    local channel = ld.channels[channel_id]
    if not channel then
        return false
    end
    
    return channel.players[rid] ~= nil
end

--[[
获取所有频道列表
返回值：
    channels: 频道ID列表
]]
function CMD.get_all_channels()
    local channels = {}
    for channel_id in pairs(ld.channels) do
        table.insert(channels, channel_id)
    end
    return channels
end

--[[
清理频道（移除没有玩家的频道，可选）
参数：
    force: 是否强制清理（即使有玩家也清理）
]]
function CMD.cleanup_channels(force)
    force = force or false
    
    for channel_id, channel in pairs(ld.channels) do
        local has_players = false
        for _ in pairs(channel.players) do
            has_players = true
            break
        end
        
        if force or not has_players then
            -- 清理历史记录（可选，这里保留）
            -- channel.history = {}
            -- 如果频道没有玩家且没有历史，可以删除整个频道
            if not has_players and #channel.history == 0 then
                ld.channels[channel_id] = nil
            end
        end
    end
    
    return true
end

-- 导出频道类型常量
PUBLIC.CHANNEL_TYPE = CHANNEL_TYPE

-- 启动服务
base.start_service(".chat_manager")

