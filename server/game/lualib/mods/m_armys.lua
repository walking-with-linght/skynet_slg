
-- 军队
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
    self.armys = armys
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

-- 部队是否能变化（上下阵）
function PUBLIC.armyCanModify(self, cityId, order, position)
	local army = PUBLIC.getArmyById(self, cityId, order)
	if not army then
		return false, error_code.ArmyNotFound
	end
	if army.cmd == Army_Cmd.ArmyCmdIdle then
		return true
	end
	if army.cmd == Army_Cmd.ArmyCmdConscript then
		local end_time = army.conscript_times[position]
		return end_time == 0, error_code.ArmyConscript
	end
	return false, error_code.GeneralBusy
end

-- 获取部队
function PUBLIC.getArmyById(self, cityId, order)
	for _, army in ipairs(self.armys) do
		if army.cityId == cityId and army.order == order then
			return army
		end
	end
	local city = PUBLIC.getCityById(self, cityId)
	if not city then
		return nil, error_code.CityNotExist
	end
	local default_generals = {0, 0, 0}
	local default_soldiers = {0, 0, 0}
	local default_conscript_times = {0, 0, 0}
	local default_conscript_cnts = {0, 0, 0}
	-- 创建新部队
	local army = {
		rid = self.rid,
		cityId = cityId,
		order = order,
		generals = cjson.encode(default_generals),
		soldiers = cjson.encode(default_soldiers),
		conscript_times = cjson.encode(default_conscript_times),
		conscript_cnts = cjson.encode(default_conscript_cnts),
		cmd = Army_Cmd.ArmyCmdIdle,
		from_x = city.x,
		from_y = city.y,
		to_x = city.x,
		to_y = city.y,
		start = nil,
		['end'] = nil,
	}
	table.insert(self.armys, army)
	-- 保存到数据库
	skynet.call(".mysql", "lua", "insert", ld.table_name, army)
	army.generals = default_generals
	army.soldiers = default_soldiers
	army.conscript_times = default_conscript_times
	army.conscript_cnts = default_conscript_cnts
	return army
end
-- 武将下阵
function PUBLIC.armyGeneralDown(self, cityId, order, position)
	local army = PUBLIC.getArmyById(self, cityId, order)
	if not army then
		return false, error_code.ArmyNotFound
	end
	local ok,code = PUBLIC.armyCanModify(self, cityId, order, position)
	if not ok then
		return false, code
	end
	local generalId = army.generals[position]
	army.generals[position] = 0
	army.soldiers[position] = 0
	army.conscript_times[position] = 0
	army.conscript_cnts[position] = 0
	event:dispatch("save", NM)
	-- 武将也要更新
	local general = PUBLIC.getGeneralById(self, generalId)
	if not general then
		return true -- false, error_code.GeneralNotFound
	end
	general.order = 0
	general.cityId = 0
	event:dispatch("save", "generals")
	return true
end

-- 武将上阵
function PUBLIC.armyGeneralUp(self, cityId, order, position, generalId)
	local army = PUBLIC.getArmyById(self, cityId, order)
	if not army then
		return false, error_code.ArmyNotFound
	end
	local ok,code = PUBLIC.armyCanModify(self, cityId, order, position)
	if not ok then
		return false, code
	end
	local general = PUBLIC.getGeneralById(self, generalId)
	if not general then
		return false, error_code.GeneralNotFound
	end

	army.generals[position] = generalId
	army.soldiers[position] = 0
	event:dispatch("save", NM)
	
	general.cityId = cityId
	general.order = order
	event:dispatch("save", "generals")
	return true
end
-- 武将是否已在其他部队
function PUBLIC.generalIsInArmy(self, generalId)
	for _, army in pairs(self.armys) do
		for pos, gid in ipairs(army.generals) do
			if gid == generalId then
				return pos
			end
		end
	end
end

-- 发送部队信息到客户端
function PUBLIC.pack_army_info(self, army)
	return {
		cityId = army.cityId,
		order = army.order,
		generals = army.generals,
		soldiers = army.soldiers,
		conscript_times = army.conscript_times,
		conscript_cnts = army.conscript_cnts,
		cmd = army.cmd,
		from_x = army.from_x,
		from_y = army.from_y,
		to_x = army.to_x,
		to_y = army.to_y,
		start = army.start or -62135596800,
		['end'] = army['end']or -62135596800,
		rid = self.rid,
		state = army.cmd,
		union_id = 0, -- 联盟，暂时为0
	}
end

