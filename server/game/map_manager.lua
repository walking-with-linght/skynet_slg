--[[
地图建筑管理服务
负责管理玩家在地图上的建筑（要塞、城市、资源点等）
]]

local skynet = require "skynet"
local base = require "base"
local basefunc = require "basefunc"
local sharedata = require "skynet.sharedata"
local cjson = require "cjson"
require "skynet.manager"

local CMD = base.CMD
local PUBLIC = base.PUBLIC
local DATA = base.DATA
local REQUEST = base.REQUEST

-- 建筑类型常量
local BuildType = {
    SystemFortress = 50,  -- 系统要塞
    SystemCity = 51,      -- 系统城市
    ResourceLand = 52,    -- 资源土地
    ResourceIron = 53,    -- 铁矿资源
    ResourceStone = 54,   -- 石矿资源
    ResourceGrain = 55,   -- 粮食资源
    PlayerFortress = 56,  -- 玩家要塞
}

-- 建筑状态
local GeneralState = {
    Normal = 0,
    Convert = 1,
}

-- 数据库表名（分服表）
local TABLE_NAME = "tb_map_role_build_1"

-- 数据库字段定义
local DB_SCHEMA = {
    id = "int",
    rid = "int",
    type = "int",
    level = "int",
    op_level = "int",
    x = "int",
    y = "int",
    name = "string",
    max_durable = "int",
    cur_durable = "int",
    end_time = "timestamp",
    occupy_time = "timestamp",
    giveUp_time = "int",
}

-- 内存缓存：按坐标索引 {x_y = build}
local buildByPos = {}
-- 内存缓存：按角色ID索引 {rid = {build1, build2, ...}}
local buildByRid = {}
-- 内存缓存：按建筑ID索引 {id = build}
local buildById = {}
-- 放弃队列：{build_id = giveUp_time}
local giveUpQueue = {}
-- 拆除队列：{build_id = end_time}
local destroyQueue = {}

-- 城市内存缓存：按坐标索引 {x_y = city}
local cityByPos = {}
-- 城市内存缓存：按角色ID索引 {rid = {city1, city2, ...}}
local cityByRid = {}
-- 城市内存缓存：按城市ID索引 {cityId = city}
local cityById = {}

-- 缓存配置数据
local mapData = nil
local mapBuildConfig = nil
local mapBuildCustomConfig = nil
local basicConfig = nil

-- 建筑类型缓存：按类型索引 {buildType = {city1, city2, ...}}
local buildTypeCache = {}
-- 建筑位置缓存：按坐标索引 {x_y = {type, level}}
local buildPosCache = {}
-- 缓存是否已初始化
local buildTypeCacheInitialized = false

-- 获取配置
local function getMapData()
    if not mapData then
        mapData = sharedata.query("config/map.json")
    end
    return mapData
end
-- 生成坐标键
local function posKey(x, y)
    return x .. "_" .. y
end

