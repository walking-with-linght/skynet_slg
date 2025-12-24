--[[
 $ @Author: 654146770@qq.com
 $ @Date: 2024-06-05 21:52:14
 $ @LastEditors: 654146770@qq.com
 $ @LastEditTime: 2024-07-21 16:39:39
 $ @FilePath: \my_skynet_lib\server\gate_server\logic\service\ws\ws.lua
]]


local skynet = require "skynet"
local base = require "base"
local basefunc = require "basefunc"
local sharedata = require "skynet.sharedata"
require "skynet.manager"



local CMD=base.CMD
local PUBLIC=base.PUBLIC
local DATA=base.DATA
local REQUEST=base.REQUEST

-- 缓存地图配置数据
local mapData = nil
local function getMapData()
    if not mapData then
        mapData = sharedata.query("config/map.json")
    end
    return mapData
end

-- 根据坐标计算位置索引（参考 Go 代码）
-- 从 Go 代码看：X = i % MapWith, Y = i / MapHeight
-- 如果 MapWidth == MapHeight（通常地图是方形的），则 i = Y * MapWidth + X
local function toPositionIndex(x, y, mapWidth)
    return y * mapWidth + x
end

-- 检查地图配置中该位置是否可以建（参考 Go 代码 IsCanBuild）
-- type == 0 表示不能建
local function isCanBuildByMapConfig(x, y)
    local mapData = getMapData()
    if not mapData or not mapData.list then
        return true  -- 如果没有配置，默认可以建
    end
    
    local mapWidth = mapData.w or mapData.width
    if not mapWidth then
        return true  -- 如果没有宽度信息，默认可以建
    end
    
    local posIndex = toPositionIndex(x, y, mapWidth)
    -- Lua 数组索引从 1 开始，所以需要 +1
    local mapItem = mapData.list[posIndex + 1]
    
    if not mapItem then
        return false  -- 位置超出范围
    end
    
    local mapType = mapItem[1]  -- type 是第一个元素 [type, level]
    -- type == 0 表示不能建（参考 Go 代码：if c.Type == 0 { return false }）
    if mapType == 0 then
        return false
    end
    
    return true
end


-- 检查位置是否可以建城（参考 Go 代码 IsCanBuildCity 逻辑）
local function isCanBuildCity(x, y, mapWidth, mapHeight)
    -- 检查周围2x2区域是否都在地图范围内（参考 Go 代码：for i := x-2; i <= x+2; i++）
    for i = x - 2, x + 2 do
        if i < 0 or i >= mapWidth then
            return false
        end
        
        for j = y - 2, y + 2 do
            if j < 0 or j >= mapHeight then
                return false
            end
        end
    end
    
    -- 检查中心点是否可以建城
    -- 根据 Go 代码，需要检查 IsCanBuild(x, y)、RBMgr.IsEmpty、RCMgr.IsEmpty
    if not PUBLIC.isPositionEmpty(x, y) then
        return false
    end
    
    return true
end

-- 检查是否在系统城池附近5格内
local function isNearSystemCity(x, y, sysCities)
    if not sysCities then
        return false
    end
    
    for _, sysCity in ipairs(sysCities) do
        -- 系统城池附近5格不能有玩家城池
        if sysCity.x and sysCity.y then
            if x >= sysCity.x - 5 and x <= sysCity.x + 5 and
               y >= sysCity.y - 5 and y <= sysCity.y + 5 then
                return true
            end
        end
    end
    
    return false
end

-- 检查位置是否已有城市或建筑（完善版）
-- 参考 Go 代码：IsCanBuild(x, y)、RBMgr.IsEmpty(x, y)、RCMgr.IsEmpty(x, y)
function PUBLIC.isPositionEmpty(x, y)
    -- 1. 检查地图配置中该位置是否可以建（type == 0 不能建）
    -- 参考 Go 代码 IsCanBuild：if c.Type == 0 { return false }
    if not isCanBuildByMapConfig(x, y) then
        return false
    end
    
    -- 2. 检查是否有玩家城市（RCMgr.IsEmpty）
    local ok, existingCity = skynet.call(".mysql", "lua", "select_one_by_conditions", 
        "tb_map_role_city_1", 
        {x = x, y = y})
    
    if ok and existingCity then
        return false
    end
    
    -- 3. 检查是否有玩家建筑（RBMgr.IsEmpty）
    -- 假设建筑表名为 tb_map_role_build_1，根据实际情况调整
    local ok, existingBuild = skynet.call(".mysql", "lua", "select_one_by_conditions", 
        "tb_map_role_build_1", 
        {x = x, y = y})
    
    if ok and existingBuild then
        return false
    end
    
    return true
