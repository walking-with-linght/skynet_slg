
-- 建筑
local skynet = require "skynet"
local base = require "base"
local event = require "event"
local cjson = require "cjson"
local sharedata = require "sharedata"
local protoid = require "protoid"
local error_code = require "error_code"

local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST

local NM = "facility"

local lf = base.LocalFunc(NM)
local ld = base.LocalData(NM,{
	db = {
		rid = "int",
		cityId = "int",
		facilities = "json",
	},
	table_name = "tb_city_facility_1",
})

local facilities_config = {}

function lf.load(self)

	local facility_config = sharedata.query("config/facility/facility.lua")
	for i,v in ipairs(facility_config.list) do
		facilities_config[i] = sharedata.query("config/facility/" .. v.path)
	end


	self.facility = {}
	local facility,ok = PUBLIC.loadDbData(ld.table_name, "rid", self.rid, ld.db)
	assert(ok)
	if ok and next(facility) then
		for _,v in pairs(facility) do
			self.facility[v.cityId] = v.facilities
		end
		PUBLIC.updateFacilityTime(self)
	else
		-- 初始化主城设施
		local init_facility = {}
		for i,v in ipairs(facility_config.list) do
			-- 顺序遍历，注意配置哈
			init_facility[i] = {
				type = v.type,
				name = v.name,
				level = 0,
				up_time = 0,
			}
		end
		-- 插入到数据库
		local ok,msg = skynet.call(".mysql", "lua", "insert", ld.table_name, {
			rid = self.rid,
			cityId = self.main_cityId,
			facilities = cjson.encode(init_facility),
		})
		assert(ok,msg)
		-- 初始化一下
		self.facility[self.main_cityId] = init_facility
	end
	-- print("load facility",dump(self.facility))
end
function lf.loaded(self)

end
function lf.enter(self, seq)
	PUBLIC.updateFacilityAdd(self)
end
function lf.leave(self)

end

function lf.new_city(self, city)
	self.facility[city.cityId] = city.facilities

	-- 这里应该可以不用插入，因为lf.save会识别插入或者更新
	-- local ok,msg = skynet.call(".mysql", "lua", "insert", "tb_city_facility_1", {
	-- 	rid = self.rid,
	-- 	cityId = city.cityId,
	-- 	facilities = cjson.encode(city.facilities),
	-- })
	-- assert(ok,msg)
end
function lf.save(self,m_name)
	if m_name  == NM then
		for cityId, facilities in pairs(self.facility) do
			if facilities then
				PUBLIC.saveDbData(ld.table_name, "cityId", cityId, {
					rid = self.rid,
						cityId = cityId,
						facilities = facilities,
					}, ld.db)
			end
		end
		PUBLIC.updateFacilityAdd(self)
	end
end
skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
	event:register("new_city",lf.new_city)
	event:register("save", lf.save)
end)

-- 获取某设施
function PUBLIC.getFacility(self, cityId, fType)
	local facility = self.facility[cityId][fType]
	return facility
end

-- 更新设施时间
function PUBLIC.updateFacilityTime(self)
	local dirty = false
	for cityId, facilities in pairs(self.facility) do
		for fType, facility in pairs(facilities) do
			if facility.up_time > 0 and facility.up_time <= os.time() then
				facility.up_time = 0
				facility.level = facility.level + 1
				dirty = true
			end
		end
	end
	if dirty then
		lf.save(self, NM)
	end
end

-- 更新城市设施的所有加成  
function PUBLIC.updateFacilityAdd(self)
	local additions = {}
	for cityId, facilities in pairs(self.facility) do
		additions[cityId] = {}
		for _,v in pairs(facilities) do
			local facility_config = facilities_config[v.type]
			if facility_config then
				for idx,addition_type in ipairs(facility_config.additions) do
					if v.level > 0 then
						additions[cityId][addition_type] = (additions[cityId][addition_type] or 0) + facility_config.levels[v.level].values[idx]
					end
				end
			end
		end
	end
	self.additions = additions
end

function PUBLIC.getFacilityAdd(self, cityId, addition_type)
	local additions = self.additions[cityId]
	if not additions then
		return 0
	end
	return additions[addition_type] or 0
end

-- 城市设施列表
REQUEST[protoid.city_facilities] = function(self,args)
	PUBLIC.updateFacilityTime(self)
	local facilities = self.facility[args.msg.cityId] or {}
	CMD.send2client({
		seq = args.seq,
		msg = {
			cityId = args.msg.cityId,
			facilities = facilities,
		},
		name = protoid.city_facilities,
		code = error_code.success,
	})
end

