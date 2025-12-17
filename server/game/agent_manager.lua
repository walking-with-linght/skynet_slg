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
require "skynet.manager"
local sessionlib = require "session"
local error_code = require "error_code"

require "agent_helper"

local CMD=base.CMD
local PUBLIC=base.PUBLIC
local DATA=base.DATA
local REQUEST=base.REQUEST

local ROLES = {}

local ld = base.LocalData("agent_manager")
local lf = base.LocalFunc("agent_manager")

ld.wait_login = {}
ld.online_uid = {}
ld.online_rid = {}
ld.online_cnt = 0


local function send2client(gate_link, data)
    CMD.cluster_send(gate_link.node, gate_link.addr, "send2client", gate_link.client,data)
end
-- 创建角色
REQUEST["role.create"] = function(data, gate_link)
    print("role.create", data.msg, data.seq)
    --[[
    data.msg = {
        headId = 0,
        nickName = "仲翼衣",
        sex = 0,
        sid = 0,
        uid = 9,
    }
    ]]
    -- 创建角色
    local nickName = data.msg.nickName
    local sid = data.msg.sid
    local uid = data.msg.uid
    local headId = data.msg.headId
    local sex = data.msg.sex

    -- 查一下有没有角色，没有再新建
    local ok,role = skynet.call(".mysql", "lua", "select_one_by_key", "tb_role_1", "uid" , uid)
    if not ok then
        send2client(gate_link, {
            name = "role.create",
            seq = data.seq,
            code = error_code.DBError,
        })
        return
    end
    if role and role.rid then
        send2client(gate_link, {
            name = "role.create",
            -- msg = {
            -- },
            seq = data.seq,
            code = error_code.RoleAlreadyCreate,
        })
        return
    end
    -- 创建新角色
    local role = {
        uid = uid,
        headId = headId,
        sex = sex,
        nick_name = nickName,
        balance = 0,
        login_time = nil,
        created_at = os.date('%Y-%m-%d %H:%M:%S'),
        profile = ""
    }
    local ok,rid = skynet.call(".mysql", "lua", "insert", "tb_role_1", role)
    role.rid = rid
    send2client(gate_link, {
        name = "role.create",
        msg = {
            role = role
        },
        seq = data.seq,
        code = error_code.success,
    })
end
-- 进入游戏
REQUEST["role.enterServer"] = function(data, gate_link)
    print("role.create", dump(data))
    local session = data.msg.session
    local code ,uid = sessionlib.check_session(session)
    if code ~= error_code.success then
        send2client(gate_link, {
            name = "role.enterServer",
            msg = {
                -- session = "",
            },
            seq = data.seq,
            code = code,
        })
        return
    end
    
    -- 这里可以分配 agent 服务了
    -- 查找角色
    local ok, role = skynet.call(".mysql", "lua", "select_one_by_key", "tb_role_1", "uid" , uid)
    if not ok then
        send2client(gate_link, {
            name = "role.enterServer",
            seq = data.seq,
            code = error_code.DBError,
        })
        return
    end
    if not role or not role.rid then
        send2client(gate_link, {
            name = "role.enterServer",
            seq = data.seq,
            code = error_code.RoleNotExist,
        })
        return
    end
    local agent = lf.agent_load(role.rid )
    ROLES[role.rid ] = {
        agent  = agent,
        rid = role.rid ,
        uid = uid,
    }
    local ok, uinfo = skynet.call(agent, "lua", "enter", { rid = role.rid , uid = uid ,seq = data.seq}, gate_link)
    if not ok then
        ROLES[role.rid ] = nil
        send2client(gate_link, {
            name = "role.enterServer",
            seq = data.seq,
            code = error_code.DBError,
        })
        return
    end
    ld.wait_login[uid] = nil
    ld.online_uid[uid] = agent
    ld.online_rid[role.rid ] = agent
    ld.online_cnt = ld.online_cnt + 1
end

function CMD.client_request(data, gate_link)
    print("client_request", data.name, data.msg, data.seq)
    local f = REQUEST[data.name]
    if f then
        local ok, ret = pcall(f, data, gate_link)
        if not ok then
            elog("error", data.name, ret)
        end
    else
        elog("command not found", data.name)
    end
end

-----------------

