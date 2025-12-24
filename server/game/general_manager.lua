--[[
将领管理服务
参考 general_mgr.go 实现
]]

local skynet = require "skynet"
local base = require "base"
local basefunc = require "basefunc"
local sharedata = require "skynet.sharedata"
require "skynet.manager"
local cjson = require "cjson"

local CMD = base.CMD
local PUBLIC = base.PUBLIC
local DATA = base.DATA
local REQUEST = base.REQUEST

-- 武将状态常量
local GeneralNormal = 0  -- 正常状态

-- 内存缓存
local genByRole = {}  -- 按角色ID索引的武将列表 {rid: {general1, general2, ...}}
local genByGId = {}   -- 按武将ID索引的武将对象 {gid: general}

-- 获取基础配置
local function getBasicConfig()
    return sharedata.query("config/basic.lua")
end

-- 获取武将配置
local function getGeneralConfig()
    return sharedata.query("config/general/general.lua")
end

-- 获取NPC配置
local function getNPCConfig()
    -- 假设NPC配置在某个地方，如果没有可以返回nil
    return sharedata.query("config/npc/npc_army.lua")
end

-- 检查武将是否激活（参考 Go 代码 IsActive）
local function isGeneralActive(general)
    if not general then
        return false
    end
    -- 假设 state == GeneralNormal 表示激活
    return general.state == GeneralNormal
end

-- 添加武将达到内存缓存
local function addGeneral(general)
    if not general or not general.id then
        return false
    end
    
    local rid = general.rid or 0
    local gid = general.id
    
    -- 添加到按角色索引
    if not genByRole[rid] then
        genByRole[rid] = {}
    end
    -- 检查是否已存在
    local exists = false
    for _, g in ipairs(genByRole[rid]) do
        if g.id == gid then
            exists = true
            break
        end
    end
    if not exists then
        table.insert(genByRole[rid], general)
    end
    
    -- 添加到按ID索引
    genByGId[gid] = general
    
    return true
end

-- 创建新武将（参考 Go 代码 model.NewGeneral）
local function newGeneral(cfgId, rid, level)
    local generalConfig = getGeneralConfig()
    if not generalConfig then
        skynet.error("general config not found")
        return nil, false
    end
    
    -- 查找武将配置
    local cfg = nil
    if generalConfig.list then
        for _, c in ipairs(generalConfig.list) do
            if c.cfgId == cfgId then
                cfg = c
                break
            end
        end
    end
    
    if not cfg then
        skynet.error("general cfg not found, cfgId:", cfgId)
        return nil, false
    end
    local default_skills = {{id = 0, lv = 0, cfgId = 0}, {id = 0, lv = 0, cfgId = 0}, {id = 0, lv = 0, cfgId = 0}}
    -- 创建武将数据
    local general = {
        rid = rid or 0,
        cfgId = cfgId,
        level = level or 1,
        physical_power = getBasicConfig().general.physical_power_limit or 100, -- 体力
        -- 其他属性根据配置初始化
        exp = 0, -- 经验
        order = 0,--第几队
        cityId = 0, -- 城池ID
        star = 0, -- 稀有度(星级)
        star_lv = 0, -- 稀有度(星级)进阶等级级
        arms = 0, -- 兵种
        has_pr_point = 0, -- 总属性点
        use_pr_point = 0, -- 已用属性点
        attack_distance = 0, -- 攻击距离
        force_added = 0, -- 已加攻击属性
        strategy_added = 0, -- 已加战略属性
        defense_added = 0, -- 已加防御属性
        speed_added = 0, -- 已加速度属性
        destroy_added = 0, -- 已加破坏属性
        parentId = 0, -- 已合成到武将的id
        compose_type = 0, -- 合成类型
        skills = cjson.encode(default_skills), -- 合成携带的技能类型
        state = GeneralNormal, -- 0:正常，1:转换掉了
        created_at = os.date('%Y-%m-%d %H:%M:%S'), -- 创建时间
    }
    
    -- 插入数据库
    local ok, gid = skynet.call(".mysql", "lua", "insert", "tb_general_1", general)
    if not ok then
        skynet.error("create general failed, cfgId:", cfgId)
        return nil, false
    end
    general.skills = default_skills
    general.id = gid
    return general, true
end

