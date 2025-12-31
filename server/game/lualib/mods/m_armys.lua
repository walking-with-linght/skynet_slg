
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
		id = "int",
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
		start = "timestamp", -- 出发时间
		['end'] = "timestamp", -- 到达时间
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
	PUBLIC.checkArmyConscript(self)
end
function lf.leave(self)

end

function lf.save(self, m_name)
	if m_name == NM then
		for _, army in ipairs(self.armys) do
			if army.id then
				-- 使用 saveDbData 自动处理 JSON 字段编码
				PUBLIC.saveDbData(ld.table_name, "id", army.id, army, ld.db)
			end
		end
	end
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
	local army = PUBLIC.getArmy(self, cityId, order)
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

-- 根据部队id获取部队
function PUBLIC.getArmyById(self, armyId)
	PUBLIC.checkArmyConscript(self)
	for _, army in ipairs(self.armys) do
		if army.id == armyId then
			return army
		end
	end
end
-- 获取部队
function PUBLIC.getArmy(self, cityId, order)
	PUBLIC.checkArmyConscript(self)
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
	local ok,id = skynet.call(".mysql", "lua", "insert", ld.table_name, army)
	if not ok then
		return nil, error_code.DBError
	end
	army.id = id
	army.generals = default_generals
	army.soldiers = default_soldiers
	army.conscript_times = default_conscript_times
	army.conscript_cnts = default_conscript_cnts
	return army
end
-- 武将下阵
function PUBLIC.armyGeneralDown(self, cityId, order, position)
	local army = PUBLIC.getArmy(self, cityId, order)
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
	event:dispatch("save", self,NM)
	-- 武将也要更新
	local general = PUBLIC.getGeneralById(self, generalId)
	if not general then
		return true -- false, error_code.GeneralNotFound
	end
	general.order = 0
	general.cityId = 0
	event:dispatch("save", self,"generals")
	return true
end

-- 武将上阵
function PUBLIC.armyGeneralUp(self, cityId, order, position, generalId)
	PUBLIC.checkArmyConscript(self)
	local army = PUBLIC.getArmy(self, cityId, order)
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
	event:dispatch("save", self,NM)
	
	general.cityId = cityId
	general.order = order
	event:dispatch("save", self,"generals")
	return true
end

-- 推送部队信息到客户端
function PUBLIC.pushArmy(self, cityId, order)
	local army = PUBLIC.getArmy(self, cityId, order)
	if not army then
		return
	end
	local msg = PUBLIC.pack_army_info(self, army)
	CMD.send2client({
		seq = MSG_TYPE.S2C,
		msg = msg,
		name = protoid.army_push,
		code = error_code.success,
	})
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

function PUBLIC.pack_army_list(self)
	local army_list = {}
	for _, army in ipairs(self.armys) do
		table.insert(army_list, PUBLIC.pack_army_info(self, army))
	end
	return army_list
end

-- 检查是否征兵完成
function PUBLIC.checkArmyConscript(self)
	local dirty = false
	for _, army in ipairs(self.armys) do
		if army.cmd == Army_Cmd.ArmyCmdConscript then
			local is_ok = 0
			for idx, cnt in ipairs(army.conscript_cnts) do
				if cnt > 0 then
					local end_time = army.conscript_times[idx]
					if end_time > 0 and end_time <= os.time() then
						army.conscript_times[idx] = 0
						army.conscript_cnts[idx] = 0
						army.soldiers[idx] = army.soldiers[idx] + cnt
						dirty = true
						is_ok = is_ok + 1
					end
				else
					is_ok = is_ok + 1
				end
			end
			if is_ok == #army.conscript_cnts then
				army.cmd = Army_Cmd.ArmyCmdIdle
				dirty = true
			end
		end
	end
	if dirty then
		event:dispatch("save", self,NM)
	end
end
-- 发送部队信息到客户端
function PUBLIC.pack_army_info(self, army)
	return {
		cityId = army.cityId,
		order = army.order,
		generals = army.generals,
		soldiers = army.soldiers,
		con_times = army.conscript_times,
		con_cnts = army.conscript_cnts,
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
		id = army.id, -- 部队id,应该是mysql中的id
	}