-- 升级设施
REQUEST[protoid.city_upFacility] = function(self,args)
	PUBLIC.updateFacilityTime(self)
	local cityId = args.msg.cityId
	local fType = args.msg.fType + 1
	local facility = self.facility[cityId][fType]
	if not facility then
		return CMD.send2client({
			seq = args.seq,
			name = protoid.city_upFacility,
			code = error_code.InvalidParam,
		})
	end
	-- 解锁条件
	local facility_config = facilities_config[fType]
	if not facility_config then
		return CMD.send2client({
			seq = args.seq,
			name = protoid.city_upFacility,
			code = error_code.InvalidParam,
		})
	end
	local conditions = facility_config.conditions
	for _,v in ipairs(conditions) do
		local condition_facility = self.facility[cityId][v.type + 1]
		if condition_facility.level < v.level then
			return CMD.send2client({
				seq = args.seq,
				name = protoid.city_upFacility,
				code = error_code.CanNotUpBuild,
			})
		end
	end
	-- 正在升级中
	if facility.up_time > 0 and facility.up_time > os.time() then
		return CMD.send2client({
			seq = args.seq,
			name = protoid.city_upFacility,
			code = error_code.UpError,
		})
	end

	-- 下一级
	local next_level = facility.level + 1
	-- 资源需求
	local need = facility_config.levels[next_level].need
	for k,v in pairs(need) do
		if self.resource[k] < v then
			return CMD.send2client({
				seq = args.seq,
				name = protoid.city_upFacility,
				code = error_code.ResNotEnough,
			})
		end
	end
	-- 扣除资源  这里要注意，应该同步扣除，如果失败，需要回滚
	for k,v in pairs(need) do
		self.resource[k] = self.resource[k] - v
		assert(self.resource[k] >= 0)
	end
	PUBLIC.updateRoleRes(self)

	 -- 这里不加等级，等时间到了再加 PUBLIC.updateFacilityTime(self)
	-- facility.level = facility.level + 1 
	print("升级设施", cityId, fType, next_level, facility.up_time,facility_config.levels[next_level].time)
	facility.up_time = os.time() + facility_config.levels[next_level].time
	lf.save(self, NM)
	CMD.send2client({
		seq = args.seq,
		msg = {
			cityId = cityId,
			facility = facility,
			role_res = self.resource,
		},
		name = protoid.city_upFacility,
		code = error_code.success,
	})
end

-- 市场
REQUEST[protoid.interior_transform] = function(self,args)
	PUBLIC.updateFacilityTime(self)
	local main_cityId = self.main_cityId
	local facility = self.facility[main_cityId][16]
	if not facility or facility.level <= 0 then
		return CMD.send2client({
			seq = args.seq,	
			name = protoid.interior_transform,
			code = error_code.NotHasJiShi,
		})
	end
	-- 获取市场等级
	local market_level = facility.level
	-- 获取市场配置
	local market_config = facilities_config[16].levels[market_level]
	if not market_config then
		return CMD.send2client({
			seq = args.seq,
			name = protoid.interior_transform,
			code = error_code.InvalidParam,
		})
	end
	local add_rate = market_config.values[1] + 50
	print("市场等级", market_level, "加成", add_rate)
	-- 待转换资源 目标资源
	local source = {
		type = 0,
		value = 0
	}
	local target = {
		type = 0,
		value = 0
	}
	for k,v in ipairs(args.msg.from) do
		if v > 0 then
			source.type = k
			source.value = v
			break
		end
	end
	for k,v in ipairs(args.msg.to) do
		if v > 0 then
			target.type = k
			target.value = v
			break
		end
	end
	if source.type == 0 or target.type == 0  or source.type == target.type then
		return CMD.send2client({
			seq = args.seq,
			name = protoid.interior_transform,
			code = error_code.InvalidParam,
		})
	end
	-- 计算转换比例
	local convert_rate = add_rate / 100
	
	local source_res = self.resource[Market_Type_Server[source.type]]
	print("转换比例", convert_rate,source.type,Market_Type_Server[source.type],source_res, source.value)
	if source_res < source.value then
		return CMD.send2client({
			seq = args.seq,
			name = protoid.interior_transform,
			code = error_code.ResNotEnough,
		})
	end
	local target_res = self.resource[Market_Type_Server[target.type]]
	PUBLIC.modifyRoleRes(self, {
		[Market_Type_Server[source.type]] = -source.value,
		[Market_Type_Server[target.type]] = math.ceil((source.value * convert_rate)/100),
	})
	
	PUBLIC.pushRoleRes(self)
	CMD.send2client({
		seq = args.seq,
		name = protoid.interior_transform,
		code = error_code.success,
	})
end