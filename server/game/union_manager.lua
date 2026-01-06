--[[
联盟管理服务
功能：
1. 联盟的创建、解散、申请、审批、踢人、任命、禅让等操作
2. 智能加载机制：按需加载联盟数据，5分钟后卸载离线联盟
3. 玩家上线/离线管理，记录agent地址
4. 广播通知机制
]]

local skynet = require "skynet"
local base = require "base"
local cjson = require "cjson"
local error_code = require "error_code"
require "skynet.manager"

-- 启用空表作为数组
cjson.encode_empty_table_as_array(true)

local CMD = base.CMD
local PUBLIC = base.PUBLIC
local DATA = base.DATA

local ld = base.LocalData("union_manager")
local lf = base.LocalFunc("union_manager")

-- 配置
local CONFIG = {
    UNLOAD_DELAY = 300,  -- 5分钟后卸载离线联盟（单位：秒，skynet时间单位是1/100秒，所以是30000）
}

-- 数据库表名
local TABLE_COALITION = "tb_coalition_1"
local TABLE_COALITION_APPLY = "tb_coalition_apply_1"
local TABLE_COALITION_LOG = "tb_coalition_log_1"
local TABLE_ROLE_ATTR = "tb_role_attribute_1"

-- 数据库字段定义
local DB_SCHEMA_COALITION = {
    id = "int",
    name = "string",
    members = "string",
    create_id = "int",
    chairman = "int",
    vice_chairman = "int",
    notice = "string",
    state = "int",
    ctime = "timestamp",
}

local DB_SCHEMA_APPLY = {
    id = "int",
    union_id = "int",
    rid = "int",
    state = "int",
    ctime = "timestamp",
}

local DB_SCHEMA_LOG = {
    id = "int",
    union_id = "int",
    op_rid = "int",
    target_id = "int",
    des = "string",
    state = "int",
    ctime = "timestamp",
}

-- 联盟数据缓存：{union_id = union_data}
ld.unions = ld.unions or {}

-- 联盟卸载定时器：{union_id = timer_id}
ld.unload_timers = ld.unload_timers or {}

-- 玩家在线状态：{rid = {agent = agent_addr, union_id = union_id}}
ld.online_players = ld.online_players or {}

-- 联盟成员在线状态：{union_id = {rid1 = agent1, rid2 = agent2, ...}}
ld.union_online_members = ld.union_online_members or {}

-- 申请列表缓存：{union_id = {apply1, apply2, ...}}
ld.union_applies = ld.union_applies or {}

-- 日志缓存：{union_id = {log1, log2, ...}}
ld.union_logs = ld.union_logs or {}

-- 职位常量
local TITLE = {
    CHAIRMAN = 0,      -- 盟主
    VICE_CHAIRMAN = 1, -- 副盟主
    MEMBER = 2,        -- 普通成员
}

-- 日志状态常量
local LOG_STATE = {
    CREATE = 0,        -- 创建
    DISMISS = 1,       -- 解散
    JOIN = 2,          -- 加入
    EXIT = 3,          -- 退出
    KICK = 4,          -- 踢出
    APPOINT = 5,       -- 任命
    ABDICATE = 6,      -- 禅让
    MOD_NOTICE = 7,    -- 修改公告
}

-- 申请状态常量
local APPLY_STATE = {
    PENDING = 0,       -- 未处理
    REJECT = 1,        -- 拒绝
    ACCEPT = 2,        -- 通过
}

-- 解析成员列表（JSON字符串转数组）
local function parseMembers(membersStr)
    if not membersStr or membersStr == "" then
        return {}
    end
    local ok, members = pcall(cjson.decode, membersStr)
    if ok and type(members) == "table" then
        return members
    end
    return {}
end

-- 序列化成员列表（数组转JSON字符串）
local function serializeMembers(members)
    if not members or #members == 0 then
        return "[]"
    end
    return cjson.encode(members)
end

-- 检查成员是否在联盟中
local function isMemberInUnion(members, rid)
    for _, memberRid in ipairs(members) do
        if memberRid == rid then
            return true
        end
    end
    return false
end

-- 添加成员到联盟
local function addMemberToUnion(members, rid)
    if not isMemberInUnion(members, rid) then
        table.insert(members, rid)
    end
end

-- 从联盟移除成员
local function removeMemberFromUnion(members, rid)
    for i, memberRid in ipairs(members) do
        if memberRid == rid then
            table.remove(members, i)
            return true
        end
    end
    return false
end

-- 获取成员职位
local function getMemberTitle(union, rid)
    if union.chairman == rid then
        return TITLE.CHAIRMAN
    elseif union.vice_chairman == rid then
        return TITLE.VICE_CHAIRMAN
    else
        return TITLE.MEMBER
    end
