
-- 城市
local skynet = require "skynet"
local base = require "base"
local event = require "event"
local sharedata = require "skynet.sharedata"
local protoid = require "protoid"
local error_code = require "error_code"

local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST

local NM = "citys"

local lf = base.LocalFunc(NM)



function lf.load(self)
    local ok,citys = skynet.call(".mysql", "lua", "select_by_key", "tb_map_role_city_1", "rid", self.rid)
    if not citys or #citys == 0 then
        -- 创建主城池
        local ok, city = skynet.call(".map_manager", "lua", "findAndCreateMainCity", {rid = self.rid,nick_name = self.role.nick_name})
        assert(ok, "创建主城池失败")
        citys = {city}
    end
    local main_cityId = 0
    for _,city in ipairs(citys) do
        if city.is_main == 1 then
            main_cityId = city.cityId
            city.is_main = true
        else
            city.is_main = false
        end
        city.max_durable = city.max_durable or 100000
        city.level = city.level or 1
        city.parent_id = city.parent_id or 0
        city.union_id = city.union_id or 0
        city.union_name = city.union_name or ""
    end
    -- max_durable
    -- level
    -- parent_id
    -- union_id
    -- union_name
    self.citys = citys or {}
    self.main_cityId = main_cityId
end
function lf.loaded(self)

end
function lf.enter(self, seq)

end
function lf.leave(self)

end


skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
end)

-- 战报
REQUEST[protoid.nationMap_scanBlock] = function(self,args)

	-- CMD.send2client({
	-- 	seq = args.seq,
	-- 	msg = {
	-- 		list = {},
	-- 	},
	-- 	name = protoid.nationMap_scanBlock,
	-- 	code = error_code.success,
	-- })
end

-- 上报自己位置
REQUEST[protoid.role_upPosition] = function(self,args)

	-- CMD.send2client({
	-- 	seq = args.seq,
	-- 	msg = {
	-- 		list = {},
	-- 	},
	-- 	name = protoid.nationMap_scanBlock,
	-- 	code = error_code.success,
	-- })
end