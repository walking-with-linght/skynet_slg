
-- 资源
local skynet = require "skynet"
local base = require "base"
local event = require "event"
local sharedata = require "skynet.sharedata"
local cjson = require "cjson"
local protoid = require "protoid"
local error_code = require "error_code"
local utils = require "utils"

local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST

local NM = "resource"

local lf = base.LocalFunc(NM)
local ld = base.LocalData(NM,{
	db = {
		rid = "int",
		wood = "int",
		iron = "int",
		stone = "int",
		grain = "int",
		gold = "int",
		decree = "int",
	},
	table_name = "tb_role_res_1",
})

function lf.load(self)
    local resource,ok =  PUBLIC.loadDbData(ld.table_name, "rid", self.rid, ld.db)
    if not resource[1] or not next(resource[1]) then
		-- 刚创建的，初始化一下
		local role_res_config = sharedata.query("config/basic.lua")
		print("默认配置",dump(role_res_config))
		resource = {
			decree = role_res_config.role.decree,	-- 令牌
			gold = role_res_config.role.gold,		-- 金币
			grain = role_res_config.role.grain,		-- 粮食
			iron = role_res_config.role.iron,		-- 铁矿
			stone = role_res_config.role.stone,		-- 石矿
			wood = role_res_config.role.wood,		-- 木头
			rid = self.rid
		}
		-- local ok = skynet.call(".mysql", "lua", "insert", "tb_role_res_1", resource)
		-- assert(ok)
		self.resource = resource
	else
		self.resource = resource[1]
	end
	
	
end
function lf.loaded(self)

end
function lf.enter(self, seq)

end
function lf.leave(self)

end

function lf.save(self,m_name)
	if m_name  == NM then
		PUBLIC.saveDbData(ld.table_name, "rid", self.rid, self.resource, ld.db)
	end
end

skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
	event:register("save", lf.save)
end)


function PUBLIC.updateRoleRes(self, res_map)
	for k,v in pairs(res_map or {}) do
		self.resource[k] = v
	end
	lf.save(self, NM)
end



-- 更新客户端
function PUBLIC.updateClientRoleRes(self)
	CMD.send2client({
		seq = 0,
		msg = self.resource,
		name = protoid.role_res,
		code = error_code.success,
	})
end
-- 修改资源
function PUBLIC.modifyRoleRes(self, res_map)
	for k,v in pairs(res_map or {}) do
		self.resource[k] = self.resource[k] + v
	end
	lf.save(self, NM)
end


-- 批量扣除资源，比如全部满足才扣除
function PUBLIC.batchDeductRoleRes(self, res_map)
	local all_enough = true
	for k,v in pairs(res_map or {}) do
		if self.resource[k] < v then
			all_enough = false
			break
		end
	end
	if all_enough then
		for k,v in pairs(res_map or {}) do
			self.resource[k] = self.resource[k] - v
		end
		lf.save(self, NM)
		return true
	else
		return false
	end
	return false
end


-- 征收资源进度
REQUEST[protoid.interior_openCollect] = function(self,args)
	local role_res_config = sharedata.query("config/basic.lua")
	local cur_times = 0
	local limit = role_res_config.role.collect_times_limit
	local next_time = os.time()*1000
	-- 是否跨天
	if utils.isCrossDay(self.attr.last_collect_time) then

	else
		cur_times = self.attr.collect_times
		limit = role_res_config.role.collect_times_limit

		if cur_times >= limit then
			next_time = (utils.getToday0Timestamp() + 24*3600 ) *1000 
		else
			next_time =utils.date2timestamp(self.attr.last_collect_time)*1000 + role_res_config.role.collect_interval
		end
		
	end
	CMD.send2client({
		seq = args.seq,
		msg = {
			cur_times = cur_times,
			limit = limit,
			next_time = next_time,
		},
		name = protoid.interior_openCollect,
		code = error_code.success,
	})

end
-- 征收资源
REQUEST[protoid.interior_collect] = function(self,args)
	local role_res_config = sharedata.query("config/basic.lua")
	local cur_collect_times = 0
	-- 是否跨天
	if utils.isCrossDay(self.attr.last_collect_time) then
		cur_collect_times = 1
	else
		-- 未跨天，判断是否超出次数
		if self.attr.collect_times >= role_res_config.role.collect_times_limit then
			return CMD.send2client({
				seq = args.seq,
				code = error_code.OutCollectTimesLimit,
				name = protoid.interior_collect,
			})
		end
		cur_collect_times = self.attr.collect_times + 1
	end
	local add_gold = role_res_config.role.gold_yield
	self.resource.gold = self.resource.gold + add_gold
	self.resource.collect_times = cur_collect_times
	self.attr.last_collect_time = os.date("%Y-%m-%d %H:%M:%S")
	PUBLIC.updateRoleRes(self, {
		gold = add_gold,
	})
	PUBLIC.updateRoleAttr(self, {
		collect_times = cur_collect_times,
		last_collect_time = self.attr.last_collect_time,
	})
	-- 更新征收次数
	skynet.call(".mysql", "lua", "update", "tb_role_attribute_1",  "rid", self.rid, {
		last_collect_time = self.attr.last_collect_time,
	})
	local next_time = os.time()*1000 + role_res_config.role.collect_interval
	if cur_collect_times >= role_res_config.role.collect_times_limit then
		next_time = (utils.getToday0Timestamp() + 24*3600 ) *1000 
	end
	CMD.send2client({
		seq = args.seq,
		msg = {
			limit = role_res_config.role.collect_times_limit,
			cur_times = cur_collect_times,
			gold = add_gold,
			next_time = next_time,
		},
		name = protoid.interior_collect,
		code = error_code.success,
	})
end