end

-- 检查是否有权限（盟主或副盟主）
local function hasPermission(union, rid)
    return union.chairman == rid or union.vice_chairman == rid
end

-- 检查是否是盟主
local function isChairman(union, rid)
    return union.chairman == rid
end

-- 保存申请到数据库（同步获取ID，然后异步更新）
local function saveApplyAsync(apply)
    if apply.id and apply.id > 0 then
        -- 已有ID，异步更新
        skynet.fork(function()
            PUBLIC.saveDbData(TABLE_COALITION_APPLY, "id", apply.id, apply, DB_SCHEMA_APPLY)
        end)
    else
        -- 没有ID，同步插入获取ID（因为后续操作需要ID）
        local ok, applyId = skynet.call(".mysql", "lua", "insert", TABLE_COALITION_APPLY, apply)
        if ok then
            apply.id = applyId
        end
    end
end

-- 异步保存日志到数据库
local function saveLogAsync(logData)
    skynet.fork(function()
        if logData.id and logData.id > 0 then
            -- 更新（一般日志不需要更新）
            -- PUBLIC.saveDbData(TABLE_COALITION_LOG, "id", logData.id, logData, DB_SCHEMA_LOG)
        else
            -- 插入
            local ok, logId = skynet.call(".mysql", "lua", "insert", TABLE_COALITION_LOG, logData)
            if ok then
                logData.id = logId
            end
        end
    end)
end

-- 添加日志（同时更新内存缓存）
local function addLog(unionId, opRid, targetId, des, state)
    unionId = tonumber(unionId)
    local logData = {
        union_id = unionId,
        op_rid = opRid,
        target_id = targetId or 0,
        des = des or "",
        state = state,
        ctime = os.date('%Y-%m-%d %H:%M:%S'),
    }
    
    -- 添加到内存缓存
    if not ld.union_logs[unionId] then
        ld.union_logs[unionId] = {}
    end
    table.insert(ld.union_logs[unionId], logData)
    
    -- 限制日志数量（最多保留最近1000条）
    if #ld.union_logs[unionId] > 1000 then
        table.remove(ld.union_logs[unionId], 1)
    end
    
    -- 异步保存到数据库
    saveLogAsync(logData)
    
    return logData
end

-- 加载联盟数据（从数据库）
local function loadUnionFromDb(unionId)
    local ok, data = skynet.call(".mysql", "lua", "select_one_by_key", 
        TABLE_COALITION, "id", unionId)
    
    if not ok or not data then
        return nil
    end
    
    -- 解析成员列表
    data.members = parseMembers(data.members)
    
    -- 添加到缓存
    ld.unions[unionId] = data
    
    -- 初始化在线成员列表
    if not ld.union_online_members[unionId] then
        ld.union_online_members[unionId] = {}
    end
    
    return data
end

-- 获取联盟数据（智能加载）
local function getUnion(unionId)
    unionId = tonumber(unionId)
    if not unionId or unionId <= 0 then
        return nil
    end
    
    -- 先从缓存查找
    local union = ld.unions[unionId]
    if union then
        return union
    end
    
    -- 缓存中没有，从数据库加载（备用方案，正常情况下启动时已全部加载）
    return loadUnionFromDb(unionId)
end

-- 保存联盟数据到数据库
local function saveUnion(union)
    if not union or not union.id then
        return false
    end
    
    local saveData = {}
    for k, v in pairs(union) do
        if k ~= "members" then
            saveData[k] = v
        end
    end
    
    -- 序列化成员列表
    saveData.members = serializeMembers(union.members)
    
    return PUBLIC.saveDbData(TABLE_COALITION, "id", union.id, saveData, DB_SCHEMA_COALITION)
end

-- 取消卸载定时器
local function cancelUnloadTimer(unionId)
    local timerId = ld.unload_timers[unionId]
    if timerId then
        skynet.timeout(timerId, function() end)  -- 取消定时器
        ld.unload_timers[unionId] = nil
    end
end

-- 设置卸载定时器（5分钟后卸载）
local function setUnloadTimer(unionId)
    -- 先取消之前的定时器
    cancelUnloadTimer(unionId)
    
    -- 设置新定时器（5分钟 = 300秒 = 30000个skynet时间单位）
    local timerId = skynet.timeout(CONFIG.UNLOAD_DELAY * 100, function()
        -- 检查是否还有在线成员
        local onlineMembers = ld.union_online_members[unionId]
        if onlineMembers then
            local hasOnline = false
            for _ in pairs(onlineMembers) do
                hasOnline = true
                break
            end
            
            -- 如果没有在线成员，卸载联盟数据
            if not hasOnline then
                local union = ld.unions[unionId]
                if union then
                    -- 保存到数据库
                    saveUnion(union)
                    -- 从缓存移除
                    ld.unions[unionId] = nil
                    ld.union_online_members[unionId] = nil
                    print(string.format("联盟 %d 已卸载（所有成员离线）", unionId))
                end
            end
        end
        
        ld.unload_timers[unionId] = nil
    end)
    
    ld.unload_timers[unionId] = timerId
