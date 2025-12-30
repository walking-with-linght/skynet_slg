local skynet = require "skynet"
local cluster = require "skynet.cluster"
local Timer = require "utils.timer"
local basefunc = require "basefunc"
local cjson = require "cjson"
local mysql = require "skynet.db.mysql"
require "skynet.manager"
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


--[[
根据字段类型定义，从数据库加载数据并自动处理JSON字段
参数:
	self: 角色对象
	table_name: MySQL表名
	key_field: 主键字段名（如 "rid"）
	key_value: 主键值
	db_schema: 字段类型定义表，格式: {field_name = "type", ...}
	          支持的类型: "int", "string", "json", "float", "datetime"
	          示例: {rid = "int", jsondata = "json", name = "string"}
返回值:
	data: 加载的数据（已自动处理JSON字段）
	ok: 是否加载成功
示例:
	local db_schema = {
		rid = "int",
		pos_tags = "json",
		collect_times = "int",
	}
	local data, ok = PUBLIC.loadDbData(self, "tb_role_attribute_1", "rid", self.rid, db_schema)
]]
function PUBLIC.loadDbData(table_name, key_field, key_value, db_schema)
	if not db_schema or not next(db_schema) then
		elog("loadDbData: db_schema is required")
		return nil, false
	end
	
	local ok, data = skynet.call(".mysql", "lua", "select_by_key", table_name, key_field, key_value)
	if not ok or not data then
		return nil, false
	end
	
	-- 根据字段类型自动处理
	for field_name, field_type in pairs(db_schema) do
		if data[field_name] ~= nil then
			if field_type == "json" then
				-- JSON字段自动解码
				if type(data[field_name]) == "string" and data[field_name] ~= "" then
					local decode_ok, decoded = pcall(cjson.decode, data[field_name])
					if decode_ok then
						data[field_name] = decoded
					else
						elog("loadDbData: json decode failed", field_name, data[field_name])
						data[field_name] = {}
					end
				elseif data[field_name] == "" or data[field_name] == nil then
					data[field_name] = {}
				end
			elseif field_type == "int" then
				-- 确保是整数类型
				data[field_name] = tonumber(data[field_name]) or 0
			elseif field_type == "float" then
				-- 确保是浮点数类型
				data[field_name] = tonumber(data[field_name]) or 0.0
			end
		end
	end
	
	return data, true
end

--[[
根据字段类型定义，保存数据到数据库并自动处理JSON字段
使用 INSERT ... ON DUPLICATE KEY UPDATE 一条SQL语句完成插入或更新
参数:
	table_name: MySQL表名
	key_field: 主键字段名（如 "rid"）
	key_value: 主键值
	data: 要保存的数据表
	db_schema: 字段类型定义表，格式: {field_name = "type", ...}
	          支持的类型: "int", "string", "json", "float", "datetime"
返回值:
	ok: 是否保存成功
示例:
	local db_schema = {
		rid = "int",
		pos_tags = "json",
		collect_times = "int",
	}
	local save_data = {
		rid = self.rid,  -- 必须包含主键
		pos_tags = self.attr.pos_tags,  -- 会自动编码为JSON
		collect_times = self.attr.collect_times,
	}
	local ok = PUBLIC.saveDbData("tb_role_attribute_1", "rid", self.rid, save_data, db_schema)
]]
function PUBLIC.saveDbData(table_name, key_field, key_value, data, db_schema)
	if not db_schema or not next(db_schema) then
		elog("saveDbData: db_schema is required and cannot be empty")
		return false
	end
	
	-- 确保主键字段在 db_schema 中定义
	if not db_schema[key_field] then
		elog("saveDbData: key_field '%s' must be defined in db_schema", key_field)
		return false
	end
	
	-- 确保主键字段包含在数据中
	if not data then
		data = {}
	end
	data[key_field] = key_value
	
	-- 只遍历 db_schema 中定义的字段
	local save_data = {}
	local cols = {}
	local vals = {}
	local updates = {}
	
	for field_name, field_type in pairs(db_schema) do
		-- 从 data 中获取字段值，如果不存在则根据类型设置默认值
		local value = data[field_name]
		local processed_value
		local is_string = false
		
		-- 根据字段类型处理
		if field_type == "json" then
			-- JSON字段自动编码
			if value == nil then
				processed_value = cjson.encode({})
				is_string = true
			elseif type(value) == "table" then
				processed_value = cjson.encode(value)
				is_string = true
			elseif type(value) == "string" then
				-- 如果已经是字符串，尝试解码再编码以确保格式正确
				local decode_ok, decoded = pcall(cjson.decode, value)
				if decode_ok then
					processed_value = cjson.encode(decoded)
				else
					processed_value = value
				end
				is_string = true
			else
				processed_value = cjson.encode(value or {})
				is_string = true
			end
		elseif field_type == "int" or field_type == "float" then
			-- 数值类型，确保是数字
			if value == nil then
				processed_value = 0
			else
				processed_value = tonumber(value) or 0
			end
			is_string = false
		else
			-- string 和 datetime 类型
			if value == nil then
				processed_value = ""
			else
				processed_value = tostring(value)
			end
			is_string = true
		end
		
		-- 字符串类型需要转义，数值类型直接使用
		local sql_value
		if is_string then
			sql_value = mysql.quote_sql_str(processed_value)
		else
			sql_value = tostring(processed_value)
		end
		
		table.insert(cols, "`" .. field_name .. "`")
		table.insert(vals, sql_value)
		
		-- 主键字段不参与更新部分
		if field_name ~= key_field then
			table.insert(updates, "`" .. field_name .. "`=" .. sql_value)
		end
		
		save_data[field_name] = processed_value
	end
	
	-- 构建 INSERT ... ON DUPLICATE KEY UPDATE SQL
	if #cols == 0 then
		elog("saveDbData: no fields to save")
		return false
	end
	
	local cols_str = table.concat(cols, ",")
	local vals_str = table.concat(vals, ",")
	
	-- 如果没有需要更新的字段（只有主键），则只执行 INSERT，忽略重复键错误
	local sql
	if #updates == 0 then
		-- 只有主键字段，使用 INSERT IGNORE
		sql = string.format(
			"INSERT IGNORE INTO %s (%s) VALUES (%s)",
			table_name, cols_str, vals_str
		)
	else
		-- 有更新字段，使用 ON DUPLICATE KEY UPDATE
		local updates_str = table.concat(updates, ",")
		sql = string.format(
			"INSERT INTO %s (%s) VALUES (%s) ON DUPLICATE KEY UPDATE %s",
			table_name, cols_str, vals_str, updates_str
		)
	end
	
	-- 执行SQL
	local ok, result = skynet.call(".mysql", "lua", "execute", sql)
	if not ok then
		elog("saveDbData failed:", sql, result and cjson.encode(result) or "unknown error")
		return false
	end
	
	return true
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


