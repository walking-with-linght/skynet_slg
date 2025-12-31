
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
local ld = base.LocalData(NM, {
	-- db 字段定义表
	db = {
		id = "int",
		rid = "int",
		cfgId = "int",
		physical_power = "int",
		exp = "int",
		order = "int",
		level = "int",
		cityId = "int",
		star = "int",
		star_lv = "int",
		arms = "int",
		has_pr_point = "int",
		use_pr_point = "int",
		attack_distance = "int",
		force_added = "int",
		strategy_added = "int",
		defense_added = "int",
		speed_added = "int",
		destroy_added = "int",
		parentId = "int",
		compose_type = "int",
		skills = "json",
		state = "int",
		created_at = "timestamp",
	},
	table_name = "tb_general_1",
	id_map_cache = {},
})

function lf.load(self)
	-- 从数据库加载该玩家的所有武将（只加载正常状态的）
	local generals_data, ok = PUBLIC.loadDbData(ld.table_name, "rid", self.rid, ld.db)
	if not ok or not generals_data then
		generals_data = {}
	end
	
	-- 过滤出正常状态的武将，并处理 skills JSON 字段
	self.generals = {}
	ld.id_map_cache = {}
	
	for _, general in ipairs(generals_data) do
		-- skills 字段已经在 loadDbData 中自动解码为 table
		if general.state == GeneralState.Normal then
			-- 客户端要的字段，跟服务器字段不一致，烦死了
			general.curArms = general.arms
			general.hasPrPoint = general.has_pr_point
			general.usePrPoint = general.use_pr_point

			table.insert(self.generals, general)
			ld.id_map_cache[general.id] = general
		end
	end
	
	-- 如果没有武将，创建3个初始武将
	if #self.generals == 0 then
		local new_generals, ok = PUBLIC.randCreateGeneral(self, 3)
		if ok and new_generals then
			for _, general in ipairs(new_generals) do
				table.insert(self.generals, general)
				ld.id_map_cache[general.id] = general
			end
		end
	end
end
function lf.loaded(self)

end
function lf.enter(self, seq)

end
function lf.leave(self)
end

function lf.save(self, m_name)
	if m_name == NM then
		-- 保存所有武将
		for _, general in ipairs(self.generals) do
			PUBLIC.saveGeneral(self, general.id)
		end
	end
end

-- 根据ID获取武将
function PUBLIC.getGeneralById(self, id)
	return ld.id_map_cache[id]
end

-- 保存单个武将
function PUBLIC.saveGeneral(self, id)
	local general = ld.id_map_cache[id]
	if not general then
		return false
	end
	
	-- 使用 saveDbData 保存（id 作为主键）
	return PUBLIC.saveDbData(ld.table_name, "id", id, general, ld.db)
end

-- 批量保存武将
function PUBLIC.saveGenerals(self, ids)
	if not ids or #ids == 0 then
		return true
	end
	
	for _, id in ipairs(ids) do
		PUBLIC.saveGeneral(self, id)
	end
	return true
end

