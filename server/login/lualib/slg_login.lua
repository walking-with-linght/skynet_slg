local skynet = require "skynet"
local base = require "base"
local cjson = require "cjson"
local DATA = base.DATA     --本服务使用的表
local CMD = base.CMD       --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local dump = require "dump"
local utils = require "utils"
local msgpack = require "msgpack"
local error_code = require "error_code"
local basefunc = require "basefunc"
local REQUEST = base.REQUEST


-- 注册
REQUEST["/account/register"] = function(path, method, header, body, query)
	local hardware = query.hardware
	local username = query.username
	local password = query.password

	if not hardware or not username or not password then
		return 400, "hardware and username and password are required"
	end

	-- 看下 redis 有没有数据，如果有直接返回错误，没有再查一次 mysql
	local redis_key = string.format("account:%s", username)
	local user_data = skynet.call(".redis", "lua", "EXISTS", redis_key)
	if user_data then
		return 200, {
			code = error_code.account_already_exists,
			errmsg = "账号已存在",
		}
	end

	-- 查一次 mysql
	local ok,mysql_data = skynet.call(".mysql", "lua", "select_one_by_key", "tb_user_info", "username", username)
	if ok and mysql_data and next(mysql_data) then
		print(dump(mysql_data),"mysql_cache")
		skynet.call(".redis", "lua", "hmset", redis_key, mysql_data)
		return 200, {
			code = error_code.account_already_exists,
			errmsg = "账号已存在",
		}
	end
	local passcode = utils.random_string(8)
	local now = os.time()
	local uid = 9--tonumber(skynet.call(".redis", "lua", "incr", "uid_seq"))
	local user = {
		uid = uid,
		hardware = hardware,
		username = username,
		passwd = basefunc.md5(password,passcode),
		passcode = passcode,
		ctime = os.date('%Y-%m-%d %H:%M:%S', now),
		mtime = os.date('%Y-%m-%d %H:%M:%S', now),
		status = 0,
	}
	skynet.call(".redis", "lua", "hmset", redis_key, user)
	-- 插入一条数据
	local resultid = skynet.call(".mysql", "lua", "insert", "tb_user_info", user)
	print(resultid,"resultid")

	return 200, {
		code = error_code.success,
	}
end


return function (path, method, header, body, query)

    -- print("http request path=",path)
    -- print("http request method=", method)
    -- print("http request header=",header)
    -- print("http request body=",body)
    -- print("http request query=",query)
    -- print(dump({path, method, header, body, query}))
    local f = REQUEST[path]
    if f then
        local code ,ret,header =  f(path, method, header, body, query)
        print(dump({code, ret, header}))
        return code, ret, header
    end
    return 404,"not found"
end