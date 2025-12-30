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
local CMD=base.CMD
local PUBLIC=base.PUBLIC
local DATA=base.DATA
local REQUEST=base.REQUEST

local function send2client(gate_link, data)
    CMD.cluster_send(gate_link.node, gate_link.addr, "send2client", gate_link.client,data)
end

local function on_login(uid,ip,hardware,session)
    -- 写日志，tb_login_last tb_login_history
    -- 但用户只有一条
    skynet.send(".mysql", "lua", "execute", 
        string.format("insert into tb_login_last(uid,login_time,ip,is_logout,hardware,session) value (%d, '%s', '%s', %d, '%s', '%s') on duplicate key update login_time = '%s', ip = '%s', is_logout = %d, hardware = '%s',session = '%s' ;",
            uid,
            os.date('%Y-%m-%d %H:%M:%S'),
            ip,
            0, -- 0=登录 1=登出
            hardware,
            session,
            os.date('%Y-%m-%d %H:%M:%S'),
            ip,
            0, -- 0=登录 1=登出
            hardware,
            session
        )
    )
    skynet.send(".mysql", "lua", "insert", "tb_login_history", {
        uid = uid,
        ctime = os.date('%Y-%m-%d %H:%M:%S'),
        ip = ip,
        state = 0, -- 0=登录 1=登出
        hardware = hardware,
    })
    
end

-- 重登
REQUEST["account.reLogin"] = function(data, gate_link)
    print("account.relogin", dump(data))
    local session = data.msg.session
    local hardware = data.msg.hardware
    local code ,uid = sessionlib.check_session(session)
    if code ~= error_code.success then
        send2client(gate_link, {
            name = "account.reLogin",
            seq = data.seq,
            code = code,
        })
        return
    end
    -- 从数据库中查询用户信息
    local ok,last_login = skynet.call(".mysql", "lua", "select_one_by_key", "tb_login_last", "uid", uid)
    if not ok then
        send2client(gate_link, {
            name = "account.reLogin",
            seq = data.seq,
            code = error_code.DBError,
        })
        return
    end
    if not last_login or last_login.hardware ~=  hardware then
        send2client(gate_link, {
            name = "account.reLogin",
            seq = data.seq,
            code = error_code.HardwareIncorrect,
        })
        return
    end
    send2client(gate_link, {
        name = "account.reLogin",
        msg = {
            session = session,
        },
        seq = data.seq,
        code = error_code.success,
    })
    on_login(uid, last_login.ip, last_login.hardware, session)
    CMD.cluster_send(gate_link.node, gate_link.addr, "update_login_state", gate_link.client, {username = username,uid = uid} , true)
end
-- 登录
REQUEST["account.login"] = function(data, gate_link)
    print("account.login", dump(data))
    -- 验证用户名和密码
    local username = data.msg.username
    local password = data.msg.password
    local ip = data.msg.ip
    local hardware = data.msg.hardware


    local ok,account = skynet.call(".mysql", "lua", "select_one_by_key", "tb_user_info", "username", username)
    if not ok then
        send2client(gate_link, {
            name = "account.login",
            seq = data.seq,
            code = error_code.DBError,
        })
        return
    end
    --- 拿到 uid
    if not account or not account.uid then
        send2client(gate_link, {
            name = "account.login",
            seq = data.seq,
            code = error_code.account_not_exists,
        })
        return
    end
    
    local passwd = account.passwd
    if passwd ~= basefunc.md5(password, account.passcode) then
        send2client(gate_link, {
            name = "account.login",
            -- msg = {
            --     password = "",
            --     session = "",
            --     uid = "",
            --     username = "",
            -- },
            seq = data.seq,
            code = error_code.password_incorrect,
        })
        return
    end
    local ok,session = sessionlib.generate_session(account.uid)
    if not ok then
        elog(account.uid, session)
        return
    end
    print(session,"session")
    send2client(gate_link, {
        name = "account.login",
        msg = {
            password = account.password,
            session = session,
            uid = account.uid,
            username = account.username,
        },
        seq = data.seq,
        code = error_code.success,
    })
    on_login(account.uid, ip, hardware, session)
    CMD.cluster_send(gate_link.node, gate_link.addr, "update_login_state", gate_link.client, {username = username,uid = account.uid} , true)
end

function CMD.client_request(data, gate_link)
    print("dispatch_request", data.name, data.msg, data.seq)
    local f = REQUEST[data.name]
    if f then
        local ok, ret = pcall(f, data,gate_link)
        if not ok then
            elog("error", data.name, ret)
        end
    else
        elog("command not found", data.name)
    end
end

-- local function init()
--     local ok,ret = skynet.call(".mysql", "lua", "execute", "SELECT MAX(uid) FROM tb_user_info;SELECT MAX(rid) FROM tb_role_1;")
--     if ok then
--         print(dump(ret))
--         local uid_max = ret[1][1]["MAX(uid)"]
--         local rid_max = ret[2][1]["MAX(rid)"]
--         -- print("uid_max",uid_max)
--         -- print("rid_max",rid_max)
--         skynet.call(".redis", "lua", "set", "uid_seq", uid_max)
--         skynet.call(".redis", "lua", "set", "rid_seq", rid_max)
--     end
-- end

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
--     skynet.register(".login_manager")
-- end)
base.start_service(".login_manager")