end

-- 更新玩家在线状态
local function updatePlayerOnline(rid, agent, unionId)
    ld.online_players[rid] = {
        agent = agent,
        union_id = unionId or 0,
    }
    
    if unionId and unionId > 0 then
        if not ld.union_online_members[unionId] then
            ld.union_online_members[unionId] = {}
        end
        ld.union_online_members[unionId][rid] = agent
        
        -- 取消卸载定时器（有成员上线）
        cancelUnloadTimer(unionId)
    end
end

-- 更新玩家离线状态
local function updatePlayerOffline(rid)
    local playerInfo = ld.online_players[rid]
    if playerInfo then
        local unionId = playerInfo.union_id
        if unionId and unionId > 0 then
            -- 从联盟在线成员列表移除
            local onlineMembers = ld.union_online_members[unionId]
            if onlineMembers then
                onlineMembers[rid] = nil
                
                -- 检查是否还有在线成员
                local hasOnline = false
                for _ in pairs(onlineMembers) do
                    hasOnline = true
                    break
                end
                
                -- 如果没有在线成员，设置卸载定时器
                if not hasOnline then
                    setUnloadTimer(unionId)
                end
            end
        end
        
        ld.online_players[rid] = nil
    end
end

-- 广播消息给联盟所有在线成员
local function broadcastToUnion(unionId, msg, excludeRid)
    excludeRid = excludeRid or 0
    local onlineMembers = ld.union_online_members[unionId]
    if not onlineMembers then
        return
    end
    
    for rid, agent in pairs(onlineMembers) do
        if rid ~= excludeRid then
            pcall(skynet.send, agent, "lua", "union_notify", msg)
        end
    end
end

-- 更新角色属性表中的联盟信息
-- local function updateRoleAttrUnion(rid, unionId, parentId)
--     parentId = parentId or 0
--     local ok, attr = skynet.call(".mysql", "lua", "select_one_by_key", 
--         TABLE_ROLE_ATTR, "rid", rid)
    
--     if ok and attr then
--         attr.union_id = unionId
--         attr.parent_id = parentId
--         PUBLIC.saveDbData(TABLE_ROLE_ATTR, "rid", rid, attr, {
--             rid = "int",
--             union_id = "int",
--             parent_id = "int",
--             collect_times = "int",
--             pos_tags = "json",
--             last_collect_time = "timestamp",
--         })
--     end
-- end

-- 创建联盟
function CMD.createUnion(rid, name)
    rid = tonumber(rid)
    name = tostring(name or "")
    
    if name == "" or #name > 20 then
        return error_code.UnionCreateError, "联盟名称无效"
    end
    
    -- 检查玩家是否已有联盟
    -- local ok, attr = skynet.call(".mysql", "lua", "select_one_by_key", 
    --     TABLE_ROLE_ATTR, "rid", rid)
    -- if ok and attr and attr.union_id and attr.union_id > 0 then
    --     return false, "已经有联盟了"
    -- end
    
    -- 这里需要优化一下，加载联盟的时候做个名字映射表，不要在数据库里面查TODO 2026年1月6日17:59:51
    -- 检查联盟名称是否已存在
    local ok, existing = skynet.call(".mysql", "lua", "select_one_by_conditions", 
        TABLE_COALITION, {name = name, state = 1})
    if ok and existing then
        return error_code.UnionCreateError, "联盟名称已存在"
    end
    
    -- 创建联盟
    local unionData = {
        name = name,
        members = serializeMembers({rid}),
        create_id = rid,
        chairman = rid,
        vice_chairman = 0,
        notice = "",
        state = 1,
        ctime = os.date('%Y-%m-%d %H:%M:%S'),
    }
    
    local ok, unionId = skynet.call(".mysql", "lua", "insert", TABLE_COALITION, unionData)
    if not ok then
        return error_code.UnionCreateError, "创建联盟失败"
    end
    
    unionData.id = unionId
    unionData.members = {rid}
    
    -- 添加到缓存
    ld.unions[unionId] = unionData
    if not ld.union_online_members[unionId] then
        ld.union_online_members[unionId] = {}
    end
    
    -- 更新角色属性
    -- updateRoleAttrUnion(rid, unionId, 0)
    
    -- 更新在线状态
    local playerInfo = ld.online_players[rid]
    if playerInfo then
        updatePlayerOnline(rid, playerInfo.agent, unionId)
    end
    
    -- 添加日志
    addLog(unionId, rid, 0, string.format("创建联盟 %s", name), LOG_STATE.CREATE)
    
    return error_code.success, unionData
