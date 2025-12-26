
-- 军队
local skynet = require "skynet"
local base = require "base"
local event = require "event"
local protoid = require "protoid"
local error_code = require "error_code"


local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST

local NM = "armys"

local lf = base.LocalFunc(NM)

function lf.load(self)
    local ok,armys = skynet.call(".mysql", "lua", "select_one_by_key", "tb_army_1", "rid", self.rid)
    self.armys = armys or {}
end
function lf.loaded(self)

end
function lf.enter(self, seq)

end
function lf.leave(self)

end

skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
end)

-- 武将信息
REQUEST[protoid.army_myList] = function(self,args)
	local cityId = self.main_cityId
	CMD.send2client({
		seq = args.seq,
		msg = {
			armys = self.armys,
			cityId = cityId,
		},
		name = protoid.army_myList,
		code = error_code.success,
	})
end

-- 战报
REQUEST[protoid.war_report] = function(self,args)

	-- 这里从tb_war_report_1表中查询
	CMD.send2client({
		seq = args.seq,
		msg = {
			list = {},
		},
		name = protoid.war_report,
		code = error_code.success,
	})
end

