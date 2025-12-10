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
local msgpack = require "msgpack"
local CMD=base.CMD
local PUBLIC=base.PUBLIC
local DATA=base.DATA
local REQUEST=base.REQUEST

local function send2client(gate, data)
    CMD.cluster_send(gate.node, gate.addr, "send2client", gate.client,data)
end
-- 创建角色
REQUEST["role.create"] = function(data, gate)
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
    local role_name = data.msg.role_name
    local role_data = {
        name = role_name,
    }
end

-- 登录
REQUEST["account.login"] = function(data, gate)
    print("account.login", data.msg, data.seq)
    -- 验证用户名和密码
    local username = data.msg.username
    local password = data.msg.password
    local ip = data.msg.ip
    local hardware = data.msg.hardware

    local redis_key = string.format("account:%s", username)
    local user_data = skynet.call(".redis", "lua", "hget", redis_key, "user_data")
    if not user_data then
        send2client(gate, {
            name = "account.login",
            msg = {
                password = "",
                session = "",
                uid = "",
                username = "",
            },
            seq = data.seq,
            code = error_code.account_not_exists,
        })
        return
    end
    user_data = msgpack.unpack(user_data)
    local passwd = user_data.passwd
    if passwd ~= basefunc.md5(password, user_data.passcode) then
        send2client(gate, {
            name = "account.login",
            msg = {
                password = "",
                session = "",
                uid = "",
                username = "",
            },
            seq = data.seq,
            code = error_code.password_incorrect,
        })
        return
    end
    local ok,session = sessionlib.generate_session(user_data.uid)
    if not ok then
        elog(user_data.uid,session)
        return
    end
    print(session,"session")
    skynet.call(".redis", "lua", "hset", redis_key, "session", session)
    send2client(gate, {
        name = "account.login",
        msg = {
            password = user_data.passwd,
            session = session,
            uid = user_data.uid,
            username = user_data.username,
        },
        seq = data.seq,
        code = error_code.success,
    })
    -- 写日志，tb_login_last tb_login_history
end

function CMD.dispatch_request(data, gate)
    print("dispatch_request", data.name, data.msg, data.seq)
    local f = REQUEST[data.name]
    if f then
        local ok, ret = pcall(f, data,gate)
        if not ok then
            elog("error", data.name, ret)
        end
    else
        print("command not found", data.name)
    end
end

-- 服务主入口
skynet.start(function()
    skynet.dispatch("lua", function(session, _, cmd, ...)
        local f = CMD[cmd]
        if not f then
            skynet.ret(skynet.pack(nil, "command not found"))
            return
        end
        
        local ok, ret,ret2,ret3,ret4 = pcall(f, ...)
        if not ok then
            rlog("error",ret)
        end
        if session ~= 0 then
            if ok  then
                skynet.retpack(ret,ret2,ret3,ret4)
            else
                skynet.ret(skynet.pack(nil, ret))
            end
        end
    end)
    skynet.register(".login_manager")
end)
