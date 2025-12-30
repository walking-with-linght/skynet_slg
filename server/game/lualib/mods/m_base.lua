

local skynet = require "skynet"
local base = require "base"
local error_code = require "error_code"
local event = require "event"
local sharedata = require "skynet.sharedata"
local sessionlib = require "session"
local time = require "time"
local protoid = require "protoid"
local utils = require "utils"
local cjson = require "cjson"

local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST

local NM = "base"

local lf = base.LocalFunc(NM)
local ld = base.LocalData(NM,{
	-- db 字段定义表，格式: {field_name = "type", ...}
	-- 支持的类型: "int", "string", "json", "float", "datetime"
	-- 示例: {rid = "int", jsondata = "json", name = "string"}
	db = {
		rid = "int",
		uid = "int",
		headId = "int",
		sex = "int",
		nick_name = "string",
		balance = "int",
		login_time = "string",
		logout_time = "string",
		created_at = "string",
		profile = "string",
	},
	table_name = "tb_role_1",
})

function lf.load(self)
	local role,ok = PUBLIC.loadDbData(ld.table_name, "rid", self.rid, ld.db)
	role = role[1]
	role.nickName = role.nick_name
	-- 基础数据
	self.role = role
	print("load role",dump(role))
end
function lf.loaded(self)
	rlog("rid base-mod loaded")
end
function lf.enter(self, seq)
	rlog("rid base-mod enter")
	local ok,session = sessionlib.generate_session(self.rid)
    if ok ~= 0 then
        elog(self.uid, session)
        return
    end
	self.token = session
	CMD.send2client({
		seq = seq,
		msg = {
			role = self.role,
			role_res = self.resource,
			time = math.floor(time.gettime() / 10),
			token = session,
		},
		name = protoid.role_enterServer,
		code = error_code.success,
	})
end
function lf.leave(self)
end

function lf.save(self,m_name)
	if m_name  == NM then
		PUBLIC.saveDbData(ld.table_name, "rid", self.rid, self.role, ld.db)
	end
end

skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
	event:register("save", lf.save)
end)

function PUBLIC.parseRoleRes(self)
	local role_res_config = sharedata.query("config/basic.lua")
	local pack_role_res = {
		depot_capacity = role_res_config.role.depot_capacity,
		gold_yield = role_res_config.role.gold_yield,
		grain_yield = role_res_config.role.grain_yield,
		iron_yield = role_res_config.role.iron_yield,
		stone_yield = role_res_config.role.stone_yield,
		wood_yield = role_res_config.role.wood_yield,
	}
	table.merge(pack_role_res, self.resource)
	return pack_role_res
end

function PUBLIC.pushRoleRes(self)
	CMD.send2client({
		seq = 0,
		msg = PUBLIC.parseRoleRes(self),
		name = protoid.roleRes_push,
		code = error_code.success,
	})
end


-------client-------
function REQUEST:heartbeat()
	return {result = error_code.success}
end

-- 地形配置
REQUEST[protoid.nationMap_config] = function(self,args)
	local config = sharedata.query("config/map_build.lua")
	CMD.send2client({
		seq = args.seq,
		msg = {
			Confs = config.cfg,
		},
		name = protoid.nationMap_config,
		code = error_code.success,
	})
end

-- 角色属性
REQUEST[protoid.nrole_myProperty] = function(self,args)
	local role_res_config = sharedata.query("config/basic.lua")
	local pack_role_res = {
		depot_capacity = role_res_config.role.depot_capacity,
		gold_yield = role_res_config.role.gold_yield,
		grain_yield = role_res_config.role.grain_yield,
		iron_yield = role_res_config.role.iron_yield,
		stone_yield = role_res_config.role.stone_yield,
		wood_yield = role_res_config.role.wood_yield,
	}
	table.merge(pack_role_res, self.resource)
	local pack = {
		armys = self.armys,
		citys = self.citys,
		generals = self.generals,
		mr_builds = {}, -- 应该是正在建造的建筑
		role_res = pack_role_res,
	}
	CMD.send2client({
		seq = args.seq,
		msg = pack,
		name = protoid.nrole_myProperty,
		code = error_code.success,
	})
end

-- 坐标收藏
REQUEST[protoid.role_posTagList] = function(self,args)
	CMD.send2client({
		seq = args.seq,
		msg = self.attr.pos_tags,
		name = protoid.role_posTagList,
		code = error_code.success,
	})
end
-- 标记坐标
REQUEST[protoid.role_opPosTag] = function(self,args)
	local pos_tags = self.attr.pos_tags
	-- args.msg.type 1=标记，0=取消标记
	if args.msg.type == 1 then -- 标记
		local is_exist = false
		for i,v in ipairs(pos_tags) do
			if v.x == args.msg.x and v.y == args.msg.y then
				return CMD.send2client({
					seq = args.seq,
					name = protoid.role_opPosTag,
					code = error_code.InvalidParam,
				})
			end
		end
		table.insert(pos_tags, args.msg)
	else -- 取消标记
		for i,v in ipairs(pos_tags) do
			if v.x == args.msg.x and v.y == args.msg.y then
				table.remove(pos_tags, i)
				break
			end
		end
	end
	self.attr.pos_tags = pos_tags
	CMD.send2client({
		seq = args.seq,
		msg = {
			type = args.msg.type,
			x = args.msg.x,
			y = args.msg.y,
			name = args.msg.name,
		},
		name = protoid.role_posTagList,
		code = error_code.success,
	})
end