end

-- 解散联盟
function CMD.dismissUnion(unionId, rid)
    unionId = tonumber(unionId)
    rid = tonumber(rid)
    
    local union = getUnion(unionId)
    if not union then
        return false, "联盟不存在"
    end
    
    if union.state ~= 1 then
        return false, "联盟已解散"
    end
    
    if not isChairman(union, rid) then
        return false, "只有盟主可以解散联盟"
    end
    
    -- 更新状态
    union.state = 0
    saveUnion(union)
    
    -- 更新所有成员的联盟信息
    for _, memberRid in ipairs(union.members) do
        -- updateRoleAttrUnion(memberRid, 0, 0)
        updatePlayerOffline(memberRid)
    end
    
    -- 添加日志
    addLog(unionId, rid, 0, "解散联盟", LOG_STATE.DISMISS)
    
    -- 广播通知
    broadcastToUnion(unionId, {
        type = "dismiss",
        union_id = unionId,
    })
    
    -- 从缓存移除
    ld.unions[unionId] = nil
    ld.union_online_members[unionId] = nil
    cancelUnloadTimer(unionId)
    
    return true
end

-- 申请加入联盟
function CMD.applyJoinUnion(unionId, rid ,nick_name)
    unionId = tonumber(unionId)
    rid = tonumber(rid)
    
    local union = getUnion(unionId)
    if not union then
        return error_code.UnionNotFound, "联盟不存在"
    end
    
    if union.state ~= 1 then
        return error_code.UnionNotFound, "联盟已解散"
    end
    
    -- 检查是否已有联盟
    -- local ok, attr = skynet.call(".mysql", "lua", "select_one_by_key", 
    --     TABLE_ROLE_ATTR, "rid", rid)
    -- if ok and attr and attr.union_id and attr.union_id > 0 then
    --     return false, "已经有联盟了"
    -- end
    
    -- 从内存缓存检查是否已经申请过
    local applies = ld.union_applies[unionId] or {}
    for _, apply in ipairs(applies) do
        if apply.rid == rid and apply.state == APPLY_STATE.PENDING then
            return  error_code.HasApply, "已经申请过了"
        end
    end
    
    -- 创建申请
    local applyData = {
        union_id = unionId,
        rid = rid,
        state = APPLY_STATE.PENDING,
        ctime = os.date('%Y-%m-%d %H:%M:%S'),
    }
    
    -- 添加到内存缓存
    if not ld.union_applies[unionId] then
        ld.union_applies[unionId] = {}
    end
    table.insert(ld.union_applies[unionId], applyData)
    
    -- 异步保存到数据库
    saveApplyAsync(applyData)
    
    -- 通知盟主和副盟主
    local onlineMembers = ld.union_online_members[unionId]
    if onlineMembers then
        local chairmanAgent = onlineMembers[union.chairman]
        if chairmanAgent then
            pcall(skynet.send, chairmanAgent, "lua", "union_notify", {
                type = "new_apply",
                union_id = unionId,
                nick_name = nick_name,
                apply = applyData,
            })
        end
        
        if union.vice_chairman > 0 then
            local viceAgent = onlineMembers[union.vice_chairman]
            if viceAgent then
                pcall(skynet.send, viceAgent, "lua", "union_notify", {
                    type = "new_apply",
                    union_id = unionId,
                    nick_name = nick_name,
                    apply = applyData,
                })
            end
        end
    end
    
    return  error_code.success, "申请加入联盟成功"
end

