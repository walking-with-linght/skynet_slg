
-- 武将
local skynet = require "skynet"
local base = require "base"
local event = require "event"
local protoid = require "protoid"
local error_code = require "error_code"
local cjson = require "cjson"
local sharedata = require "skynet.sharedata"

local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST

local NM = "generals"

local lf = base.LocalFunc(NM)
local ld = base.LocalData(NM)

ld.id_map_cache = {}
function lf.load(self)
	local generals, ok = skynet.call(".general_manager", "lua", "getOrCreateByRId", self.rid)
	assert(ok)
	self.generals = generals
	for _, general in ipairs(self.generals) do
		ld.id_map_cache[general.id] = general
	end
	-- print(dump(self.generals))
end
function lf.loaded(self)

end
function lf.enter(self, seq)

end
function lf.leave(self)

end

function PUBLIC.getGeneralById(self, id)
	return ld.id_map_cache[id]
end


function PUBLIC.saveGeneral(self, id)
	local general = ld.id_map_cache[id]
	if not general then
		return
	end
	print("更新保存武将", id)
	local ok,msg = skynet.call(".general_manager", "lua", "batchUpdateGeneral", {general})
	print("更新保存武将", ok, msg)
end

function PUBLIC.saveGenerals(self, ids)
	if not ids or #ids == 0 then
		return
	end
	local generals = {}
	for _, id in ipairs(ids) do
		local general = ld.id_map_cache[id]
		if general then
			table.insert(generals, general)
		end
	end
	skynet.call(".general_manager", "lua", "batchUpdateGeneral", generals)
end

-- 推送将领信息
function PUBLIC.pushGeneral(self, gid)
	local general = ld.id_map_cache[gid]
	if not general then
		return
	end
	CMD.send2client({
		seq = MSG_TYPE.S2C,
		msg = general,
		name = protoid.general_push,
		code = error_code.success,
	})
end

skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
end)

-- 武将信息
REQUEST[protoid.general_myGenerals] = function(self,args)
	CMD.send2client({
		seq = args.seq,
		msg = {
			generals = self.generals,
		},
		name = protoid.general_myGenerals,
		code = error_code.success,
	})
end
-- 回收武将卡
REQUEST[protoid.general_convert] = function(self,args)
	local gIds = args.msg.gIds
	local ok_gIds = {}
	local all_add_gold = 0
	for _, gid in ipairs(gIds) do
		local general = ld.id_map_cache[gid]
		if general then
			local add_gold = 10 * general.star * (general.star_lv + 1)
			print("回收武将", gid, add_gold,general.star,general.star_lv)
			self.resource.gold = self.resource.gold + add_gold
			general.state = GeneralState.Convert
			table.insert(ok_gIds, gid)
			all_add_gold = all_add_gold + add_gold
		else
			print("没有找到武将", gid)
		end
	end
	PUBLIC.saveGenerals(self, ok_gIds)
	CMD.send2client({
		seq = args.seq,
		msg = {
			gIds = ok_gIds,
			gold = self.resource.gold,
			add_gold = all_add_gold,
		},
		name = protoid.general_convert,
		code = error_code.success,
	})
end

-- 抽卡 单抽
REQUEST[protoid.general_drawGeneral] = function(self,args)
	local drawTimes = args.msg.drawTimes
	if drawTimes <= 0 then
		return
	end
	local basic_config = sharedata.query("config/basic.lua")
	local cost = drawTimes * basic_config.general.draw_general_cost
	-- 判断金币是否足够
	if self.resource.gold < cost then
		CMD.send2client({
			seq = args.seq,
			name = protoid.general_drawGeneral,
			code = error_code.GoldNotEnough,
		})
		return
	end
	-- 武将数量限制
	if #self.generals >= basic_config.general.limit then
		CMD.send2client({
			seq = args.seq,
			name = protoid.general_drawGeneral,
			code = error_code.OutGeneralLimit,
		})
		return
	end
	self.resource.gold = self.resource.gold - cost

	local new_generals,ok = skynet.call(".general_manager", "lua", "randCreateGeneral", self.rid,drawTimes)
	if not ok then
		CMD.send2client({
			seq = args.seq,
			name = protoid.general_drawGeneral,
			code = error_code.DBError,
		})
		return
	end
	local new_ids = {}
	-- 添加到内存缓存
	for _, general in ipairs(new_generals) do
		table.insert(self.generals, general)
		ld.id_map_cache[general.id] = general
		table.insert(new_ids, general.id)
	end
	PUBLIC.saveGenerals(self, new_ids)
	CMD.send2client({
		seq = args.seq,
		msg = {
			generals = new_generals,
		},
		name = protoid.general_drawGeneral,
		code = error_code.success,
	})
end