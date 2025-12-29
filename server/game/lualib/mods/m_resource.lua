
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

function lf.load(self)
    local ok,role_res =  skynet.call(".mysql", "lua", "select_one_by_key", "tb_role_res_1", "rid", self.rid)
    
    if not role_res then
		-- 刚创建的，初始化一下
		local role_res_config = sharedata.query("config/basic.lua")
		print("默认配置",dump(role_res_config))
		role_res = {
			decree = role_res_config.role.decree,	-- 令牌
			gold = role_res_config.role.gold,		-- 金币
			grain = role_res_config.role.grain,		-- 粮食
			iron = role_res_config.role.iron,		-- 铁矿
			stone = role_res_config.role.stone,		-- 石矿
			wood = role_res_config.role.wood,		-- 木头
			rid = self.rid
		}
		local ok = skynet.call(".mysql", "lua", "insert", "tb_role_res_1", role_res)
		assert(ok)
        self.role_res = role_res
	else
		self.role_res = role_res
	end
	local ok,role_attr =  skynet.call(".mysql", "lua", "select_one_by_key", "tb_role_attribute_1", "rid", self.rid)
	-- 角色属性表
	if not role_attr then
		role_attr = {
			rid = self.rid,
			parent_id = 0,
			collect_times = 0,
			pos_tags = cjson.encode({}),
		}
		local ok = skynet.call(".mysql", "lua", "insert", "tb_role_attribute_1", role_attr)
		role_attr.rid = nil
		self.role_attr = role_attr
	else
		if role_attr.pos_tags then
			role_attr.pos_tags = cjson.decode(role_attr.pos_tags)
		else
			role_attr.pos_tags = {}
		end
		self.role_attr = role_attr
	end
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


function PUBLIC.updateRoleRes(self, res_map)
	for k,v in pairs(res_map) do
		self.role_res[k] = v
	end
	PUBLIC.saveRoleRes(self)
end

function PUBLIC.updateRoleAttr(self, attr_map)
	for k,v in pairs(attr_map) do
		self.role_attr[k] = v
	end
	skynet.call(".mysql", "lua", "update", "tb_role_attribute_1",  "rid", self.rid, attr_map)
end

-- 更新客户端
function PUBLIC.updateClientRoleRes(self)
	CMD.send2client({
		seq = 0,
		msg = self.role_res,
		name = protoid.role_res,
		code = error_code.success,
	})
end
-- 修改资源
function PUBLIC.modifyRoleRes(self, res_map)
	for k,v in pairs(res_map) do
		self.role_res[k] = self.role_res[k] + v
	end
	PUBLIC.saveRoleRes(self)
end
-- 保存资源
function PUBLIC.saveRoleRes(self)
	local save_data = {
		wood = self.role_res.wood,
		iron = self.role_res.iron,
		stone = self.role_res.stone,
		grain = self.role_res.grain,
		gold = self.role_res.gold,
		decree = self.role_res.decree,
	}
	skynet.call(".mysql", "lua", "update", "tb_role_res_1",  "rid", self.rid, save_data)
end

-- 征收资源进度
REQUEST[protoid.interior_openCollect] = function(self,args)
	local role_res_config = sharedata.query("config/basic.lua")
	local cur_times = 0
	local limit = role_res_config.role.collect_times_limit
	local next_time = os.time()*1000
	-- 是否跨天
	if utils.isCrossDay(self.role_attr.last_collect_time) then

	else
		cur_times = self.role_attr.collect_times
		limit = role_res_config.role.collect_times_limit

		if cur_times >= limit then
			next_time = (utils.getToday0Timestamp() + 24*3600 ) *1000 
		else
			next_time =utils.date2timestamp(self.role_attr.last_collect_time)*1000 + role_res_config.role.collect_interval
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
	if utils.isCrossDay(self.role_attr.last_collect_time) then
		cur_collect_times = 1
	else
		-- 未跨天，判断是否超出次数
		if self.role_attr.collect_times >= role_res_config.role.collect_times_limit then
			return CMD.send2client({
				seq = args.seq,
				code = error_code.OutCollectTimesLimit,
				name = protoid.interior_collect,
			})
		end
		cur_collect_times = self.role_attr.collect_times + 1
	end
	local add_gold = role_res_config.role.gold_yield
	self.role_res.gold = self.role_res.gold + add_gold
	self.role_res.collect_times = cur_collect_times
	self.role_attr.last_collect_time = os.date("%Y-%m-%d %H:%M:%S")
	PUBLIC.updateRoleRes(self, {
		gold = add_gold,
	})
	PUBLIC.updateRoleAttr(self, {
		collect_times = cur_collect_times,
		last_collect_time = self.role_attr.last_collect_time,
	})
	-- 更新征收次数
	skynet.call(".mysql", "lua", "update", "tb_role_attribute_1",  "rid", self.rid, {
		last_collect_time = self.role_attr.last_collect_time,
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