-- 审批通过
function CMD.approveApply(unionId, applyId, rid)
    unionId = tonumber(unionId)
    applyId = tonumber(applyId)
    rid = tonumber(rid)
    
    local union = getUnion(unionId)
    if not union then
        return false, "联盟不存在"
    end
    
    if not hasPermission(union, rid) then
        return false, "权限不足"
    end
    
    -- 从内存缓存查询申请
    local applies = ld.union_applies[unionId] or {}
    local apply = nil
    local applyIndex = 0
    for i, a in ipairs(applies) do
        if a.id == applyId then
            apply = a
            applyIndex = i
            break
        end
    end
    
    if not apply then
        return false, "申请不存在"
    end
    
    if apply.union_id ~= unionId then
        return false, "申请不属于该联盟"
    end
    
    if apply.state ~= APPLY_STATE.PENDING then
        return false, "申请已处理"
    end
    
    local applicantRid = apply.rid
    
    -- 检查是否已有联盟
    -- local ok, attr = skynet.call(".mysql", "lua", "select_one_by_key", 
    --     TABLE_ROLE_ATTR, "rid", applicantRid)
    -- if ok and attr and attr.union_id and attr.union_id > 0 then
    --     return false, "申请人已有联盟"
    -- end
    
    -- 检查联盟人数限制（假设最大100人）
    if #union.members >= 100 then
        return false, "联盟人数已满"
    end
    
    -- 更新申请状态（内存）
    apply.state = APPLY_STATE.ACCEPT
    
    -- 异步保存到数据库
    saveApplyAsync(apply)
    
    -- 添加成员
    addMemberToUnion(union.members, applicantRid)
    saveUnion(union)
    
    -- 更新角色属性
    -- updateRoleAttrUnion(applicantRid, unionId, 0)
    
    -- 更新在线状态
    local applicantInfo = ld.online_players[applicantRid]
    if applicantInfo then
        updatePlayerOnline(applicantRid, applicantInfo.agent, unionId)
    end
    
    -- 添加日志
    addLog(unionId, rid, applicantRid, "审批通过申请", LOG_STATE.APPOINT)
    
    -- 广播通知
    broadcastToUnion(unionId, {
        type = "member_join",
        union_id = unionId,
        rid = applicantRid,
    })
    
    return true
end

-- 审批拒绝
function CMD.rejectApply(unionId, applyId, rid)
    unionId = tonumber(unionId)
    applyId = tonumber(applyId)
    rid = tonumber(rid)
    
    local union = getUnion(unionId)
    if not union then
        return false, "联盟不存在"
    end
    
    if not hasPermission(union, rid) then
        return false, "权限不足"
    end
    
    -- 从内存缓存查询申请
    local applies = ld.union_applies[unionId] or {}
    local apply = nil
    for _, a in ipairs(applies) do
        if a.id == applyId then
            apply = a
            break
        end
    end
    
    if not apply then
        return false, "申请不存在"
    end
    
    if apply.union_id ~= unionId then
        return false, "申请不属于该联盟"
    end
    
    if apply.state ~= APPLY_STATE.PENDING then
        return false, "申请已处理"
    end
    
    -- 更新申请状态（内存）
    apply.state = APPLY_STATE.REJECT
    
    -- 异步保存到数据库
    saveApplyAsync(apply)
    
    -- 添加日志
    addLog(unionId, rid, apply.rid, "拒绝申请", LOG_STATE.APPOINT)
    
    return true
end

-- 踢人
function CMD.kickMember(unionId, targetRid, rid)
    unionId = tonumber(unionId)
    targetRid = tonumber(targetRid)
    rid = tonumber(rid)
    
    local union = getUnion(unionId)
    if not union then
        return false, "联盟不存在"
    end
    
    if not hasPermission(union, rid) then
        return false, "权限不足"
    end
    
    if targetRid == rid then
        return false, "不能踢自己"
    end
    
    if targetRid == union.chairman then
        return false, "不能踢盟主"
    end
    
    if not isMemberInUnion(union.members, targetRid) then
        return false, "成员不存在"
    end
    
    -- 移除成员
    removeMemberFromUnion(union.members, targetRid)
    
    -- 如果是副盟主，清除副盟主职位
    if union.vice_chairman == targetRid then
        union.vice_chairman = 0
    end
    
    saveUnion(union)
    
    -- 更新角色属性
    -- updateRoleAttrUnion(targetRid, 0, 0)
    
    -- 更新在线状态
    updatePlayerOffline(targetRid)
    
    -- 添加日志
    addLog(unionId, rid, targetRid, "踢出成员", LOG_STATE.KICK)
    
    -- 广播通知
    broadcastToUnion(unionId, {
        type = "member_kick",
        union_id = unionId,
        rid = targetRid,
    })
    
    return true
end

-- 任命副盟主
function CMD.appointViceChairman(unionId, targetRid, rid)
    unionId = tonumber(unionId)
    targetRid = tonumber(targetRid)
    rid = tonumber(rid)
    
    local union = getUnion(unionId)
    if not union then
        return false, "联盟不存在"
    end
    
    if not isChairman(union, rid) then
        return false, "只有盟主可以任命"
    end
    
    if not isMemberInUnion(union.members, targetRid) then
        return false, "成员不存在"
    end
    
    if targetRid == union.chairman then
        return false, "不能任命自己"
    end
    
    -- 设置副盟主
    union.vice_chairman = targetRid
    saveUnion(union)
    
    -- 添加日志
    addLog(unionId, rid, targetRid, "任命副盟主", LOG_STATE.APPOINT)
    
    -- 广播通知
    broadcastToUnion(unionId, {
        type = "appoint_vice",
        union_id = unionId,
        rid = targetRid,
    })
    
    return true
