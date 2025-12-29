local skynet = require "skynet"
require "skynet.manager"
local lfs = require "lfs"
local sharedata = require "skynet.sharedata"
local cjson = require "cjson"

-- 递归加载所有 JSON 配置
local function load_all_configs()
    local function load_dir(dir_path, prefix)
        for name in lfs.dir(dir_path) do
            if name ~= "." and name ~= ".." then
                local full_path = dir_path .. "/" .. name
                local attr = lfs.attributes(full_path)
                
                if attr.mode == "directory" then
                    -- 递归加载子目录
                    local new_prefix = prefix and (prefix .. "." .. name) or name
                    load_dir(full_path, new_prefix)
                elseif name:match("%.lua$") then
                    -- 加载 lua 文件
					print(full_path,"加载配置文件")
					local f = io.open(full_path, "r")
					local content = f:read("*a")
    				f:close()
					content = load(content,"chunk")()
					sharedata.new(full_path, content)
                elseif name:match("%.json$") then
                    -- 加载 JSON 文件
					print(full_path,"加载配置文件")
					local f = io.open(full_path, "r")
					local content = f:read("*a")
    				f:close()
					content = cjson.decode(content)
					sharedata.new(full_path, content)
                end
            end
        end
    end
    load_dir("config")
end


skynet.start(function()
    skynet.error('account start')

    local console_port = skynet.getenv("console_port")
    if console_port then
        skynet.newservice("debug_console",console_port)
    end

    skynet.call(skynet.newservice("mysqlpool"), "lua", "open", {
		host 	= skynet.getenv("db_host"),
		port 	= skynet.getenv("db_port"),
		database 	= skynet.getenv("db_db"),
		user 		= skynet.getenv("db_user"),
		password 	= skynet.getenv("db_pwd"),
		name = ".mysql",
	})
    skynet.call(skynet.newservice("redispool"), "lua", "open", {
		host 	= skynet.getenv("redis_host"),
		port 	= skynet.getenv("redis_port"),
		db 		= skynet.getenv("redis_db"),
		auth 	= skynet.getenv("redis_auth"),
		name = ".redis",
	})


    -- 先加载配置
    load_all_configs()
    
	skynet.newservice("agent_manager")
    skynet.newservice("general_manager")
    skynet.newservice("map_manager")
    skynet.newservice("chat_manager")



    -- 服务发现永远放在最后面
    local addr = skynet.uniqueservice("redis_discover")
	skynet.call(addr,"lua","start")

    skynet.exit()
end)