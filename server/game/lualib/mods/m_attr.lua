

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

local NM = "attr"

local lf = base.LocalFunc(NM)
local ld = base.LocalData(NM,{
	-- db 字段定义表，格式: {field_name = "type", ...}
	-- 支持的类型: "int", "string", "json", "float", "datetime"
	-- 示例: {rid = "int", jsondata = "json", name = "string"}
	db = {
		rid = "int",
		parent_id = "int",
		collect_times = "int",
		pos_tags = "json",
		last_collect_time = "timestamp",
	},
	table_name = "tb_role_attribute_1",
})

function lf.load(self)
	local attr,ok = PUBLIC.loadDbData(ld.table_name, "rid", self.rid, ld.db)
    if not attr[1] or not next(attr[1]) then
        attr = {
            rid = self.rid,
            parent_id = 0,
            collect_times = 0,
            pos_tags = cjson.encode({}),
            last_collect_time = os.date("%Y-%m-%d %H:%M:%S"),
        }
        local ok = skynet.call(".mysql", "lua", "insert", ld.table_name, attr)
        assert(ok)
		attr.pos_tags = {}
		self.attr = attr
    else
		self.attr = attr[1]
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
		PUBLIC.saveDbData(ld.table_name, "rid", self.rid, self.attr, ld.db)
	end
end

skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
	event:register("save", lf.save)
end)

function PUBLIC.updateRoleAttr(self, attr_map)
	for k,v in pairs(attr_map or {}) do
		self.attr[k] = v
	end
	lf.save(self, NM)
end


-- 坐标收藏
REQUEST[protoid.role_posTagList] = function(self,args)
	CMD.send2client({
		seq = args.seq,
		msg = {
			pos_tags  = self.attr.pos_tags
		},
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
		print("pos_tags",dump(pos_tags),dump(args.msg))
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
	lf.save(self, NM)
	CMD.send2client({
		seq = args.seq,
		msg = {
			type = args.msg.type,
			x = args.msg.x,
			y = args.msg.y,
			name = args.msg.name,
		},
		name = protoid.role_opPosTag,
		code = error_code.success,
	})
end