end

-- 计算该部队的cost
function PUBLIC.getArmyCost(self, cityId, order)
	local army = PUBLIC.getArmy(self, cityId, order)
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
	PUBLIC.checkArmyConscript(self)
	local cityId = self.main_cityId
	CMD.send2client({
		seq = args.seq,
		msg = {
			armys = PUBLIC.pack_army_list(self),
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
	PUBLIC.checkArmyConscript(self)

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
	local army = PUBLIC.getArmy(self, cityId, order)
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
	local real_position = nil
	for pos, _generalId in ipairs(army.generals) do
		if _generalId == generalId then
			real_position = pos
			break
		end
	end
	real_position = real_position or (position + 1)
	-- 该位置是否能变动
	local ok,code = PUBLIC.armyCanModify(self, cityId, order, real_position)
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
		local ok,code = PUBLIC.armyGeneralDown(self, cityId, order, real_position)
		if not ok then
			CMD.send2client({
				seq = args.seq,
				name = protoid.army_dispose,
				code = code, 
			})
			return
		end
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
		local ok,code = PUBLIC.armyGeneralUp(self, cityId, order, real_position, generalId)
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
		msg = {army = PUBLIC.pack_army_info(self, army)},
		name = protoid.army_dispose,
		code = error_code.success,
	})
	PUBLIC.pushArmy(self, cityId, order)
	event:dispatch("save", self,NM)
	event:dispatch("army_dispose", self, generalId)
end

-- 分配士兵
REQUEST[protoid.army_conscript] = function(self,args)
	PUBLIC.checkArmyConscript(self)
	local armyId = args.msg.armyId
	local cnts = args.msg.cnts
	local army = PUBLIC.getArmyById(self, armyId)
	if not army then
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_conscript,
			code = error_code.ArmyNotFound,
		})
		return
	end
	if #cnts ~= 3 then
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_conscript,
			code = error_code.InvalidParam,
		})
		return
	end
	-- 募兵所等级
	local mbs = PUBLIC.getFacility(self, army.cityId, Facility_Type.MBS)
	if not mbs or mbs.level < 1 then
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_conscript,
			code = error_code.BuildMBSNotFound,
		})
		return
	end
	-- 带兵数量限制
	-- 基础带兵数量
	local general_basic_config = sharedata.query("config/general/general_basic.lua")
	local general_config = sharedata.query("config/general/general.lua")
	for idx, generalId in ipairs(army.generals) do
		if generalId ~= 0 then
			local g = PUBLIC.getGeneralById(self, generalId)
			if not g then
				CMD.send2client({
					seq = args.seq,
					name = protoid.army_conscript,
					code = error_code.DBError,
				})
				return
			end
			local base_soldiers = general_basic_config.levels[g.level].soldiers
			-- 士兵数量加成
			local soldiers_add = PUBLIC.getFacilityAdd(self, army.cityId, Facility_Addition_Type.TypeSoldier)
			local max_soldiers = base_soldiers + soldiers_add
			if cnts[idx] > max_soldiers then
				CMD.send2client({
					seq = args.seq,
					name = protoid.army_conscript,
					code = error_code.OutArmyLimit,
				})
				return
			end
		end
	end

	-- 征兵消耗
	local total = 0
	for idx, cnt in ipairs(cnts) do
		if cnt > 0 then
			total = total + cnt
		end
	end
	local conscript_config = sharedata.query("config/basic.lua").conscript
	local cost_wood = total * conscript_config.cost_wood
	local cost_iron = total * conscript_config.cost_iron
	local cost_stone = total * conscript_config.cost_stone
	local cost_grain = total * conscript_config.cost_grain
	local cost_gold = total * conscript_config.cost_gold
	local ok = PUBLIC.batchDeductRoleRes(self, {
		wood = cost_wood,
		iron = cost_iron,
		stone = cost_stone,
		grain = cost_grain,
		gold = cost_gold,
	})
	if not ok then
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_conscript,
			code = error_code.ResNotEnough,
		})
		return
	end
	for idx, cnt in ipairs(cnts) do
		if cnt > 0 then
			army.conscript_times[idx] = os.time() + cnt *conscript_config.cost_time
			army.conscript_cnts[idx] = cnt
		end
	end
	army.cmd = Army_Cmd.ArmyCmdConscript
	event:dispatch("save", self,NM)
	PUBLIC.pushArmy(self, army.cityId, army.order)
	CMD.send2client({
		seq = args.seq,
		msg = {
			army = PUBLIC.pack_army_info(self, army),
			role_res = self.resource,
		},
		name = protoid.army_conscript,
		code = error_code.success,
	})