-- 创建新武将
function PUBLIC.createGeneral(self, cfgId, level)
	level = level or 1
	local basic_config = sharedata.query("config/basic.lua")
	local general_config = sharedata.query("config/general/general.lua")
	
	if not general_config or not general_config.list then
		elog("createGeneral: general config not found")
		return nil, false
	end
	
	-- 查找武将配置
	local cfg = nil
	for _, c in ipairs(general_config.list) do
		if c.cfgId == cfgId then
			cfg = c
			break
		end
	end
	
	if not cfg then
		elog("createGeneral: general cfg not found, cfgId:", cfgId)
		return nil, false
	end
	
	local default_skills = {{id = 0, lv = 0, cfgId = 0}, {id = 0, lv = 0, cfgId = 0}, {id = 0, lv = 0, cfgId = 0}}
	
	-- 创建武将数据
	local general = {
		rid = self.rid,
		cfgId = cfgId,
		level = level,
		physical_power = basic_config.general.physical_power_limit or 100,
		exp = 0,
		order = 0,
		cityId = 0,
		star = cfg.star,
		star_lv = 0,
		arms = cfg.arms and cfg.arms[1] or 0,
		has_pr_point = 0,
		use_pr_point = 0,
		attack_distance = 0,
		force_added = 0,
		strategy_added = 0,
		defense_added = 0,
		speed_added = 0,
		destroy_added = 0,
		parentId = 0,
		compose_type = 0,
		skills = default_skills,  -- 作为 table，会自动编码为 JSON
		state = GeneralState.Normal,
		created_at = os.date('%Y-%m-%d %H:%M:%S'),
	}
	
	-- 准备插入数据（skills 需要编码为 JSON 字符串）
	local insert_data = {}
	for k, v in pairs(general) do
		if k == "skills" and type(v) == "table" then
			insert_data[k] = cjson.encode(v)
		else
			insert_data[k] = v
		end
	end
	
	-- 直接使用 MySQL insert 接口
	local ok, gid = skynet.call(".mysql", "lua", "insert", ld.table_name, insert_data)
	if not ok then
		elog("createGeneral: insert to db failed")
		return nil, false
	end
	
	-- 设置 id 并添加到内存
	general.id = gid
	general.skills = default_skills  -- 保持为 table 格式
	
	-- 添加到内存
	table.insert(self.generals, general)
	ld.id_map_cache[general.id] = general
	
	return general, true
end

-- 随机创建武将
function PUBLIC.randCreateGeneral(self, nums)
	nums = tonumber(nums) or 1
	local general_config = sharedata.query("config/general/general.lua")
	
	if not general_config or not general_config.list then
		elog("randCreateGeneral: general config not found")
		return nil, false
	end
	
	local cfgList = general_config.list
	if not cfgList or #cfgList == 0 then
		elog("randCreateGeneral: general config list is empty")
		return nil, false
	end
	
	local new_generals = {}
	for i = 1, nums do
		local randomIndex = math.random(1, #cfgList)
		local cfgId = cfgList[randomIndex].cfgId
		
		local general, ok = PUBLIC.createGeneral(self, cfgId, 1)
		if not ok then
			elog("randCreateGeneral: create general failed, cfgId:", cfgId)
			return nil, false
		end
		table.insert(new_generals, general)
	end
	
	return new_generals, true
end

-- 更新武将体力
function PUBLIC.updatePhysicalPower(self, gid, new_power)
	local general = ld.id_map_cache[gid]
	if not general then
		return false
	end
	
	general.physical_power = new_power
	return PUBLIC.saveGeneral(self, gid)
end

-- 批量更新体力（每小时恢复）
function PUBLIC.recoverPhysicalPower(self)
	local basic_config = sharedata.query("config/basic.lua")
	local limit = basic_config.general.physical_power_limit or 100
	local recoverCnt = basic_config.general.recovery_physical_power or 10
	
	local updated = false
	for _, general in ipairs(self.generals) do
		if general.physical_power < limit then
			local new_power = math.min(limit, general.physical_power + recoverCnt)
			if new_power ~= general.physical_power then
				general.physical_power = new_power
				PUBLIC.saveGeneral(self, general.id)
				updated = true
			end
		end
	end
	
	return updated
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

function lf.army_dispose(self, generalId)
	PUBLIC.pushGeneral(self, generalId)
end
skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
	event:register("save", lf.save)
	event:register("army_dispose", lf.army_dispose)
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

	local new_generals, ok = PUBLIC.randCreateGeneral(self, drawTimes)
	if not ok then
		CMD.send2client({
			seq = args.seq,
			name = protoid.general_drawGeneral,
			code = error_code.DBError,
		})
		return
	end
	CMD.send2client({
		seq = args.seq,
		msg = {
			generals = new_generals,
		},
		name = protoid.general_drawGeneral,
		code = error_code.success,
	})
end