

local skynet = require "skynet"
local base = require "base"
local error_code = require "error_code"
local event = require "event"
local sharedata = require "skynet.sharedata"
local sessionlib = require "session"
local time = require "time"
local protoid = require "protoid"
local utils = require "utils"

local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST

local NM = "base"

local lf = base.LocalFunc(NM)
local ld = base.LocalData(NM,{
	db = {},--需要存库的数据
})

local db = ld.db

function lf.load(self)
	-- local key = PUBLIC.get_db_key(self.rid)
	-- local cache = Common.redisExecute({"hget",key,NM},Redis_DB.game)
	-- if cache then
	-- 	db = util.db_decode(cache)
	-- end
	
	-- 基础数据
	local ok,role = skynet.call(".mysql", "lua", "select_one_by_key", "tb_role_1", "rid", self.rid)
	assert(ok)
	
	-- 基础数据
	self.role = role
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
			role_res = self.role_res,
			time = math.floor(time.gettime() / 10),
			token = session,
		},
		name = protoid.role_enterServer,
		code = error_code.success,
	})
end
function lf.leave(self)
	rlog("rid base-mod leave")
end

skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
end)

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
	table.merge(pack_role_res, self.role_res)
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
		msg = self.role_attr.pos_tags,
		name = protoid.role_posTagList,
		code = error_code.success,
	})
end