end

-- 取消副盟主
function CMD.cancelViceChairman(unionId, targetRid, rid)
    unionId = tonumber(unionId)
    targetRid = tonumber(targetRid)
    rid = tonumber(rid)
    
    local union = getUnion(unionId)
    if not union then
        return false, "联盟不存在"
    end
    
    if not isChairman(union, rid) then
        return false, "只有盟主可以取消任命"
    end
    
    if union.vice_chairman ~= targetRid then
        return false, "该成员不是副盟主"
    end
    
    -- 取消副盟主
    union.vice_chairman = 0
    saveUnion(union)
    
    -- 添加日志
    addLog(unionId, rid, targetRid, "取消副盟主", LOG_STATE.APPOINT)
    
    -- 广播通知
    broadcastToUnion(unionId, {
        type = "cancel_vice",
        union_id = unionId,
        rid = targetRid,
    })
    
    return true
end

-- 禅让盟主
function CMD.abdicateChairman(unionId, targetRid, rid)
    unionId = tonumber(unionId)
    targetRid = tonumber(targetRid)
    rid = tonumber(rid)
    
    local union = getUnion(unionId)
    if not union then
        return false, "联盟不存在"
    end
    
    if not isChairman(union, rid) then
        return false, "只有盟主可以禅让"
    end
    
    if targetRid == rid then
        return false, "不能禅让给自己"
    end
    
    if not isMemberInUnion(union.members, targetRid) then
        return false, "成员不存在"
    end
    
    -- 禅让：原盟主变为普通成员，新盟主上任
    local oldViceChairman = union.vice_chairman
    union.chairman = targetRid
    union.vice_chairman = 0  -- 清除副盟主
    
    saveUnion(union)
    
    -- 添加日志
    addLog(unionId, rid, targetRid, "禅让盟主", LOG_STATE.ABDICATE)
    
    -- 广播通知
    broadcastToUnion(unionId, {
        type = "abdicate",
        union_id = unionId,
        old_chairman = rid,
        new_chairman = targetRid,
    })
    
    return true
end

-- 根据联盟id查询成员
function CMD.getMembers(unionId)
    unionId = tonumber(unionId)
    
    local union = getUnion(unionId)
    if not union then
        return nil, "联盟不存在"
    end
    
    -- 查询成员详细信息（需要从角色表查询）
    local members = {}
    for _, memberRid in ipairs(union.members) do
        local ok, role = skynet.call(".mysql", "lua", "select_one_by_key", 
            "tb_role_1", "rid", memberRid)
        if ok and role then
            -- 查询主城坐标
            local cityOk, cities = skynet.call(".mysql", "lua", "select_by_key", 
                "tb_map_role_city_1", "rid", memberRid)
            local x, y = 0, 0
            if cityOk and cities and #cities > 0 then
                -- 查找主城
                for _, city in ipairs(cities) do
                    if city.is_main == 1 then
                        x = city.x or 0
                        y = city.y or 0
                        break
                    end
                end
                -- 如果没有主城，使用第一个城市
                if x == 0 and y == 0 and cities[1] then
                    x = cities[1].x or 0
                    y = cities[1].y or 0
                end
            end
            
            table.insert(members, {
                rid = memberRid,
                name = role.nick_name or "",
                title = getMemberTitle(union, memberRid),
                x = x,
                y = y,
            })
        end
    end
    
    return members
end