-- 初始化建筑类型缓存（一次性遍历配置，填充所有类型缓存）
local function initBuildTypeCache()
    if buildTypeCacheInitialized then
        return
    end
    
    local mapData = getMapData()
    if not mapData or not mapData.list then
        buildTypeCacheInitialized = true
        return
    end
    
    local mapWidth = mapData.w or mapData.width
    if not mapWidth then
        buildTypeCacheInitialized = true
        return
    end
    
    -- 初始化所有建筑类型的缓存表
    buildTypeCache[BuildType.SystemFortress] = {}
    buildTypeCache[BuildType.SystemCity] = {}
    buildTypeCache[BuildType.ResourceLand] = {}
    buildTypeCache[BuildType.ResourceIron] = {}
    buildTypeCache[BuildType.ResourceStone] = {}
    buildTypeCache[BuildType.ResourceGrain] = {}
    buildTypeCache[BuildType.PlayerFortress] = {}
    
    -- 遍历地图配置，填充所有类型的缓存
    for i, item in ipairs(mapData.list) do
        if type(item) == "table" and #item >= 2 then
            local buildType = item[1]
            local level = item[2] or 1
            
            -- 计算坐标：i 从 1 开始，需要减 1
            local index = i - 1
            local x = index % mapWidth
            local y = math.floor(index / mapWidth)
            
            local buildInfo = {
                x = x,
                y = y,
                type = buildType,
                level = level,
            }
            
            -- 添加到对应类型的缓存
            if buildTypeCache[buildType] then
                table.insert(buildTypeCache[buildType], buildInfo)
            end
            
            -- 添加到位置缓存（用于快速查找）
            local key = posKey(x, y)
            buildPosCache[key] = {
                type = buildType,
                level = level,
            }
        end
    end
    
    buildTypeCacheInitialized = true
    print(string.format("建筑类型缓存初始化完成: 系统城池=%d, 系统要塞=%d", 
        #buildTypeCache[BuildType.SystemCity], 
        #buildTypeCache[BuildType.SystemFortress]))
end

-- 从缓存中获取指定类型的建筑列表
local function getBuildsByType(buildType)
    if not buildTypeCacheInitialized then
        initBuildTypeCache()
    end
    
    return buildTypeCache[buildType] or {}
end

-- 从配置中提取系统城池列表（从缓存读取）
local function getSystemCitiesFromConfig()
    return getBuildsByType(BuildType.SystemCity)
end

-- 从配置中提取系统要塞列表（从缓存读取）
local function getSystemFortressesFromConfig()
    return getBuildsByType(BuildType.SystemFortress)
end

-- 判断指定位置是否为系统城池（从缓存读取）
function PUBLIC.isSystemCity(x, y)
    if not buildTypeCacheInitialized then
        initBuildTypeCache()
    end
    
    local key = posKey(x, y)
    local posInfo = buildPosCache[key]
    if posInfo and posInfo.type == BuildType.SystemCity then
        return true
    end
    return false
end

-- 判断指定位置是否为系统要塞（从缓存读取）
function PUBLIC.isSystemFortress(x, y)
    if not buildTypeCacheInitialized then
        initBuildTypeCache()
    end
    
    local key = posKey(x, y)
    local posInfo = buildPosCache[key]
    if posInfo and posInfo.type == BuildType.SystemFortress then
        return true
    end
    return false
end

-- 获取指定位置的建筑类型和等级（从缓存读取）
function PUBLIC.getBuildTypeAtPos(x, y)
    if not buildTypeCacheInitialized then
        initBuildTypeCache()
    end
    
    local key = posKey(x, y)
    return buildPosCache[key]
end

-- 建筑配置缓存：按 type_level 索引 {type_level = config}
local buildConfigCache = {}
local buildConfigCacheInitialized = false

-- 初始化建筑配置缓存
local function initBuildConfigCache()
    if buildConfigCacheInitialized then
        return
    end
    
    if not mapBuildConfig then
        mapBuildConfig = sharedata.query("config/map_build.lua")
    end
    
    if mapBuildConfig and mapBuildConfig.cfg then
        for _, cfg in ipairs(mapBuildConfig.cfg) do
            if cfg.type and cfg.level then
                local key = cfg.type .. "_" .. cfg.level
                buildConfigCache[key] = cfg
            end
        end
    end
    
    buildConfigCacheInitialized = true
    print("建筑配置缓存初始化完成，共", #(mapBuildConfig and mapBuildConfig.cfg or {}), "个配置")
end

local function getMapBuildConfig()
    if not mapBuildConfig then
        mapBuildConfig = sharedata.query("config/map_build.lua")
        -- 加载配置后立即初始化缓存
        if not buildConfigCacheInitialized then
            initBuildConfigCache()
        end
    elseif not buildConfigCacheInitialized then
        -- 如果配置已加载但缓存未初始化，初始化缓存
        initBuildConfigCache()
    end
    return mapBuildConfig
end

-- 根据类型和等级快速获取建筑配置（从缓存读取）
local function getBuildConfigByTypeLevel(buildType, level)
    if not buildConfigCacheInitialized then
        initBuildConfigCache()
    end
    
    local key = buildType .. "_" .. level
    return buildConfigCache[key]
end

local function getMapBuildCustomConfig()
    if not mapBuildCustomConfig then
        mapBuildCustomConfig = sharedata.query("config/map_build_custom.lua")
    end
    return mapBuildCustomConfig
end

local function getBasicConfig()
    if not basicConfig then
        basicConfig = sharedata.query("config/basic.lua")
    end
    return basicConfig
end

-- 根据坐标计算位置索引
local function toPositionIndex(x, y, mapWidth)
    return y * mapWidth + x
end



-- 检查地图配置中该位置是否可以建
local function isCanBuildByMapConfig(x, y)
    local mapData = getMapData()
    if not mapData or not mapData.list then
        return true
    end
    
    local mapWidth = mapData.w or mapData.width
    if not mapWidth then
        return true
    end
    
    local posIndex = toPositionIndex(x, y, mapWidth)
    local mapItem = mapData.list[posIndex + 1]
    
    if not mapItem then
        return false
    end
    
    local mapType = mapItem[1]
    if mapType == 0 then
        return false
    end
    
    return true
end

-- 将城市数据添加到缓存（接受已查询的数据，避免重复查询）
local function addCityDataToCache(cityData)
    if not cityData or not cityData.cityId then
        return nil
    end
    
    -- 如果已经在缓存中，直接返回
    if cityById[cityData.cityId] then
        return cityById[cityData.cityId]
    end
    
    local city = cityData
    local key = posKey(city.x, city.y)
    cityByPos[key] = city
    cityById[city.cityId] = city
    
    local rid = city.rid or 0
    if not cityByRid[rid] then
        cityByRid[rid] = {}
    end
    
    -- 检查是否已存在（避免重复添加）
    local exists = false
    for _, c in ipairs(cityByRid[rid]) do
        if c.cityId == city.cityId then
            exists = true
            break
        end
    end
    
    if not exists then
        table.insert(cityByRid[rid], city)
    end
    
    return city
end


-- 根据坐标获取城市（带缓存）
local function getCityByPos(x, y)
    local key = posKey(x, y)
    local city = cityByPos[key]
    
    if not city then
        -- 从数据库加载
        local ok, data = skynet.call(".mysql", "lua", "select_one_by_conditions", 
            "tb_map_role_city_1", {x = x, y = y})
        
        if ok and data then
            -- 直接使用已查询的数据，避免重复查询
            city = addCityDataToCache(data)
        end
    end
    
    return city
end

-- 添加城市到缓存
local function addCityToCache(city)
    if not city or not city.cityId then
        return false
    end
    
    local key = posKey(city.x, city.y)
    cityByPos[key] = city
    cityById[city.cityId] = city
    
    local rid = city.rid or 0
    if not cityByRid[rid] then
        cityByRid[rid] = {}
    end
    
    -- 检查是否已存在
    local exists = false
    for _, c in ipairs(cityByRid[rid]) do
        if c.cityId == city.cityId then
            exists = true
            break
        end
    end
    
    if not exists then
        table.insert(cityByRid[rid], city)
    end
    
    return true
end

-- 从缓存移除城市
local function removeCityFromCache(city)
    if not city or not city.cityId then
        return false
    end
    
    local key = posKey(city.x, city.y)
    cityByPos[key] = nil
    cityById[city.cityId] = nil
    
    local rid = city.rid or 0
    if cityByRid[rid] then
        for i, c in ipairs(cityByRid[rid]) do
            if c.cityId == city.cityId then
                table.remove(cityByRid[rid], i)
                break
            end
        end
    end
    
    return true
end

-- 检查位置是否已有城市或建筑
function PUBLIC.isPositionEmpty(x, y)
    -- 1. 检查地图配置
    if not isCanBuildByMapConfig(x, y) then
        return false
    end
    
    -- 2. 检查是否有玩家城市（先查内存缓存）
    local key = posKey(x, y)
    if cityByPos[key] then
        return false
    end
    
    -- 如果缓存中没有，查数据库并加入缓存
    local city = getCityByPos(x, y)
    if city then
        return false
    end
    
    -- 3. 检查是否有玩家建筑（先查内存缓存）
    if buildByPos[key] then
        return false
    end
    
    -- 再查数据库（如果缓存中没有）
    local ok, existingBuild = skynet.call(".mysql", "lua", "select_one_by_conditions", 
        TABLE_NAME, 
        {x = x, y = y})
    
    if ok and existingBuild then
        -- 将查询到的建筑加入缓存，避免下次重复查询
        addBuildDataToCache(existingBuild)
        return false
    end
    
    return true
end

-- 根据坐标提供对应建筑配置
function CMD.getBuildConfigByPosition(x, y)
    local mapData = getMapData()
    if not mapData or not mapData.list then
        return nil
    end
    local mapWidth = mapData.w or mapData.width
    local posIndex = toPositionIndex(x, y, mapWidth)
    return mapData.list[posIndex + 1]
end

-- 获取建筑配置（根据类型和等级，从缓存读取）
local function getBuildConfig(buildType, level)
    return getBuildConfigByTypeLevel(buildType, level)
end

-- 获取建筑建造/升级配置（玩家要塞）
local function getBuildCustomConfig(buildType, level)
    local config = getMapBuildCustomConfig()
    if not config or not config.cfg then
        return nil
    end
    
    for _, cfg in ipairs(config.cfg) do
        if cfg.type == buildType then
            for _, levelCfg in ipairs(cfg.levels or {}) do
                if levelCfg.level == level then
                    return levelCfg
                end
            end
        end
    end
    
    return nil
end

-- 初始化建筑属性（从配置加载）
local function initBuild(build)
    local cfg = getBuildConfig(build.type, build.level)
    if not cfg then
        -- 尝试从自定义配置获取（玩家要塞）
        cfg = getBuildCustomConfig(build.type, build.level)
    end
    
    if cfg then
        build.name = cfg.name or build.name
        build.max_durable = cfg.durable or build.max_durable
        build.cur_durable = cfg.durable or build.cur_durable
        build.defender = cfg.defender or 0
        
        -- 资源产出（临时字段，从配置计算）
        build.wood = cfg.wood or 0
        build.iron = cfg.iron or 0
        build.stone = cfg.stone or 0
        build.grain = cfg.grain or 0
    end
end

-- 重置建筑为未占领状态
local function resetBuild(build)
    build.rid = 0
    build.occupy_time = nil
    build.giveUp_time = 0
    build.end_time = nil
    build.op_level = build.level
    
    -- 恢复原始资源类型（从地图配置获取）
    local mapCfg = CMD.getBuildConfigByPosition(build.x, build.y)
    if mapCfg then
        local resType = mapCfg[1]  -- type
        local resLevel = mapCfg[2] or 1  -- level
        
        -- 根据资源类型设置建筑类型
        if resType >= 52 and resType <= 55 then
            build.type = resType
            build.level = resLevel
            initBuild(build)
        end
    end
end

-- 将建筑转换为资源点（拆除时使用）
local function convertToRes(build)
    local mapCfg = CMD.getBuildConfigByPosition(build.x, build.y)
    if mapCfg then
        local resType = mapCfg[1]
        local resLevel = mapCfg[2] or 1
        
        build.type = resType
        build.level = resLevel
        build.op_level = build.level
        build.rid = 0
        build.occupy_time = nil
        build.giveUp_time = 0
        build.end_time = nil
        
        initBuild(build)
    end
end

-- 状态判断方法
local function isInGiveUp(build)
    return build.giveUp_time and build.giveUp_time > 0
end

local function isWarFree(build)
    if not build.occupy_time then
        return false
    end
    
    local basicConfig = getBasicConfig()
    local warFreeTime = (basicConfig.build and basicConfig.build.war_free) or 20  -- 秒
    
    local occupyTime = build.occupy_time
    if type(occupyTime) == "string" then
        -- 转换为时间戳
        occupyTime = os.time({year = tonumber(string.sub(occupyTime, 1, 4)),
                              month = tonumber(string.sub(occupyTime, 6, 7)),
                              day = tonumber(string.sub(occupyTime, 9, 10)),
                              hour = tonumber(string.sub(occupyTime, 12, 13)),
                              min = tonumber(string.sub(occupyTime, 15, 16)),
                              sec = tonumber(string.sub(occupyTime, 18, 19))})
    end
    
    local curTime = os.time()
    return (curTime - occupyTime) < warFreeTime
end

local function isResBuild(build)
    return build.type >= 52 and build.type <= 55
end

local function isBusy(build)
    return build.level ~= build.op_level
end

local function isHaveModifyLVAuth(build)
    -- 只有玩家要塞可以修改等级
    return build.type == BuildType.PlayerFortress
end

local function isHasTransferAuth(build)
    -- 要塞类型有调兵权限
    return build.type == BuildType.SystemFortress or build.type == BuildType.PlayerFortress
end

-- 计算视野范围
local function cellRadius(build)
    if build.type == BuildType.SystemCity then
        -- 系统城市根据等级返回1-3
        return math.min(3, math.max(1, build.level))
    end
    return 1
end

-- 建造或升级
local function buildOrUp(build, targetLevel, buildTime)
    build.op_level = targetLevel
    build.level = targetLevel - 1  -- 建造中，等级为目标-1
    build.end_time = os.time() + buildTime
    
    -- 清空资源产出和放弃时间
    build.wood = 0
    build.iron = 0
    build.stone = 0
    build.grain = 0
    build.giveUp_time = 0
end

-- 拆除建筑
local function delBuild(build, destroyTime)
    build.op_level = 0
    build.end_time = os.time() + destroyTime
end

-- 转换为协议对象（自动检查建造/升级是否完成）
local function toProto(build)
    -- 检查建造/升级是否完成
    if build.end_time and isHasTransferAuth(build) then
        local endTime = build.end_time
        if type(endTime) == "string" then
            -- 转换为时间戳
            endTime = os.time({year = tonumber(string.sub(endTime, 1, 4)),
                              month = tonumber(string.sub(endTime, 6, 7)),
                              day = tonumber(string.sub(endTime, 9, 10)),
                              hour = tonumber(string.sub(endTime, 12, 13)),
                              min = tonumber(string.sub(endTime, 15, 16)),
                              sec = tonumber(string.sub(endTime, 18, 19))})
        end
        
        local curTime = os.time()
        if curTime >= endTime then
            if build.op_level == 0 then
                -- 拆除完成
                convertToRes(build)
            else
                -- 建造/升级完成
                build.level = build.op_level
                initBuild(build)
                build.end_time = nil
            end
            
            -- 保存到数据库
            PUBLIC.saveBuild(build)
        end
    end
    
    -- 返回协议对象
    return {
        id = build.id,
        rid = build.rid,
        type = build.type,
        level = build.level,
        op_level = build.op_level or build.level,
        x = build.x,
        y = build.y,
        name = build.name,
        wood = build.wood or 0,
        iron = build.iron or 0,
        stone = build.stone or 0,
        grain = build.grain or 0,
        defender = build.defender or 0,
        cur_durable = build.cur_durable,
        max_durable = build.max_durable,
        occupy_time = build.occupy_time,
        end_time = build.end_time,
        giveUp_time = build.giveUp_time or 0,
    }
end

-- 保存建筑到数据库
function PUBLIC.saveBuild(build)
    if not build or not build.id then
        return false
    end
    
    return PUBLIC.saveDbData(TABLE_NAME, "id", build.id, build, DB_SCHEMA)
end

-- 推送建筑变化（通知相关玩家）
local function pushBuild(build)
    -- 获取建筑所有者
    local rid = build.rid or 0
    if rid > 0 then
        -- 通知建筑所有者（通过 agent_manager）
        local ok, agent = pcall(skynet.call, ".agent_manager", "lua", "getAgent", rid)
        if ok and agent then
            skynet.send(agent, "lua", "pushBuild", toProto(build))
        end
    end
    
    -- 通知视野范围内的玩家（TODO: 实现视野系统）
    -- local radius = cellRadius(build)
    -- local players = getPlayersInRange(build.x, build.y, radius)
    -- for _, playerRid in ipairs(players) do
    --     local ok, agent = pcall(skynet.call, ".agent_manager", "lua", "getAgent", playerRid)
    --     if ok and agent then
    --         skynet.send(agent, "lua", "pushBuild", toProto(build))
    --     end
    -- end
end

-- 同步执行（数据库更新 + 推送通知）
local function syncExecute(build)
    PUBLIC.saveBuild(build)
    pushBuild(build)
end

-- 添加建筑到内存缓存
local function addBuildToCache(build)
    if not build or not build.id then
        return false
    end
    
    local key = posKey(build.x, build.y)
    buildByPos[key] = build
    buildById[build.id] = build
    
    local rid = build.rid or 0
    if not buildByRid[rid] then
        buildByRid[rid] = {}
    end
    table.insert(buildByRid[rid], build)
    
    return true
end

-- 从内存缓存移除建筑
local function removeBuildFromCache(build)
    if not build or not build.id then
        return false
    end
    
    local key = posKey(build.x, build.y)
    buildByPos[key] = nil
    buildById[build.id] = nil
    
    local rid = build.rid or 0
    if buildByRid[rid] then
        for i, b in ipairs(buildByRid[rid]) do
            if b.id == build.id then
                table.remove(buildByRid[rid], i)
                break
            end
        end
    end
end

-- 从数据库加载建筑
-- 将建筑数据添加到缓存（接受已查询的数据，避免重复查询）
local function addBuildDataToCache(buildData)
    if not buildData or not buildData.id then
        return nil
    end
    
    -- 如果已经在缓存中，直接返回
    if buildById[buildData.id] then
        return buildById[buildData.id]
    end
    
    -- 使用 loadDbData 处理类型转换（但这里传入的是单条数据，需要特殊处理）
    -- 由于 loadDbData 需要查询数据库，我们直接手动处理类型转换
    local build = {}
    for k, v in pairs(buildData) do
        build[k] = v
    end
    
    -- 手动处理类型转换（参考 loadDbData 的逻辑）
    for field_name, field_type in pairs(DB_SCHEMA) do
        if build[field_name] ~= nil then
            if field_type == "json" then
                if type(build[field_name]) == "string" and build[field_name] ~= "" then
                    local decode_ok, decoded = pcall(cjson.decode, build[field_name])
                    if decode_ok then
                        build[field_name] = decoded
                    else
                        build[field_name] = {}
                    end
                elseif build[field_name] == "" or build[field_name] == nil then
                    build[field_name] = {}
                end
            elseif field_type == "int" then
                build[field_name] = tonumber(build[field_name]) or 0
            elseif field_type == "float" then
                build[field_name] = tonumber(build[field_name]) or 0.0
            elseif field_type == "timestamp" or field_type == "datetime" then
                if build[field_name] == nil or build[field_name] == "" then
                    build[field_name] = nil
                else
                    build[field_name] = tostring(build[field_name])
                end
            end
        end
    end
    
    initBuild(build)
    addBuildToCache(build)
    
    return build
end

-- 从数据库加载建筑到缓存（仅在真正需要查询时使用）
local function loadBuildFromDb(buildId)
    -- 先检查缓存
    if buildById[buildId] then
        return buildById[buildId]
    end
    
    local ok, data = skynet.call(".mysql", "lua", "select_one_by_key", 
        TABLE_NAME, "id", buildId)
    
    if not ok or not data then
        return nil
    end
    
    -- 直接使用已查询的数据，避免重复查询
    return addBuildDataToCache(data)
end

-- 根据坐标获取建筑
function CMD.getBuildByPos(x, y)
    local key = posKey(x, y)
    local build = buildByPos[key]
    
    if not build then
        -- 从数据库加载
        local ok, data = skynet.call(".mysql", "lua", "select_one_by_conditions", 
            TABLE_NAME, {x = x, y = y})
        
        if ok and data then
            -- 直接使用已查询的数据，避免重复查询
            build = addBuildDataToCache(data)
        end
    end
    
    return build
end

-- 根据ID获取建筑
function CMD.getBuildById(buildId)
    local build = buildById[buildId]
    
    if not build then
        build = loadBuildFromDb(buildId)
    end
    
    return build
end

-- 获取角色的所有建筑
function CMD.getBuildsByRid(rid)
    local builds = buildByRid[rid] or {}
    
    -- 如果内存中没有，从数据库加载
    if #builds == 0 then
        local ok, data = skynet.call(".mysql", "lua", "select_by_key", 
            TABLE_NAME, "rid", rid)
        
        if ok and data then
            -- 直接使用已查询的数据，避免重复查询
            for _, row in ipairs(data) do
                local build = addBuildDataToCache(row)
                if build then
                    table.insert(builds, build)
                end
            end
        end
    end
    
    return builds
end

-- 占领建筑
function CMD.occupyBuild(x, y, rid)
    local build = CMD.getBuildByPos(x, y)
    
    if not build then
        -- 创建新建筑（从地图配置获取类型）
        local mapCfg = CMD.getBuildConfigByPosition(x, y)
        if not mapCfg then
            return false, "位置不可建"
        end
        
        local buildType = mapCfg[1]
        local buildLevel = mapCfg[2] or 1
        
        build = {
            rid = rid,
            type = buildType,
            level = buildLevel,
            op_level = buildLevel,
            x = x,
            y = y,
            name = "",
            max_durable = 0,
            cur_durable = 0,
            occupy_time = os.time(),
            giveUp_time = 0,
        }
        
        initBuild(build)
        
        -- 插入数据库
        local ok, buildId = skynet.call(".mysql", "lua", "insert", TABLE_NAME, {
            rid = build.rid,
            type = build.type,
            level = build.level,
            op_level = build.op_level,
            x = build.x,
            y = build.y,
            name = build.name,
            max_durable = build.max_durable,
            cur_durable = build.cur_durable,
            occupy_time = os.date('%Y-%m-%d %H:%M:%S', build.occupy_time),
            giveUp_time = build.giveUp_time,
        })
        
        if not ok then
            return false, "创建建筑失败"
        end
        
        build.id = buildId
        addBuildToCache(build)
    else
        -- 更新占领信息
        build.rid = rid
        build.occupy_time = os.time()
        build.giveUp_time = 0
        syncExecute(build)
    end
    
    return true, build
end

-- 获取建造要塞所需的资源
function CMD.getBuildFortressNeed(targetLevel)
    local cfg = getBuildCustomConfig(BuildType.PlayerFortress, targetLevel)
    if not cfg then
        return nil, "配置不存在"
    end
    return cfg.need
end

-- 建造要塞（调用方需要先扣除资源）
function CMD.buildFortress(x, y, rid, targetLevel)
    local build = CMD.getBuildByPos(x, y)
    
    if not build then
        return false, "建筑不存在"
    end
    
    -- 检查：是否为资源建筑
    if not isResBuild(build) then
        return false, "只能在地块上建造要塞"
    end
    
    -- 检查：是否空闲
    if isBusy(build) then
        return false, "建筑正在操作中"
    end
    
    -- 检查：要塞数量是否超限
    local builds = CMD.getBuildsByRid(rid)
    local fortressCount = 0
    for _, b in ipairs(builds) do
        if b.type == BuildType.PlayerFortress then
            fortressCount = fortressCount + 1
        end
    end
    
    local basicConfig = getBasicConfig()
    local limit = (basicConfig.build and basicConfig.build.fortress_limit) or 10
    if fortressCount >= limit then
        return false, "要塞数量已达上限"
    end
    
    -- 获取建造配置
    local cfg = getBuildCustomConfig(BuildType.PlayerFortress, targetLevel)
    if not cfg then
        return false, "配置不存在"
    end
    
    -- 扣除资源（由调用方处理，调用方需要先扣除资源，再调用此接口）
    
    -- 设置建造状态
    build.type = BuildType.PlayerFortress
    build.rid = rid
    buildOrUp(build, targetLevel, cfg.time)
    
    -- 加入拆除队列（用于定时检查）
    destroyQueue[build.id] = build.end_time
    
    syncExecute(build)
    
    return true, build
end

-- 获取升级建筑所需的资源
function CMD.getUpBuildNeed(buildType, targetLevel)
    local cfg = getBuildCustomConfig(buildType, targetLevel)
    if not cfg then
        return nil, "配置不存在"
    end
    return cfg.need
end

-- 升级建筑（调用方需要先扣除资源）
function CMD.upBuild(x, y, rid, targetLevel)
    local build = CMD.getBuildByPos(x, y)
    
    if not build then
        return false, "建筑不存在"
    end
    
    if build.rid ~= rid then
        return false, "不是你的建筑"
    end
    
    -- 检查：是否有修改等级权限
    if not isHaveModifyLVAuth(build) then
        return false, "该建筑不能升级"
    end
    
    -- 检查：是否在放弃中
    if isInGiveUp(build) then
        return false, "建筑正在放弃中"
    end
    
    -- 检查：是否空闲
    if isBusy(build) then
        return false, "建筑正在操作中"
    end
    
    -- 获取升级配置
    local cfg = getBuildCustomConfig(build.type, targetLevel)
    if not cfg then
        return false, "配置不存在"
    end
    
    -- 扣除资源（由调用方处理，调用方需要先扣除资源，再调用此接口）
    
    -- 设置升级状态
    buildOrUp(build, targetLevel, cfg.time)
    
    -- 加入拆除队列
    destroyQueue[build.id] = build.end_time
    
    syncExecute(build)
    
    return true, build
end

-- 放弃领地
function CMD.giveUp(x, y, rid)
    local build = CMD.getBuildByPos(x, y)
    
    if not build then
        return false, "建筑不存在"
    end
    
    if build.rid ~= rid then
        return false, "不是你的建筑"
    end
    
    -- 检查：是否在免战期
    if isWarFree(build) then
        return false, "免战期内不能放弃"
    end
    
    -- 检查：是否已在放弃中
    if isInGiveUp(build) then
        return false, "已在放弃中"
    end
    
    local basicConfig = getBasicConfig()
    local giveUpTime = (basicConfig.build and basicConfig.build.giveUp_time) or 30  -- 秒
    
    build.giveUp_time = os.time() + giveUpTime
    giveUpQueue[build.id] = build.giveUp_time
    
    syncExecute(build)
    
    return true, build
end

-- 拆除建筑
function CMD.delBuild(x, y, rid)
    local build = CMD.getBuildByPos(x, y)
    
    if not build then
        return false, "建筑不存在"
    end
    
    if build.rid ~= rid then
        return false, "不是你的建筑"
    end
    
    -- 检查：是否有修改等级权限
    if not isHaveModifyLVAuth(build) then
        return false, "该建筑不能拆除"
    end
    
    -- 检查：是否在放弃中
    if isInGiveUp(build) then
        return false, "建筑正在放弃中"
    end
    
    -- 检查：是否空闲
    if isBusy(build) then
        return false, "建筑正在操作中"
    end
    
    -- 获取拆除配置（假设拆除时间固定）
    local destroyTime = 60  -- 秒，TODO: 从配置获取
    
    -- 扣除资源（如果需要）
    -- TODO: 从配置获取拆除所需资源
    
    -- 设置拆除状态
    delBuild(build, destroyTime)
    
    -- 加入拆除队列
    destroyQueue[build.id] = build.end_time
    
    syncExecute(build)
    
    return true, build
end

-- 检查放弃队列
function CMD.checkGiveUp()
    local curTime = os.time()
    local affectedPositions = {}
    
    for buildId, giveUpTime in pairs(giveUpQueue) do
        if curTime >= giveUpTime then
            local build = CMD.getBuildById(buildId)
            if build then
                local pos = {x = build.x, y = build.y}
                table.insert(affectedPositions, pos)
                
                resetBuild(build)
                syncExecute(build)
                
                giveUpQueue[buildId] = nil
            end
        end
    end
    
    return affectedPositions
end

-- 检查拆除队列
function CMD.checkDestroy()
    local curTime = os.time()
    
    for buildId, endTime in pairs(destroyQueue) do
        if type(endTime) == "string" then
            -- 转换为时间戳
            endTime = os.time({year = tonumber(string.sub(endTime, 1, 4)),
                              month = tonumber(string.sub(endTime, 6, 7)),
                              day = tonumber(string.sub(endTime, 9, 10)),
                              hour = tonumber(string.sub(endTime, 12, 13)),
                              min = tonumber(string.sub(endTime, 15, 16)),
                              sec = tonumber(string.sub(endTime, 18, 19))})
        end
        
        if curTime >= endTime then
            local build = CMD.getBuildById(buildId)
            if build and build.op_level == 0 then
                convertToRes(build)
                syncExecute(build)
                
                destroyQueue[buildId] = nil
            end
        end
    end
end

-- 扫描区域建筑
function CMD.scanBlock(x, y, length)
    length = length or 5
    local builds = {}
    
    for dx = -length, length do
        for dy = -length, length do
            local px = x + dx
            local py = y + dy
            
            local build = CMD.getBuildByPos(px, py)
            if build then
                table.insert(builds, toProto(build))
            end
        end
    end
    
    return builds
end

-- 获取我的所有建筑
function CMD.myRoleBuild(rid)
    local builds = CMD.getBuildsByRid(rid)
    local result = {}
    for _, build in ipairs(builds) do
        table.insert(result, toProto(build))
    end
    return result
end

-- 检查位置是否可以建城（包含系统城池附近5格检查）
local function isCanBuildCity(x, y, mapWidth, mapHeight)
    -- 检查周围2x2区域是否都在地图范围内
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
    if not PUBLIC.isPositionEmpty(x, y) then
        return false
    end
    
    -- 检查是否在系统城池附近5格内（系统城池附近5格不能有玩家城池）
    -- 直接从缓存读取，避免函数调用
    if not buildTypeCacheInitialized then
        initBuildTypeCache()
    end
    
    local sysCities = buildTypeCache[BuildType.SystemCity] or {}
    for _, sysCity in ipairs(sysCities) do
        if sysCity.x and sysCity.y then
            if x >= sysCity.x - 5 and x <= sysCity.x + 5 and
               y >= sysCity.y - 5 and y <= sysCity.y + 5 then
                return false
            end
        end
    end
    
    return true
end

-- 创建主城池
local function createMainCity(role, x, y)
    local basicConfig = getBasicConfig()
    
    -- 查找主城池配置（type=51, level=1），从缓存读取
    local cityConfig = getBuildConfigByTypeLevel(51, 1)
    
    if not cityConfig then
        -- 使用默认配置
        cityConfig = {
            type = 51,
            level = 1,
            durable = (basicConfig and basicConfig.city and basicConfig.city.durable) or 100000,
            defender = 5
        }
    end
    
    -- 创建城市数据
    local city = {
        rid = role.rid,
        name = (role.nick_name or "玩家") .. "的主城",
        x = x,
        y = y,
        is_main = 1,  -- 主城
        level = cityConfig.level or 1,
        cur_durable = cityConfig.durable or 100000,
        max_durable = cityConfig.durable or 100000,
        union_id = 0,
        union_name = "",
        parent_id = 0,
        occupy_time = os.time(),
    }
    
    local db_city = {
        rid = role.rid,
        name = city.name,
        x = x,
        y = y,
        is_main = 1,
        cur_durable = city.cur_durable,
        created_at = os.date('%Y-%m-%d %H:%M:%S'),
        occupy_time = os.date('%Y-%m-%d %H:%M:%S', city.occupy_time),
    }
    
    -- 插入数据库
    local ok, cityId = skynet.call(".mysql", "lua", "insert", "tb_map_role_city_1", db_city)
    if not ok then
        return false, "创建城市失败"
    end
    
    city.cityId = cityId
    city.created_at = db_city.created_at
    
    -- 添加到缓存
    addCityToCache(city)
    
    return true, city
end

-- 查找合适的位置创建主城池
function CMD.findAndCreateMainCity(role)
    -- 先查找玩家是否已有城池
    local cities = CMD.getCitiesByRid(role.rid)
    if cities and #cities > 0 then
        -- 返回第一个城池（通常是主城）
        return true, cities[1]
    end
    
    -- 从地图配置中获取地图尺寸
    local mapData = getMapData()
    local mapWidth = mapData and (mapData.w or mapData.width) or tonumber(skynet.getenv("MapWith")) or 40
    local mapHeight = mapData and (mapData.h or mapData.height) or tonumber(skynet.getenv("MapHeight")) or 40
    
    -- 尝试多次随机查找合适的位置
    local maxAttempts = 100
    for attempt = 1, maxAttempts do
        local x = math.random(0, mapWidth - 1)
        local y = math.random(0, mapHeight - 1)
        
        -- 检查是否可以建城（包括边界检查、位置是否为空、系统城池附近5格检查）
        if isCanBuildCity(x, y, mapWidth, mapHeight) then
            -- 创建主城池
            local ok, city = createMainCity(role, x, y)
            if ok then
                return true, city
            end
        end
    end
    
    -- 如果随机查找失败，尝试遍历查找
    for x = 0, mapWidth - 1 do
        for y = 0, mapHeight - 1 do
            -- 检查是否可以建城
            if isCanBuildCity(x, y, mapWidth, mapHeight) then
                local ok, city = createMainCity(role, x, y)
                if ok then
                    return true, city
                end
            end
        end
    end
    
    return false, "无法找到合适的位置创建主城池"
end

-- 根据坐标获取城市（供外部调用）
function CMD.getCityByPos(x, y)
    return getCityByPos(x, y)
end

-- 获取角色的所有城市（带缓存）
function CMD.getCitiesByRid(rid)
    local cities = cityByRid[rid] or {}
    
    -- 如果内存中没有，从数据库加载
    if #cities == 0 then
        local ok, data = skynet.call(".mysql", "lua", "select_by_key", 
            "tb_map_role_city_1", "rid", rid)
        
        if ok and data then
            for _, row in ipairs(data) do
                -- 直接使用已查询的数据，避免重复查询
                local city = addCityDataToCache(row)
                if city then
                    table.insert(cities, city)
                end
            end
        end
    end
    
    return cities
end

-- 初始化系统建筑（系统城池和系统要塞）
local function initSystemCities()
    -- 从配置中获取系统城池和系统要塞列表
    local configCities = getSystemCitiesFromConfig()
    local configFortresses = getSystemFortressesFromConfig()
    local configCityCount = #configCities
    local configFortressCount = #configFortresses
    local configTotalCount = configCityCount + configFortressCount
    
    -- 查询数据库中的系统建筑数量（type=50或51，rid=0）
    local ok, dbBuilds = skynet.call(".mysql", "lua", "select_by_conditions", 
        TABLE_NAME, {rid = 0})
    
    local dbCityCount = 0
    local dbFortressCount = 0
    local dbTotalCount = 0
    
    if ok and dbBuilds then
        for _, build in ipairs(dbBuilds) do
            if build.type == BuildType.SystemCity then
                dbCityCount = dbCityCount + 1
            elseif build.type == BuildType.SystemFortress then
                dbFortressCount = dbFortressCount + 1
            end
        end
        dbTotalCount = dbCityCount + dbFortressCount
    end
    
    -- 如果数量不一致，删除数据库中的系统建筑，从配置中重新插入
    if dbCityCount ~= configCityCount or dbFortressCount ~= configFortressCount then
        print(string.format("系统建筑数量不一致：系统城池(配置=%d，数据库=%d)，系统要塞(配置=%d，数据库=%d)，开始同步...", 
            configCityCount, dbCityCount, configFortressCount, dbFortressCount))
        
        -- 删除数据库中的所有系统建筑（type=50或51，rid=0）
        if dbTotalCount > 0 then
            local deleteSql = string.format("DELETE FROM %s WHERE (type = %d OR type = %d) AND rid = 0", 
                TABLE_NAME, BuildType.SystemFortress, BuildType.SystemCity)
            local ok, result = skynet.call(".mysql", "lua", "execute", deleteSql)
            if not ok then
                elog("删除系统建筑失败:", result)
                return false
            end
            print("已删除", dbTotalCount, "个系统建筑（系统城池", dbCityCount, "个，系统要塞", dbFortressCount, "个）")
        end
        
        -- 从配置中插入系统建筑
        local insertedCityCount = 0
        local insertedFortressCount = 0
        
        -- 插入系统城池
        if configCityCount > 0 then
            for _, sysCity in ipairs(configCities) do
                -- 查找系统城池配置（type=51, level=sysCity.level），从缓存读取
                local cityConfig = getBuildConfigByTypeLevel(BuildType.SystemCity, sysCity.level)
                
                if not cityConfig then
                    elog("系统城池配置不存在: type=", BuildType.SystemCity, "level=", sysCity.level)
                else
                    -- 创建系统城池数据
                    local build = {
                        rid = 0,  -- 系统建筑 rid = 0
                        type = BuildType.SystemCity,
                        level = sysCity.level,
                        op_level = sysCity.level,
                        x = sysCity.x,
                        y = sysCity.y,
                        name = cityConfig.name or "系统城市",
                        max_durable = cityConfig.durable or 100000,
                        cur_durable = cityConfig.durable or 100000,
                        occupy_time = nil,
                        giveUp_time = 0,
                    }
                    
                    -- 插入数据库
                    local ok, buildId = skynet.call(".mysql", "lua", "insert", TABLE_NAME, {
                        rid = build.rid,
                        type = build.type,
                        level = build.level,
                        op_level = build.op_level,
                        x = build.x,
                        y = build.y,
                        name = build.name,
                        max_durable = build.max_durable,
                        cur_durable = build.cur_durable,
                        occupy_time = nil,
                        giveUp_time = build.giveUp_time,
                    })
                    
                    if ok then
                        build.id = buildId
                        initBuild(build)
                        addBuildToCache(build)
                        insertedCityCount = insertedCityCount + 1
                    else
                        elog("插入系统城池失败: x=", sysCity.x, "y=", sysCity.y)
                    end
                end
            end
        end
        
        -- 插入系统要塞
        if configFortressCount > 0 then
            for _, sysFortress in ipairs(configFortresses) do
                -- 查找系统要塞配置（type=50, level=sysFortress.level），从缓存读取
                local fortressConfig = getBuildConfigByTypeLevel(BuildType.SystemFortress, sysFortress.level)
                
                if not fortressConfig then
                    elog("系统要塞配置不存在: type=", BuildType.SystemFortress, "level=", sysFortress.level)
                else
                    -- 创建系统要塞数据
                    local build = {
                        rid = 0,  -- 系统建筑 rid = 0
                        type = BuildType.SystemFortress,
                        level = sysFortress.level,
                        op_level = sysFortress.level,
                        x = sysFortress.x,
                        y = sysFortress.y,
                        name = fortressConfig.name or "系统要塞",
                        max_durable = fortressConfig.durable or 30000,
                        cur_durable = fortressConfig.durable or 30000,
                        occupy_time = nil,
                        giveUp_time = 0,
                    }
                    
                    -- 插入数据库
                    local ok, buildId = skynet.call(".mysql", "lua", "insert", TABLE_NAME, {
                        rid = build.rid,
                        type = build.type,
                        level = build.level,
                        op_level = build.op_level,
                        x = build.x,
                        y = build.y,
                        name = build.name,
                        max_durable = build.max_durable,
                        cur_durable = build.cur_durable,
                        occupy_time = nil,
                        giveUp_time = build.giveUp_time,
                    })
                    
                    if ok then
                        build.id = buildId
                        initBuild(build)
                        addBuildToCache(build)
                        insertedFortressCount = insertedFortressCount + 1
                    else
                        elog("插入系统要塞失败: x=", sysFortress.x, "y=", sysFortress.y)
                    end
                end
            end
        end
        
        print(string.format("已插入系统建筑：系统城池 %d 个，系统要塞 %d 个", 
            insertedCityCount, insertedFortressCount))
    else
        print(string.format("系统建筑数量一致：系统城池 %d 个，系统要塞 %d 个", 
            configCityCount, configFortressCount))
        
        -- 即使数量一致，也需要将数据库中的系统建筑加载到缓存
        if ok and dbBuilds then
            for _, row in ipairs(dbBuilds) do
                if row.type == BuildType.SystemCity or row.type == BuildType.SystemFortress then
                    addBuildDataToCache(row)
                end
            end
        end
    end
    
    return true
end

-- 初始化服务
function CMD.load()
    -- 初始化建筑类型缓存（必须先初始化，因为后续会用到）
    initBuildTypeCache()
    
    -- 初始化建筑配置缓存（必须先初始化，因为后续会用到）
    initBuildConfigCache()
    
    -- 初始化系统城池
    initSystemCities()
    
    -- 启动定时任务（每10秒检查一次，100 = 10秒）
    -- local function checkTimer()
    --     CMD.checkGiveUp()
    --     CMD.checkDestroy()
        
    --     -- 继续定时
    --     skynet.timeout(100, checkTimer)
    -- end
    
    -- skynet.timeout(100, checkTimer)
    
    print("map_manager load success")
end


-- 建筑半径
function CMD.CellRadius(x,y)
    local key = posKey(x,y)

    if cityByPos[key] then
        return 1
    end
    local build = buildByPos[key]
    if not build then
        return
    end
    if build.type == BuildType.SystemCity then
        if build.level >= 8 then
            return 3
        elseif build.level >= 5 then
            return 2
        else
            return 1
        end
    else
        return 0
    end
end

-- 获取角色的联盟信息（优先从城市获取，如果没有则查询角色属性表）
local function getRoleUnionInfo(rid)
    -- 优先从城市获取联盟信息
    local cities = CMD.getCitiesByRid(rid)
    if cities and #cities > 0 then
        local city = cities[1]  -- 使用第一个城市
        return city.union_id or 0, city.parent_id or 0  -- 返回 union_id, parent_id
    end
    
    -- 如果没有城市，从角色属性表获取 parent_id
    local ok, attr = skynet.call(".mysql", "lua", "select_one_by_key", 
        "tb_role_attribute_1", "rid", rid)
    if ok and attr then
        local parentId = attr.parent_id or 0
        return 0, parentId  -- 返回 union_id=0, parent_id
    end
    
    return 0, 0
end

-- 是否能到达该点
function CMD.IsCanArrive(role, x, y)
    local radius = CMD.CellRadius(x, y) or 0
    local unionId = role.union_id or 0
    local rid = role.rid or 0
    
    -- 查找10格半径内的建筑和城市
    for tx = x - 10, x + 10 do
        for ty = y - 10, y + 10 do
            -- 检查建筑
            local build = CMD.getBuildByPos(tx, ty)
            if build then
                local absX = math.abs(x - tx)
                local absY = math.abs(y - ty)
                local buildRadius = CMD.CellRadius(tx, ty) or 0
                
                if absX <= radius + buildRadius + 1 and absY <= radius + buildRadius + 1 then
                    local buildRid = build.rid or 0
                    -- 获取建筑的联盟信息
                    local buildUnionId, buildParentId = getRoleUnionInfo(buildRid)
                    
                    -- 检查是否是同一个玩家或同一联盟
                    if buildRid == rid or (unionId ~= 0 and (unionId == buildUnionId or unionId == buildParentId)) then
                        return true
                    end
                end
            end
            
            -- 检查城市
            local city = CMD.getCityByPos(tx, ty)
            if city then
                local absX = math.abs(x - tx)
                local absY = math.abs(y - ty)
                local cityRadius = CMD.CellRadius(tx, ty) or 0
                
                if absX <= radius + cityRadius + 1 and absY <= radius + cityRadius + 1 then
                    local cityRid = city.rid or 0
                    local cityUnionId = city.union_id or 0
                    local cityParentId = city.parent_id or 0
                    
                    -- 检查是否是同一个玩家或同一联盟
                    if cityRid == rid or (unionId ~= 0 and (unionId == cityUnionId or unionId == cityParentId)) then
                        return true
                    end
                end
            end
        end
    end
    
    return false
end

-- 服务启动
skynet.init(function()
    CMD.load()
end)

base.start_service(".map_manager")

