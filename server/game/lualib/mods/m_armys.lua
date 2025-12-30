
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
local ld = base.LocalData(NM,{
	db = {
		rid = "int",
		cityId = "int",--城市id
		order = "int",--第几队 1-5队
		generals = "json",--将领
		soldiers = "json",--士兵
		conscript_times = "json", --征兵结束时间
		conscript_cnts = "json", --征兵数量
		cmd = "int", -- 命令  0:空闲 1:攻击 2：驻军 3:返回
		from_x = "int", -- 来自x坐标
		from_y = "int", -- 来自y坐标
		to_x = "int",-- 去往x坐标
		to_y = "int", -- 去往y坐标
		start = "string", -- 出发时间
		['end'] = "string", -- 到达时间
	},
	table_name = "tb_army_1",
})
function lf.load(self)
    local armys,ok = PUBLIC.loadDbData(ld.table_name, "rid", self.rid, ld.db)
	assert(ok)
    self.armys = armys[1] or {}
end
function lf.loaded(self)

end
function lf.enter(self, seq)

end
function lf.leave(self)

end

function lf.save(self,m_name)
	-- PUBLIC.saveDbData(ld.table_name, "rid", self.rid, self.armys, ld.db)
end

skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
	event:register("save", lf.save)
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