end

-- 查看单个部队数据
REQUEST[protoid.army_myOne] = function(self,args)
	PUBLIC.checkArmyConscript(self)
	local cityId = args.msg.cityId
	local order = args.msg.order
	local army = PUBLIC.getArmy(self, cityId, order)
	if not army then
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_one,
			code = error_code.ArmyNotFound,
		})
		return
	end
	CMD.send2client({
		seq = args.seq,
		msg = {
			army = PUBLIC.pack_army_info(self, army),
		},
		name = protoid.army_myOne,
		code = error_code.success,
	})
end

-- 军队是否可以出征
function PUBLIC.armyCanTransfer(self, army)
	return army.cmd == Army_Cmd.ArmyCmdIdle and army.generals[1] ~= 0 and army.soldiers[1] > 0
end

-- 军队是否能到达该地
function PUBLIC.armyCanArrive(self, x, y)
	return army.from_x == msg.x and army.from_y == msg.y
end

function lf.army_prepare(self, army, msg)
	if msg.x < 0 or msg.y < 0 or msg.x > Game_Map_Size.Width or msg.y > Game_Map_Size.Height then
		return error_code.InvalidParam
	end
	if not PUBLIC.armyCanTransfer(self, army) then
		if army.cmd ~= Army_Cmd.ArmyCmdConscript then
			return error_code.ArmyBusy
		else
			return error_code.ArmyNotMain
		end
	end
	local buildConfig = skynet.call(".map_manager", "lua", "getBuildConfigByPosition", msg.x, msg.y)
	--判断该地是否是能攻击类型
	if not buildConfig or buildConfig[1] == 0 then
		return error_code.InvalidParam
	end
	-- 该地是否能到达
	if not PUBLIC.armyCanArrive(self, army, msg) then
		return error_code.UnReachable
	end
	return true
end


-- 回城
function lf.army_back(self, armyId, args)
	lf.army_prepare(self, armyId)
end
-- 攻击
function lf.army_defend(self, armyId, args)
	lf.army_prepare(self, armyId)
end
-- 驻守
function lf.army_defend(self, armyId, args)
	lf.army_prepare(self, armyId)
end
-- 开垦
function lf.army_reclamation(self, armyId, args)
	lf.army_prepare(self, armyId)
end
-- 调兵
function lf.army_transfer(self, armyId, args)
	lf.army_prepare(self, armyId)
end
-- 
-- 派遣部队
REQUEST[protoid.army_assign] = function(self,args)
	PUBLIC.checkArmyConscript(self)
	local armyId = args.msg.armyId
	local cmd = args.msg.cmd
	local x = args.msg.x
	local y = args.msg.y
	local army = PUBLIC.getArmyById(self, armyId)
	if not army then
		CMD.send2client({
			seq = args.seq,
			name = protoid.army_assign,
			code = error_code.ArmyNotFound,	
		})
		return
	end
	local code = error_code.success
	if cmd == Army_Cmd.ArmyCmdBack then
		code = lf.army_back(self, armyId, args)
	elseif cmd == Army_Cmd.ArmyCmdAttack then
		code = lf.army_attack(self, armyId, args)
	elseif cmd == Army_Cmd.ArmyCmdDefend then
		code = lf.army_defend(self, armyId, args)
	elseif cmd == Army_Cmd.ArmyCmdReclamation then
		code = lf.army_reclamation(self, armyId, args)
	elseif cmd == Army_Cmd.ArmyCmdTransfer then
		code = lf.army_transfer(self, armyId, args)
	end
	CMD.send2client({
		seq = args.seq,
		msg = PUBLIC.pack_army_info(self, army),
		name = protoid.army_assign,
		code = code,
	})
end