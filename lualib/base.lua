local skynet = require "skynet"
local cluster = require "skynet.cluster"

local base = {

    -- 供外部服务调用的命令
        CMD = {},
    
        -- 客户端的请求
        REQUEST={},
    
        -- 公共函数
        PUBLIC = {},
    
        -- 公共数据
        DATA = {},
    
        CUR_CMD = {},
    }
    
local CMD=base.CMD
local DATA = base.DATA
local PUBLIC = base.PUBLIC
local CUR_CMD = base.CUR_CMD


-- 得到本地数据 表
function base.LocalData(_module_name,_default)
    local _name = "LD_" .. _module_name
    DATA[_name] = DATA[_name] or _default or {}
    return DATA[_name]
end

-- 得到本地函数 表
function base.LocalFunc(_module_name,_default)
    local _name = "LF_" .. _module_name
    PUBLIC[_name] = PUBLIC[_name] or _default or {}
    return PUBLIC[_name]
end

---- add by wss
--- 操作锁
DATA.action_lock = DATA.action_lock or {}
--- 打开 操作锁,   ！！！！ player_id 不传用于agent；player_id要传用于中心服务
function PUBLIC.on_action_lock( lock_name , player_id )
    if player_id then
        DATA.action_lock[lock_name] = DATA.action_lock[lock_name] or {}
        DATA.action_lock[lock_name][player_id] = true
    else
        DATA.action_lock[lock_name] = true
    end
end
--- 关闭锁
function PUBLIC.off_action_lock( lock_name , player_id )
    if player_id then
        DATA.action_lock[lock_name] = DATA.action_lock[lock_name] or {}
        DATA.action_lock[lock_name][player_id] = nil
    else
        DATA.action_lock[lock_name] = nil
    end
end
--- 获得锁
function PUBLIC.get_action_lock( lock_name , player_id )
    if player_id then
        return DATA.action_lock[lock_name] and DATA.action_lock[lock_name][player_id]
    else
        return DATA.action_lock[lock_name]
    end
end

local function real_load(_text,_name)

	if not _text or "" == _text then
		error("exe_lua error:_text is empty!",2)
	end

	_name = _name or ("code:" .. string.gsub(string.sub(_text,1,50),"[\r\n]"," "))

	local chunk,err = load(_text,_name)
	if not chunk then
		error(string.format("exe_lua %s error:%s ",_name,tostring(err)),2)
	end

	return chunk() or true

end

function base.CMD.exe_lua_base(_text,_name)
	local _err_stack

	local ok,msg = xpcall(
		function()
			local _ret = real_load(_text,_name)
			if type(_ret) == "table" then
				if _ret.on_load then
					return _ret.on_load()
				end
			elseif type(_ret) == "function" then
				return _ret()
			else
				return "lua loaded!"
			end
		end,
		function(_msg)
			_err_stack = debug.traceback()
			return _msg
		end
	)

	if ok then
		return true,msg
	else
		return false,tostring(msg) .. ":\n" .. tostring(_err_stack)
	end
end

function base.CMD.exe_lua(_text,_name)

	local _,msg = base.CMD.exe_lua_base(_text,_name)

	-- 返回值 丢弃是否错误
	return msg
end

-- 热更新的入口，call addr exe_file filename
function base.CMD.exe_file(_file)
    local _text
	local f = io.open(_file)
	if f then
		if _VERSION == "Lua 5.3" then
			_text = f:read("a")
		else
			_text = f:read("*a")
		end

		f:close()
	end
    if _text then
	    return base.CMD.exe_lua(_text,_file)
    end
end
local function check_node_online(cluster_name)
	local alive = skynet.call(".node_discover","lua","check_node_online",cluster_name)
	if not alive then
		print("cluster node not online",cluster_name)
		return false,"cluster node not online"
	end
	return true
end
function base.CMD.cluster_call(cluster_name,service_name,func_name,...)
	if skynet.getenv("cluster_name") == cluster_name then
		local ok,arg1,arg2,arg3,arg4,arg5 = pcall(skynet.call,service_name, "lua", func_name, ...)
		return ok,arg1,arg2,arg3,arg4,arg5
	end
	if not check_node_online(cluster_name) then
		print("cluster node not online",cluster_name,service_name,func_name)
		return false,"cluster node not online"
	end
	local ok,arg1,arg2,arg3,arg4,arg5 = pcall(cluster.call,cluster_name,service_name,func_name,...)
	return ok,arg1,arg2,arg3,arg4,arg5
end

function base.CMD.cluster_send(cluster_name,service_name,func_name,...)
	if skynet.getenv("cluster_name") == cluster_name then
		local ok,why = pcall(skynet.send,service_name, "lua", func_name, ...)
		return ok,why
	end
	if not check_node_online(cluster_name) then
		print("cluster node not online",cluster_name,service_name,func_name)
		return false,"cluster node not online"
	end
	local ok,why = pcall(cluster.send,cluster_name,service_name,func_name,...)
	print("cluster_send",cluster_name,service_name,func_name,ok,why)
	return ok,why
end


function base.CMD.cluster_call_by_type(cluster_type,service_name,func_name,...)
	local cluster_name = skynet.call(".node_discover","lua","get_node",cluster_type)
	if not cluster_name then
		print("cluster node not online",cluster_type,service_name,func_name)
		return false,"cluster node not online"
	end
	return base.CMD.cluster_call(cluster_name,service_name,func_name,...)
end

function base.CMD.cluster_send_by_type(cluster_type,service_name,func_name,...)
	local cluster_name = skynet.call(".node_discover","lua","get_node",cluster_type)
	if not cluster_name then
		print("cluster node not online",cluster_type,service_name,func_name)
		return false,"cluster node not online"
	end
	print("cluster_send_by_type",cluster_name,service_name,func_name)
	return base.CMD.cluster_send(cluster_name,service_name,func_name,...)
end

return base