local function cmd_get_args(...)
	if select("#") > 0 then
		return table.pack(...)
	else
		return nil
	end
end

local _service_start_stack_info

-- 默认的消息分发函数
function base.default_dispatcher(session, source, cmd, subcmd, ...)
	local f = CMD[cmd]

	CUR_CMD.session = session
	CUR_CMD.source = source
	CUR_CMD.cmd = cmd
	CUR_CMD.subcmd = subcmd
	CUR_CMD.args = cmd_get_args(...)

	if f then
		if session == 0 then
			local ok,msg = xpcall(function(...) f(subcmd, ...) end,basefunc.error_handle,...)
			if not ok then
				local _err_str = string.format("send :%08x ,session %d,from :%08x,CMD.%s(...)\n error:%s\n >>>> param:\n%s ",skynet.self(),session,source,cmd,tostring(msg),basefunc.tostring({subcmd, ...}))
				print(_err_str)
				error(_err_str)
			end
		else
			local ok,msg,sz = xpcall(function(...) return skynet.pack(f(subcmd, ...)) end,basefunc.error_handle,...)
			if ok then
				skynet.ret(msg,sz)
			else
				local _err_str = string.format("send :%08x ,session %d,from :%08x,CMD.%s(...)\n error:%s\n >>>> param:\n%s ",skynet.self(),session,source,cmd,tostring(msg),basefunc.tostring({subcmd, ...}))
				print(_err_str)
				error(_err_str)
			end
		end
	else
		local _err_str
		if _service_start_stack_info then
			_err_str = string.format("call :%08x ,session %d,from :%08x ,error: command '%s' not found.\nservice start %s",skynet.self(),session,source,cmd,_service_start_stack_info)
		else
			_err_str = string.format("call :%08x ,session %d,from :%08x ,error: command '%s' not found.",skynet.self(),session,source,cmd)
		end
		elog(_err_str)
		error(_err_str)
		-- if session ~= 0 then
		-- 	skynet.ret(skynet.pack("CALL_FAIL"))
		-- end
	end
end
local default_dispatcher = base.default_dispatcher

-- 启动服务
-- 参数:
-- 	_dispatcher    （可选） 协议分发函数
-- 	_register_name （可选） 注册服务名字

