

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

local NM = "union"

local lf = base.LocalFunc(NM)
local ld = base.LocalData(NM)

function lf.load(self)
end
function lf.loaded(self)
end
function lf.enter(self, seq)
	local unionId = self.attr.union_id or 0
	skynet.send(".union_manager", "lua", "playerOnline", self.rid, unionId)
end
function lf.leave(self)
    skynet.send(".union_manager", "lua", "playerOffline", self.rid)
end

function lf.save(self,m_name)
end

skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
	event:register("save", lf.save)
end)

function CMD.union_notify(self, args)
	if args.type == "new_apply" then
		CMD.send2client({
			seq = MSG_TYPE.S2C,
			msg = {
				id = args.apply.id,
				rid = args.apply.rid,
				nick_name = args.nick_name,
			},
			name = protoid.unionApply_push,
			code = error_code.success,
		})
	end
end
-- 联盟列表
REQUEST[protoid.union_list] = function(self,args)
	local ret = skynet.call(".union_manager", "lua", "getUnionList", 1,20,"")
	CMD.send2client({
		seq = args.seq,
		msg = {
            list = ret.list,
        },
		name = protoid.union_list,
		code = error_code.success,
	})
end

-- 申请加入联盟
REQUEST[protoid.union_join] = function(self,args)
    if self.attr.union_id > 0 then
        return CMD.send2client({
            seq = args.seq,
            name = protoid.union_join,
            code = error_code.UnionAlreadyHas,
        })
    end
    local apply_union_id = args.msg.id
	local code = skynet.call(".union_manager", "lua", "applyJoinUnion", apply_union_id, self.rid)
	CMD.send2client({
		seq = args.seq,
		name = protoid.union_join,
		code = code,
	})
end

-- 创建联盟
REQUEST[protoid.union_create] = function(self,args)
	if self.attr.union_id > 0 then
        return CMD.send2client({
            seq = args.seq,
            name = protoid.union_create,
            code = error_code.UnionAlreadyHas,
        })
    end
	local name = args.msg.name
	local code,union_data = skynet.call(".union_manager", "lua", "createUnion", self.rid, name)
	if code == error_code.success then
		self.attr.union_id = union_data.id
		event:emit("union_create", self, union_data)
		CMD.send2client({
			seq = args.seq,
			msg = {
				id = union_data.id,
				name = union_data.name,
			},
			name = protoid.union_create,
			code = code,
		})
		return
	end
	CMD.send2client({
		seq = args.seq,
		name = protoid.union_create,
		code = code,
	})
end