-- 计算该部队的cost
function PUBLIC.getArmyCost(self, cityId, order)
	local army = PUBLIC.getArmyById(self, cityId, order)
	if not army then
		return 0
	end
	local total_cost = 0
	local general_config = sharedata.query("config/general/general.lua")
	for _, gid in ipairs(army.generals) do
		if general_config.cfgIdMap[gid] then
			total_cost = total_cost + general_config.cfgIdMap[gid].cost
		end
	end
	return total_cost
end
-- 部队列表
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

-- 部队重组
REQUEST[protoid.army_dispose] = function(self,args)
	local cityId = args.msg.cityId
	local order = args.msg.order
	local generalId = args.msg.generalId
	local position = args.msg.position

	if order <= 0 or order > 5  or position < -1 or position > 2 then
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_dispose,
			code = error_code.InvalidParam,
		})
		return
	end

	local city = PUBLIC.getCityById(self, cityId)
	if not city then
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_dispose,
			code = error_code.CityNotExist,
		})
		return
	end
	-- 校场等级，每升一级可解锁一支队伍
	local jc = PUBLIC.getFacility(self, cityId, Facility_Type.JiaoChang)
	if not jc or jc.level < order then
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_dispose,
			code = error_code.ArmyNotEnough,
		})
		return
	end
	-- 武将
	local general = PUBLIC.getGeneralById(self, generalId)
	if not general then	
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_dispose,
			code = error_code.GeneralNotFound,
		})
		return
	end
	-- 
	local army = PUBLIC.getArmyById(self, cityId, order)
	if not army then
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_dispose,
			code = error_code.DBError,
		})
		return
	end
	if army.from_x ~= city.x or army.from_y ~= city.y then
		print("army.from_x", army.from_x, type(army.from_x), "city.x", city.x, type(city.x))
		print("army.from_y", army.from_y, type(army.from_y), "city.y", city.y, type(city.y))
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_dispose,
			code = error_code.ArmyIsOutside,
		})
		return
	end
	-- 该位置是否能变动
	local ok,code = PUBLIC.armyCanModify(self, cityId, order, position)
	if not ok then
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_dispose,
			code = code,
		})
		return
	end

	-- 下阵
	if position == -1 then
		local ok,code = PUBLIC.armyGeneralDown(self, cityId, order, position)
		if not ok then
			CMD.send2client({
				seq = args.seq,
				name = protoid.army_dispose,
				code = code, 
			})
			return
		end
		CMD.send2client({
			seq = args.seq,
			msg = army,
			name = protoid.army_dispose,
			code = error_code.success,
		})
		return
	else
		-- 上阵

		-- 该武将已有所属部队
		if general.cityId ~= 0 then
			CMD.send2client({
				seq = args.seq,
				name = protoid.army_dispose,
				code = error_code.GeneralBusy,
			})
			return
		end
		local pos = PUBLIC.generalIsInArmy(self, generalId)
		if pos then
			CMD.send2client({
				seq = args.seq,
				name = protoid.army_dispose,
				code = error_code.GeneralRepeat,
			})
			return
		end
		-- 统帅厅
		local tst = PUBLIC.getFacility(self, cityId, Facility_Type.TongShuaiTing)
		-- 解锁第三个位置需要统帅厅
		if position == 2 and (not tst or tst.level < order) then
			CMD.send2client({
				seq = args.seq,
				name = protoid.army_dispose,
				code = error_code.TongShuaiNotEnough,
			})
			return
		end
		local all_general_config = sharedata.query("config/general/general.lua")
		local basic_config = sharedata.query("config/basic.lua")
		local general_config = all_general_config.cfgIdMap[general.cfgId]
		local current_cost = PUBLIC.getArmyCost(self, cityId, order)
		local cost_add = PUBLIC.getFacilityAdd(self, cityId, Facility_Addition_Type.TypeCost)
		if (current_cost + general_config.cost) > (basic_config.city.cost + cost_add) then
			CMD.send2client({
				seq = args.seq,
				name = protoid.army_dispose,
				code = error_code.CostNotEnough,
			})
			return
		end
		-- 上阵
		local ok,code = PUBLIC.armyGeneralUp(self, cityId, order, position, generalId)
		if not ok then
			CMD.send2client({
				seq = args.seq,
				name = protoid.army_dispose,
				code = code,
			})
			return
		end
	end
	army.from_x = city.x
	army.from_y = city.y
	CMD.send2client({
		seq = args.seq,
		msg = PUBLIC.pack_army_info(self, army),
		name = protoid.army_dispose,
		code = error_code.success,
	})
	return
end