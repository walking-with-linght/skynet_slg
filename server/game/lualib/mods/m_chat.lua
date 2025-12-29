

local skynet = require "skynet"
local base = require "base"
local error_code = require "error_code"
local event = require "event"
local sharedata = require "skynet.sharedata"
local sessionlib = require "session"
local protoid = require "protoid"
local utils = require "utils"

local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST

local NM = "chat"

local lf = base.LocalFunc(NM)
local ld = base.LocalData(NM)



function lf.load(self)
end
function lf.loaded(self)
end
function lf.enter(self, seq)
    for channel_name, channel_id in pairs(Chat_Type) do
        skynet.send(".chat_manager", "lua", "join_channel", self.rid, channel_id, skynet.self())
    end

end
function lf.leave(self)
    for channel_name, channel_id in pairs(Chat_Type) do
        skynet.call(".chat_manager", "lua", "leave_channel", self.rid, channel_name)
    end
end

skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
end)
function CMD.chat_callback(message)
    CMD.send2client({
        seq = MSG_TYPE.S2C,
        msg = message,
        name = protoid.chat_push,
        code = error_code.success,
    })
end


-- 退出聊天
REQUEST[protoid.chat_exit] = function(self,args)
end

-- 聊天
REQUEST[protoid.chat_chat] = function(self,args)
	local channel_id = args.msg.type
    local message = {
        msg = args.msg.msg,
        nickName = self.role.nickName,
        rid = self.rid,
        time = os.time(),
        type = channel_id,
    }
    local ok,err = skynet.call(".chat_manager", "lua", "send_message", self.rid, channel_id, message)
    print("send_message", ok, err)
end

-- 聊天历史
REQUEST[protoid.chat_history] = function(self,args)
	local channel_id = args.msg.type
	local his = skynet.call(".chat_manager", "lua", "get_history", channel_id)
    CMD.send2client({
        seq = args.seq,
        msg = his,
        name = protoid.chat_history,
        code = error_code.success,
    })
end