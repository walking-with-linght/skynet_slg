

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
		parent_id = "int",
		collect_times = "int",
		pos_tags = "json",
		last_collect_time = "string",
	},
	table_name = "tb_role_attribute_1",
})

function lf.load(self)
	local ok,attr = PUBLIC.loadDbData(ld.table_name, "rid", self.rid, ld.db)
    if not ok or not next(attr) then
        attr = {
            rid = self.rid,
            parent_id = 0,
            collect_times = 0,
            pos_tags = cjson.encode({}),
            last_collect_time = os.date("%Y-%m-%d %H:%M:%S"),
        }
        local ok = skynet.call(".mysql", "lua", "insert", ld.table_name, attr)
        assert(ok)
    end
	self.attr = attr
end
function lf.loaded(self)
end
function lf.enter(self, seq)
	
end
function lf.leave(self)
end

function lf.save(self)
	PUBLIC.saveDbData(ld.table_name, "rid", self.rid, self.role, ld.db)
end

skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
	event:register("save", lf.save)
end)