-- 批量更新体力（使用CASE WHEN语句，每100条合并成一条SQL）
local function batchUpdatePhysicalPower(updates)
    if not updates or #updates == 0 then
        return
    end
    
    local batchSize = 100
    local batches = math.ceil(#updates / batchSize)
    
    for batch = 1, batches do
        local startIdx = (batch - 1) * batchSize + 1
        local endIdx = math.min(batch * batchSize, #updates)
        local batchUpdates = {}
        
        for i = startIdx, endIdx do
            table.insert(batchUpdates, updates[i])
        end
        
        if #batchUpdates > 0 then
            -- 构建批量更新SQL：UPDATE table SET field = CASE id WHEN ... THEN ... END WHERE id IN (...)
            local caseWhenParts = {}
            local ids = {}
            
            for _, update in ipairs(batchUpdates) do
                table.insert(caseWhenParts, string.format("WHEN %d THEN %d", update.gid, update.newPower))
                table.insert(ids, tostring(update.gid))
            end
            
            local caseWhen = table.concat(caseWhenParts, " ")
            local idList = table.concat(ids, ",")
            local sql = string.format(
                "UPDATE tb_general_1 SET physical_power = CASE id %s END WHERE id IN (%s);",
                caseWhen, idList
            )
            
            -- 执行批量更新
            local ok = skynet.call(".mysql", "lua", "execute", sql)
            if not ok then
                skynet.error("batch update physical_power failed")
            end
        end
    end
end

-- 更新体力（每小时执行一次）
local function updatePhysicalPower()
    local basicConfig = getBasicConfig()
    local limit = basicConfig.general.physical_power_limit or 100
    local recoverCnt = basicConfig.general.recovery_physical_power or 10
    
    while true do
        skynet.sleep(360000)  -- 1小时 = 3600秒 = 360000 * 0.01秒
        
        -- 收集需要更新的武将
        local updates = {}
        for gid, general in pairs(genByGId) do
            if general.physical_power < limit then
                local newPower = math.min(limit, general.physical_power + recoverCnt)
                if newPower ~= general.physical_power then
                    general.physical_power = newPower
                    table.insert(updates, {
                        gid = gid,
                        newPower = newPower
                    })
                end
            end
        end
        
        -- 批量更新到数据库（每100条合并成一条SQL）
        if #updates > 0 then
            batchUpdatePhysicalPower(updates)
        end
    end
end

-- 创建NPC武将
local function createNPC()
    local npcConfig = getNPCConfig()
    if not npcConfig then
        -- 如果没有NPC配置，返回空列表
        return {}, true
    end
    
    local gs = {}
    
    if npcConfig.armys then
        for _, armys in ipairs(npcConfig.armys) do
            if armys.army then
                for _, cfgs in ipairs(armys.army) do
                    if cfgs.cfgIds and cfgs.lvs then
                        for i, cfgId in ipairs(cfgs.cfgIds) do
                            local level = cfgs.lvs[i] or 1
                            local g, ok = newGeneral(cfgId, 0, level)
                            if not ok then
                                return nil, false
                            end
                            table.insert(gs, g)
                        end
                    end
                end
            end
        end
    end
    
    return gs, true
end

-- 加载所有武将
function CMD.load()
    -- 从数据库加载所有正常状态的武将
    -- 注意：select_by_conditions 返回 (ok, result)，如果查询成功但无结果，result 可能为 nil
    local ok, generals = skynet.call(".mysql", "lua", "select_by_conditions", 
        "tb_general_1", 
        {state = GeneralNormal})
    
    if not ok then
        skynet.error("load generals from db failed")
        return
    end
    
    -- 处理 generals 可能为 nil 的情况
    if not generals then
        generals = {}
    end
    
    -- 清空缓存
    genByRole = {}
    genByGId = {}
    
    -- 加载到内存
    if generals then
        for _, g in ipairs(generals) do
            g.skills = cjson.decode(g.skills)
            addGeneral(g)
        end
    end
    
    -- 如果没有武将，创建NPC
    if not generals or #generals == 0 then
        local gs, ok = createNPC()
        if ok and gs then
            for _, g in ipairs(gs) do
                addGeneral(g)
            end
        end
    end
    
    -- 启动体力更新协程
    skynet.fork(updatePhysicalPower)
    print("general_manager load success")
end

-- 根据角色ID获取武将列表
function CMD.getByRId(rid)
    rid = tonumber(rid) or 0
    
    -- 先从内存查找
    if genByRole[rid] then
        local out = {}
        for _, g in ipairs(genByRole[rid]) do
            if isGeneralActive(g) then
                table.insert(out, g)
            end
        end
        if #out > 0 then
            return out, true
        end
    end
    
    -- 从数据库查找
    local ok, generals = skynet.call(".mysql", "lua", "select_by_conditions", 
        "tb_general_1", 
        {rid = rid, state = GeneralNormal})
    
    if ok and generals and #generals > 0 then
        -- 添加到内存
        for _, g in ipairs(generals) do
            addGeneral(g)
        end
        return generals, true
    else
        -- elog("general not found, rid:", rid)
        return nil, false
    end
end

-- 根据武将ID获取武将
function CMD.getByGId(gid)
    gid = tonumber(gid) or 0
    
    -- 先从内存查找
    if genByGId[gid] then
        local g = genByGId[gid]
        if isGeneralActive(g) then
            return g, true
        else
            return nil, false
        end
    end
    
    -- 从数据库查找
    local ok, general = skynet.call(".mysql", "lua", "select_one_by_conditions", 
        "tb_general_1", 
        {id = gid, state = GeneralNormal})
    
    if ok and general then
        addGeneral(general)
        return general, true
    else
        elog("general gid not found, gid:", gid)
        return nil, false
    end
end

-- 检查角色是否有某个武将
function CMD.hasGeneral(rid, gid)
    rid = tonumber(rid) or 0
    gid = tonumber(gid) or 0
    
    local generals, ok = CMD.getByRId(rid)
    if ok and generals then
        for _, g in ipairs(generals) do
            if g.id == gid then
                return g, true
            end
        end
    end
    return nil, false
end

-- 检查角色是否有多个武将
function CMD.hasGenerals(rid, gIds)
    rid = tonumber(rid) or 0
    if not gIds or type(gIds) ~= "table" then
        return {}, false
    end
    
    local gs = {}
    for _, gid in ipairs(gIds) do
        local g, ok = CMD.hasGeneral(rid, gid)
        if not ok then
            return gs, false
        end
        table.insert(gs, g)
    end
    return gs, true
end

-- 获取角色的武将数量
function CMD.count(rid)
    rid = tonumber(rid) or 0
    local generals, ok = CMD.getByRId(rid)
    if ok then
        return #generals
    else
        return 0
    end
end

-- 创建新武将
function CMD.newGeneral(cfgId, rid, level)
    cfgId = tonumber(cfgId) or -99
    rid = tonumber(rid) or -99
    level = tonumber(level) or 1
    
    local g, ok = newGeneral(cfgId, rid, level)
    if ok then
        addGeneral(g)
    end
    return g, ok
end

-- 获取或创建武将（如果不存在则创建）
function CMD.getOrCreateByRId(rid)
    rid = tonumber(rid) or 0
    
    local generals, ok = CMD.getByRId(rid)
    if ok then
        return generals, true
    else
        -- 创建3个随机武将
        local gs, ok = CMD.randCreateGeneral(rid, 3)
        if not ok then
            return nil, false
        end
        return gs, true
    end
end

-- 随机创建武将
function CMD.randCreateGeneral(rid, nums)
    rid = tonumber(rid) or 0
    nums = tonumber(nums) or 1
    
    local generalConfig = getGeneralConfig()
    if not generalConfig or not generalConfig.list then
        return nil, false
    end
    
    local gs = {}
    
    for i = 1, nums do
        -- 随机抽取一个武将配置（Draw方法）
        local cfgList = generalConfig.list
        if not cfgList or #cfgList == 0 then
            return nil, false
        end
        
        local randomIndex = math.random(1, #cfgList)
        local cfgId = cfgList[randomIndex].cfgId
        
        local g, ok = CMD.newGeneral(cfgId, rid, 1)
        if not ok then
            return nil, false
        end
        table.insert(gs, g)
    end
    
    return gs, true
end

-- 获取NPC武将
function CMD.getNPCGenerals(cfgIds, levels)
    if not cfgIds or not levels or #cfgIds ~= #levels then
        return nil, false
    end
    
    local generals, ok = CMD.getByRId(0)  -- NPC的rid为0
    if not ok then
        return nil, false
    end
    
    local target = {}
    for i = 1, #cfgIds do
        local cfgId = cfgIds[i]
        local level = levels[i]
        
        for _, g in ipairs(generals) do
            if g.level == level and g.cfg_id == cfgId then
                table.insert(target, g)
                break
            end
        end
    end
    
    return target, true
end

-- 获取军队的破坏力
function CMD.getDestroy(army)
    if not army or not army.gens then
        return 0
    end
    
    local destroy = 0
    for _, g in ipairs(army.gens) do
        if g and g.getDestroy then
            destroy = destroy + g.getDestroy()
        elseif g and g.destroy then
            destroy = destroy + (g.destroy or 0)
        end
    end
    return destroy
end

-- 检查体力是否足够
function CMD.physicalPowerIsEnough(army, cost)
    if not army or not army.gens then
        return false
    end
    
    cost = tonumber(cost) or 0
    for _, g in ipairs(army.gens) do
        if g then
            if (g.physical_power or 0) < cost then
                return false
            end
        end
    end
    return true
end

-- 尝试使用体力
function CMD.tryUsePhysicalPower(army, cost)
    if not CMD.physicalPowerIsEnough(army, cost) then
        return false
    end
    
    cost = tonumber(cost) or 0
    for _, g in ipairs(army.gens) do
        if g and g.id then
            g.physical_power = (g.physical_power or 0) - cost
            -- 同步到数据库
            skynet.call(".mysql", "lua", "update", "tb_general_1", 
                "id", g.id, {physical_power = g.physical_power})
            
            -- 更新内存缓存
            if genByGId[g.id] then
                genByGId[g.id].physical_power = g.physical_power
            end
        end
    end
    
    return true
end

-- 服务启动
skynet.init(function()
    CMD.load()
end)
base.start_service(".general_manager")
