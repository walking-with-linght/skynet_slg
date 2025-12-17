
-- 资源
local skynet = require "skynet"
local base = require "base"
local event = require "event"
local sharedata = require "skynet.sharedata"


local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST

local NM = "resource"

local lf = base.LocalFunc(NM)

function lf.load(self)
    local ok,role_res =  skynet.call(".mysql", "lua", "select_one_by_key", "tb_role_res_1", "rid", self.rid)
    if not role_res then
		-- 刚创建的，初始化一下
		local role_res_config = sharedata.query("config/basic.lua")
		print("默认配置",dump(role_res_config))
		role_res = {
			decree = role_res_config.role.decree,	-- 令牌
			gold = role_res_config.role.gold,		-- 金币
			grain = role_res_config.role.grain,		-- 粮食
			iron = role_res_config.role.iron,		-- 铁矿
			stone = role_res_config.role.stone,		-- 石矿
			wood = role_res_config.role.wood,		-- 木头
			rid = self.rid
		}
		local ok = skynet.call(".mysql", "lua", "insert", "tb_role_res_1", role_res)
		assert(ok)
        self.role_res = role_res
        -- 角色属性表
		local role_attr = {
			rid = self.rid,
			parent_id = 0,
			collect_times = 0,
		}
		local ok = skynet.call(".mysql", "lua", "insert", "tb_role_attribute_1", role_attr)
        role_attr.rid = nil
        self.role_attr = role_attr
	end
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