--玩家登录
-- function CMD.role_login(args)
--     local rid = args.rid
--     if not rid then
--         return error_code.login_no_role
--     end

--     local role = rolehelp.select(rid)
--     if not role then
--         return errcode.login_not_find_role
--     end

--     local agent = lf.query_agent(rid, args)
--     ROLES[rid] = role
--     role.agent = agent
--     local ok, uinfo = skynet.call(agent, "lua", "enter", args)
--     if not ok then
--         ROLES[rid] = nil
--         return errcode.login_enter_err
--     end
--     return errcode.success, uinfo, agent
-- end

--玩家下线
function CMD.close(role)
    local rid, fd = role.rid, role.fd
    local self = ROLES[rid]
    if self and self.agent then
        skynet.send(self.agent, "lua", "afk", fd)
        ROLES[rid] = nil
        ld.online_uid[self.uid] = nil
        ld.online_rid[self.rid] = nil
    end
end



-- auth成功后从gate调用
-- function CMD.login(pid, gate_link)
--     rlog("gate请求创建agent",pid,sdump(gate_link))
--     if ld.wait_login[pid] then
--         log.warn("玩家重复登录",pid)
--         -- return
--     end
--     ld.wait_login[pid] = {
--         gate_link = gate_link,
--     }
--     local pack = skynet.call(".roled","lua","pack_pid_base",pid,true)
--     return pack
-- end

-- function lf.c2s_create_role(pid,args)
--     local prof = args.prof
--     log.debug("创建角色",pid,prof)
--     if not Role_Prof[prof] then
--         return {result = error_code.prof_not_found}
--     end
--     local error, pack = skynet.call(".roled","lua","create_role",pid,prof)
--     return {result = error, roles = pack}
-- end


--TODO 长时间在选择角色列表场景，应踢掉

--选择并进入游戏
-- function lf.c2s_select_role(pid,args)
--     local rid = args.rid
--     log.debug("选择角色进入游戏",pid,rid)
--     local role = skynet.call(".roled","lua","query_role", pid, rid)
--     if role and role.rid then
--         role.pid = pid
--         rlog("开始查找agent",pid,rid)
--         local ref <close> = lf.query_agent(rid,role)
--         rlog("agent查找成功",ref.addr)
--         local agent = ref.addr
--         local gate_link =  ld.wait_login[pid].gate_link
--         ld.wait_login[pid] = nil
--         ld.online_uid[pid] = agent
--         ld.online_rid[rid] = agent
--         ld.online_cnt = ld.online_cnt + 1
--         skynet.send(agent,"lua","enter",rid, gate_link)

--         return {result = error_code.success }
--     else
--         return {result = error_code.role_not_found}
--     end
-- end

-- function CMD.send2client(rid,cmd,data)
--     if ld.wait_login[rid] then
--         local gate_link = ld.wait_login[pid].gate_link
--         CMD.cluster_send(gate_link.node, gate_link.addr, "send2client", gate_link.client, cmd,data)
--     end
-- end

function CMD.disconnect( rid)
    rlog("disconnect", rid)

    local role = ROLES[rid]
    if not rid or not role then
        elog("玩家离线 啥玩意儿，没传 rid 啊",rid)
    end
    local agent = role.agent
    ld.online_uid[role.uid] = nil
    ld.online_rid[role.rid] = nil

    if agent then
        -- rlog("玩家断开连接",pid,rid)
        skynet.send(agent,"lua","disconnect")
        ld.online_cnt = ld.online_cnt - 1
    else
        -- log.warn("玩家断开连接",pid,rid)
    end
end

-- 服务主入口
-- skynet.start(function()
--     skynet.dispatch("lua", function(session, _, cmd, ...)
--         local f = CMD[cmd]
--         if not f then
--             skynet.ret(skynet.pack(nil, "command not found"))
--             return
--         end
        
--         local ok, ret,ret2,ret3,ret4 = pcall(f, ...)
--         if not ok then
--             rlog("error",ret)
--         end
--         if session ~= 0 then
--             if ok  then
--                 skynet.retpack(ret,ret2,ret3,ret4)
--             else
--                 skynet.ret(skynet.pack(nil, ret))
--             end
--         end
--     end)
--     skynet.register(".agent_manager")
-- end)
base.start_service(".agent_manager")