-- 根据联盟id查询日志（从内存缓存）
function CMD.getLogs(unionId, limit)
    unionId = tonumber(unionId)
    limit = tonumber(limit) or 50
    
    local logs = ld.union_logs[unionId] or {}
    
    -- 按时间倒序排序
    local sortedLogs = {}
    for _, log in ipairs(logs) do
        table.insert(sortedLogs, log)
    end
    
    table.sort(sortedLogs, function(a, b)
        if a.ctime and b.ctime then
            return a.ctime > b.ctime
        end
        return (a.id or 0) > (b.id or 0)
    end)
    
    -- 限制返回数量
    local result = {}
    for i = 1, math.min(limit, #sortedLogs) do
        table.insert(result, sortedLogs[i])
    end
    
    return result
end

-- 根据联盟id查询申请列表（从内存缓存）
function CMD.getApplies(unionId)
    unionId = tonumber(unionId)
    
    local applies = ld.union_applies[unionId] or {}
    local pendingApplies = {}
    
    -- 只返回待处理的申请
    for _, apply in ipairs(applies) do
        if apply.state == APPLY_STATE.PENDING then
            table.insert(pendingApplies, apply)
        end
    end
    
    -- 查询申请人信息
    for _, apply in ipairs(pendingApplies) do
        if not apply.nick_name then
            local name = skynet.call(".agent_manager", "lua", "query_role_info", apply.rid)
            apply.nick_name = name or ""
        end
    end
    
    return pendingApplies
end

-- 玩家上线
function CMD.playerOnline(rid, unionId, agent)
    rid = tonumber(rid)
    
    -- 查询玩家的联盟信息
    -- local ok, attr = skynet.call(".mysql", "lua", "select_one_by_key", 
    --     TABLE_ROLE_ATTR, "rid", rid)
    
    -- local unionId = 0
    -- if ok and attr and attr.union_id and attr.union_id > 0 then
    --     unionId = attr.union_id
        
        -- 加载联盟数据
        local union = getUnion(unionId)
        if union then
            -- 更新在线状态
            updatePlayerOnline(rid, agent, unionId)
            
            -- 如果是盟主或副盟主，返回申请列表
            local title = getMemberTitle(union, rid)
            if title == TITLE.CHAIRMAN or title == TITLE.VICE_CHAIRMAN then
                local applies = CMD.getApplies(unionId)
                return {
                    union = union,
                    applies = applies,
                    title = title,
                }
            end
            
            return {
                union = union,
                applies = {},
                title = title,
            }
        end
    -- end
    
    -- 更新在线状态（即使没有联盟）
    updatePlayerOnline(rid, agent, unionId)
    
    return {
        union = nil,
        applies = {},
        title = TITLE.MEMBER,
    }
end

-- 玩家离线
function CMD.playerOffline(rid)
    rid = tonumber(rid)
    updatePlayerOffline(rid)
    return true
end

-- 修改公告
function CMD.modNotice(unionId, rid, notice)
    unionId = tonumber(unionId)
    rid = tonumber(rid)
    notice = tostring(notice or "")
    
    if #notice > 256 then
        return false, "公告内容太长"
    end
    
    local union = getUnion(unionId)
    if not union then
        return false, "联盟不存在"
    end
    
    if not hasPermission(union, rid) then
        return false, "权限不足"
    end
    
    union.notice = notice
    saveUnion(union)
    
    -- 添加日志
    addLog(unionId, rid, 0, "修改公告", LOG_STATE.MOD_NOTICE)
    
    -- 广播通知
    broadcastToUnion(unionId, {
        type = "mod_notice",
        union_id = unionId,
        notice = notice,
    })
    
    return true
end

-- 退出联盟
function CMD.exitUnion(unionId, rid)
    unionId = tonumber(unionId)
    rid = tonumber(rid)
    
    local union = getUnion(unionId)
    if not union then
        return false, "联盟不存在"
    end
    
    if not isMemberInUnion(union.members, rid) then
        return false, "不是联盟成员"
    end
    
    if union.chairman == rid then
        return false, "盟主不能退出，请先禅让或解散联盟"
    end
    
    -- 移除成员
    removeMemberFromUnion(union.members, rid)
    
    -- 如果是副盟主，清除副盟主职位
    if union.vice_chairman == rid then
        union.vice_chairman = 0
    end
    
    saveUnion(union)
    
    -- 更新角色属性
    -- updateRoleAttrUnion(rid, 0, 0)
    
    -- 更新在线状态
    updatePlayerOffline(rid)
    
    -- 添加日志
    addLog(unionId, rid, 0, "退出联盟", LOG_STATE.EXIT)
    
    -- 广播通知
    broadcastToUnion(unionId, {
        type = "member_exit",
        union_id = unionId,
        rid = rid,
    })
    
    return true
end

-- 初始化服务：加载所有联盟数据、申请列表和日志
function CMD.load()
    print("union_manager: 开始加载所有联盟数据...")
    
    -- 查询所有运行中的联盟
    local ok, unions = skynet.call(".mysql", "lua", "select_by_conditions", 
        TABLE_COALITION, {state = 1})
    
    if not ok then
        print("union_manager: 加载联盟数据失败")
        return false
    end
    
    local loadedCount = 0
    local unionIds = {}
    if unions and #unions > 0 then
        for _, unionData in ipairs(unions) do
            -- 解析成员列表
            unionData.members = parseMembers(unionData.members)
            
            -- 添加到缓存
            ld.unions[unionData.id] = unionData
            table.insert(unionIds, unionData.id)
            
            -- 初始化在线成员列表
            if not ld.union_online_members[unionData.id] then
                ld.union_online_members[unionData.id] = {}
            end
            
            loadedCount = loadedCount + 1
        end
    end
    
    print(string.format("union_manager: 成功加载 %d 个联盟数据", loadedCount))
    
    -- 加载所有待处理的申请
    print("union_manager: 开始加载申请列表...")
    local ok, applies = skynet.call(".mysql", "lua", "select_by_conditions", 
        TABLE_COALITION_APPLY, {state = APPLY_STATE.PENDING})
    
    if ok and applies and #applies > 0 then
        for _, apply in ipairs(applies) do
            local unionId = apply.union_id
            if not ld.union_applies[unionId] then
                ld.union_applies[unionId] = {}
            end
            table.insert(ld.union_applies[unionId], apply)
        end
        print(string.format("union_manager: 成功加载 %d 条待处理申请", #applies))
    else
        print("union_manager: 没有待处理的申请")
    end
    
    -- 加载最近日志（每个联盟最多加载最近100条）
    print("union_manager: 开始加载日志...")
    local logCount = 0
    for _, unionId in ipairs(unionIds) do
        local ok, logs = skynet.call(".mysql", "lua", "select_by_conditions", 
            TABLE_COALITION_LOG, {union_id = unionId}, {ctime = "DESC" }, 1, 20)
        
        if ok and logs and #logs > 0 then
            -- 按时间正序排列（最早的在前，方便后续添加）
            table.sort(logs, function(a, b)
                if a.ctime and b.ctime then
                    return a.ctime < b.ctime
                end
                return (a.id or 0) < (b.id or 0)
            end)
            
            ld.union_logs[unionId] = logs
            logCount = logCount + #logs
        end
    end
    print(string.format("union_manager: 成功加载 %d 条日志", logCount))
    
    return true
end

-- 获取联盟列表
function CMD.getUnionList(page, pageSize, keyword)
    page = tonumber(page) or 1
    pageSize = tonumber(pageSize) or 20
    keyword = keyword and tostring(keyword) or ""
    
    if page < 1 then
        page = 1
    end
    if pageSize < 1 or pageSize > 100 then
        pageSize = 20
    end
    
    -- 从缓存获取所有联盟
    local allUnions = {}
    for unionId, union in pairs(ld.unions) do
        if union.state == 1 then  -- 只返回运行中的联盟
            -- 如果有关键词，进行过滤（支持名称模糊匹配）
            local match = true
            if keyword ~= "" then
                match = false
                if union.name and string.find(string.lower(union.name), string.lower(keyword)) then
                    match = true
                end
            end
            
            if match then
                -- 查询盟主信息
                -- local chairmanName = ""
                -- if union.chairman and union.chairman > 0 then
                --     local ok, role = skynet.call(".mysql", "lua", "select_one_by_key", 
                --         "tb_role_1", "rid", union.chairman)
                --     if ok and role then
                --         chairmanName = role.nick_name or ""
                --     end
                -- end
                local major = {}
                if union.chairman and union.chairman > 0 then
                    table.insert(major, {
                        rid = union.chairman,
                        name = skynet.call(".agent_manager", "lua", "query_role_info", union.chairman),
                        title = TITLE.CHAIRMAN,
                    })
                end
                if union.vice_chairman and union.vice_chairman > 0 then
                    table.insert(major, {
                        rid = union.vice_chairman,
                        name = skynet.call(".agent_manager", "lua", "query_role_info", union.vice_chairman),
                        title = TITLE.VICE_CHAIRMAN,
                    })
                end
                table.insert(allUnions, {
                    id = union.id,
                    name = union.name or "",
                    major = major,
                    cnt = #(union.members or {}),
                    notice = union.notice or "",
                    ctime = union.ctime or "",
                })
            end
        end
    end
    
    -- 按创建时间倒序排序（最新的在前）
    table.sort(allUnions, function(a, b)
        if a.ctime and b.ctime then
            return a.ctime > b.ctime
        end
        return a.id > b.id
    end)
    
    -- 分页
    local total = #allUnions
    local startIndex = (page - 1) * pageSize + 1
    local endIndex = math.min(startIndex + pageSize - 1, total)
    
    local result = {}
    for i = startIndex, endIndex do
        if allUnions[i] then
            table.insert(result, allUnions[i])
        end
    end
    
    return {
        list = result,
        total = total,
        page = page,
        pageSize = pageSize,
        totalPages = math.ceil(total / pageSize),
    }
end

-- 服务启动
skynet.init(function()
    CMD.load()
end)

-- 启动服务
base.start_service(".union_manager")

