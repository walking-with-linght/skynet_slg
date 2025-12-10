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
    skynet.register(".agent_manager")
end)
