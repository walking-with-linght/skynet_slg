
-- 城市
local skynet = require "skynet"
local base = require "base"
local event = require "event"

local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST

local NM = "citys"

local lf = base.LocalFunc(NM)

function lf.load(self)
    local ok,citys = skynet.call(".mysql", "lua", "select_by_key", "tb_map_role_city_1", "rid", self.rid)
    if not citys then
        -- 随机出生一个城市
		local x = math.random(0,skynet.getenv("MapWith"))
		local y = math.random(0,skynet.getenv("MapHeight"))
        -- //系统城池附近5格不能有玩家城池
    end
    self.citys = citys or {}
end
function lf.loaded(self)

end
function lf.enter(self, seq)

end
function lf.leave(self)

end

skynet.init(function () 
	citys:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
end)