end

-- 创建主城池
local function createMainCity(role, x, y)
    local mapBuildConfig = sharedata.query("config/map_build.lua")
    local basicConfig = sharedata.query("config/basic.lua")
    
    -- 查找主城池配置（type=51, level=1）
    local cityConfig = nil
    for _, cfg in ipairs(mapBuildConfig.cfg) do
        if cfg.type == 51 and cfg.level == 1 then
            cityConfig = cfg
            break
        end
    end
    
    if not cityConfig then
        -- 使用默认配置
        cityConfig = {
            type = 51,
            level = 1,
            durable = basicConfig.city.durable or 100000,
            defender = 5
        }
    end
    
    -- 创建城市数据
    local city = {
        rid = role.rid,
        name = role.nick_name .. "的主城",
        x = x,
        y = y,
        is_main = 1,  -- 主城
        level = cityConfig.level or 1,
        cur_durable = cityConfig.durable or 100000,
        max_durable = cityConfig.durable or 100000,
        union_id = 0,
        union_name = "",
        parent_id = 0,
        occupy_time = math.floor(skynet.time() / 100)  -- 当前时间（秒）
    }
    local db_city = {
        rid = role.rid,
        name = role.nick_name .. "的主城",
        x = x,
        y = y,
        is_main = 1,
        cur_durable = cityConfig.durable or 100000, -- 当前耐久
        created_at = os.date('%Y-%m-%d %H:%M:%S'),
    }
    -- 插入数据库
    local ok, cityId = skynet.call(".mysql", "lua", "insert", "tb_map_role_city_1", db_city)
    if not ok then
        return false, "创建城市失败"
    end
    print("创建城市成功", cityId)
    city.cityId = cityId
    return true, city
end

-- 查找合适的位置创建主城池
function CMD.findAndCreateMainCity(role)
    -- 从地图配置中获取地图尺寸
    local mapData = getMapData()
    local mapWidth = mapData and (mapData.w or mapData.width) or tonumber(skynet.getenv("MapWith")) or 40
    local mapHeight = mapData and (mapData.h or mapData.height) or tonumber(skynet.getenv("MapHeight")) or 40
    
    -- 查询系统城池（如果有系统城池表的话）
    -- 这里假设系统城池存储在某个地方，如果没有可以忽略这个检查
    local sysCities = nil
    -- local ok, sysCities = skynet.call(".mysql", "lua", "select_all", "tb_system_city_1")
    
    -- 尝试多次随机查找合适的位置
    local maxAttempts = 100
    for attempt = 1, maxAttempts do
        local x = math.random(0, mapWidth - 1)
        local y = math.random(0, mapHeight - 1)
        
        -- 检查是否在系统城池附近（系统城池附近5格不能有玩家城池）
        if not isNearSystemCity(x, y, sysCities) then
            -- 检查是否可以建城（包括边界检查和位置是否为空）
            if isCanBuildCity(x, y, mapWidth, mapHeight) then
                -- 创建主城池
                local ok, city = createMainCity(role, x, y)
                if ok then
                    return true, city
                end
            end
        end
    end
    
    -- 如果随机查找失败，尝试遍历查找
    for x = 0, mapWidth - 1 do
        for y = 0, mapHeight - 1 do
            -- 检查是否在系统城池附近
            if not isNearSystemCity(x, y, sysCities) then
                -- 检查是否可以建城
                if isCanBuildCity(x, y, mapWidth, mapHeight) then
                    local ok, city = createMainCity(role, x, y)
                    if ok then
                        return true, city
                    end
                end
            end
        end
    end
    
    return false, "无法找到合适的位置创建主城池"
end


base.start_service(".map_manager")