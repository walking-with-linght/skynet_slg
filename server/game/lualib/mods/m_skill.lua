
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

local NM = "skill"

local lf = base.LocalFunc(NM)

function lf.load(self)
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

-- 技能列表
REQUEST[protoid.skill_list] = function(self,args)
	CMD.send2client({
		seq = args.seq,
		msg = {
			list = {
				{
					cfgId = 301,
					generals = {},
					id = 1,
				},
				{
					cfgId = 201,
					generals = {},
					id = 2,
				},
				{
					cfgId = 101,
					generals = {},
					id = 3,
				},
			},
		},
		name = protoid.skill_list,
		code = error_code.success,
	})
end


