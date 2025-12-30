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
    -- 假设 state == GeneralState.Normal 表示激活
    return general.state == GeneralState.Normal
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
        star = cfg.star, -- 稀有度(星级)
        star_lv = 0, -- 稀有度(星级)进阶等级级
        arms = cfg.arms[1], -- 兵种
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
        state = GeneralState.Normal, -- 0:正常，1:转换掉了
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

-- 批量更新接口已迁移到 m_generals.lua
-- 体力更新逻辑已迁移到 m_generals.lua，由玩家模块自行管理

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

-- 初始化服务（不再加载所有武将）
function CMD.load()
    -- 只创建NPC武将（如果还没有）
    local ok, generals = skynet.call(".mysql", "lua", "select_by_conditions", 
        "tb_general_1", 
        {rid = 0, state = GeneralState.Normal})
    
    if not ok or not generals or #generals == 0 then
        -- 创建NPC武将
        local gs, ok = createNPC()
        if ok and gs then
            for _, g in ipairs(gs) do
                addGeneral(g)
            end
        end
    end
    
    print("general_manager load success")
end

-- 以下接口已迁移到 m_generals.lua，这里只保留 NPC 相关功能

-- 获取NPC武将
function CMD.getNPCGenerals(cfgIds, levels)
    if not cfgIds or not levels or #cfgIds ~= #levels then
        return nil, false
    end
    
    -- 从内存缓存中获取NPC武将（rid=0）
    local npcGenerals = genByRole[0] or {}
    
    local target = {}
    for i = 1, #cfgIds do
        local cfgId = cfgIds[i]
        local level = levels[i]
        
        for _, g in ipairs(npcGenerals) do
            if g.level == level and g.cfgId == cfgId and isGeneralActive(g) then
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