function base.start_service(_register_name,_dispatcher,_on_start)

	-- 记录栈信息，以便在找不到命令是，输出上层文件信息
	_service_start_stack_info = debug.traceback(nil,2)

	skynet.start(function()

		if type(_on_start) == "function" then
			if _on_start() then -- 返回 true 表示 自己处理完，系统不要再处理
				return
			end
		end

		skynet.dispatch("lua", _dispatcher or default_dispatcher)

		if _register_name then
			skynet.register(_register_name)
		end

	end)

end


-- 当前状态 ： 含义参见 try_stop_service 函数
base.DATA.current_service_status = "running"
base.DATA.current_service_info = nil 			-- 说明信息

--[[
尝试停止服务：在这个函数中执行关闭前的事情，比如保存数据
（这里是默认实现，服务应该根据需要实现这个函数）
参数 ：
	_count 被调用的次数，可以用来判断当前是第几次尝试
	_time 距第一次调用以来的时间
返回值：status,info
	status
		"free"		自由状态。没有缓存数据需要写入，可以关机。
		"stop"	    已停止服务，可以关机
		"runing"	正在运行，不能关机
		"wait"      正在关闭，但还未完成，需要等待；
		            如果返回此值，则会一直调用 check_service_status 直到结果不是 "wait"
	info  （可选）可以返回一段文本信息，用于说明当前状态（比如还有 n 个玩家在比赛）
 ]]
function base.PUBLIC.try_stop_service(_count,_time)
	-- 5 秒后允许关闭
	if _time < 5 then
		return "wait",string.format("after %g second stop!",5 - _time)
	else
		return "stop"
	end
end

-- 得到服务状态
function CMD.get_service_status()
	return base.DATA.current_service_status,base.DATA.current_service_info
end

-- 供调试控制台列出所有命令
function CMD.incmd()
	local ret = {}
	for _name,_ in pairs(CMD) do
		ret[#ret + 1] = _name
	end

	table.sort(ret)
	return ret
end

--[[
关闭服务
	返回执行此命令后的状态
返回值：
	参见 try_stop_service

注意： 如果 返回 "stop" 则在返回后 会立即退出（后续不要再调用此服务）
	2024年09月11日15:24:01  有用到，refd
 ]]
local _last_command_running = false
function CMD.stop_service()

	-- 最近一次还正在执行，则直接返回结果
	if _last_command_running then
		return base.DATA.current_service_status,base.DATA.current_service_info
	end

	-- 停止
	base.DATA.current_service_status,base.DATA.current_service_info = base.PUBLIC.try_stop_service(1,0)

	if base.PUBLIC.on_close_service then
		pcall(base.PUBLIC.on_close_service)
	end
	-- 如果需要等待，则不断查询状态
	if "wait" == base.DATA.current_service_status then

		local _stop_time = skynet.now()
		local _count = 1

		_last_command_running = true
		Timer.runAfter(550,function()
			_count = _count + 1
			base.DATA.current_service_status,base.DATA.current_service_info = base.PUBLIC.try_stop_service(_count,(skynet.now()-_stop_time)*0.01)

			if "stop" == base.DATA.current_service_status then

				-- 停止服务
				skynet.timeout(1,function ()
					skynet.exit()
				end)
				return false

			elseif "wait" ~= base.DATA.current_service_status then

				-- 服务已不是等待状态，不需要再查询

				_last_command_running = false
				return false
			end

			_last_command_running = false
		end)
	end

	-- 停止服务
	if "stop" == base.DATA.current_service_status then
		skynet.timeout(1,function ()
			dlog("退出---log by base.lua")
			skynet.exit()
		end)
	end
	return base.DATA.current_service_status,base.DATA.current_service_info
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
		elog("cluster node not online",cluster_name,service_name,func_name)
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
		elog("cluster node not online",cluster_name,service_name,func_name)
		return false,"cluster node not online"
	end
	local ok,why = pcall(cluster.send,cluster_name,service_name,func_name,...)
	print("cluster_send",cluster_name,service_name,func_name,ok,why)
	return ok,why
end


function base.CMD.cluster_call_by_type(cluster_type,service_name,func_name,...)
	local cluster_name = skynet.call(".node_discover","lua","get_node",cluster_type)
	if not cluster_name then
		elog("cluster node not online",cluster_type,service_name,func_name)
		return false,"cluster node not online"
	end
	return base.CMD.cluster_call(cluster_name,service_name,func_name,...)
end

function base.CMD.cluster_send_by_type(cluster_type,service_name,func_name,...)
	local cluster_name = skynet.call(".node_discover","lua","get_node",cluster_type)
	if not cluster_name then
		elog("cluster node not online",cluster_type,service_name,func_name)
		return false,"cluster node not online"
	end
	print("cluster_send_by_type",cluster_name,service_name,func_name)
	return base.CMD.cluster_send(cluster_name,service_name,func_name,...)
end

return base